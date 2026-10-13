import Foundation

/// Text utilities shared by the page and reference-library context builders.
enum SafariAgentText {
    /// Rough token estimate (≈3.5 characters per token for French and English
    /// prose). Only used to keep prompts inside a budget, never for billing.
    static func estimateTokens(_ text: String) -> Int {
        text.isEmpty ? 0 : Int((Double(text.count) / 3.5).rounded(.up))
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Cuts `text` to roughly `maxTokens`, preferring a word boundary.
    static func truncate(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        let maxCharacters = Int(Double(maxTokens) * 3.5)
        guard text.count > maxCharacters else { return text }
        var cut = String(text.prefix(maxCharacters))
        if let space = cut.lastIndex(where: { $0.isWhitespace }), cut.distance(from: space, to: cut.endIndex) < 80 {
            cut = String(cut[..<space])
        }
        return cut + " […]"
    }

    /// Keeps only scheme, host and path: query strings and fragments often
    /// carry session identifiers that the model does not need.
    static func sanitizedPageURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ""
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.string ?? ""
    }

    /// FNV-1a, used only as an in-memory cache key for page contents.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Page and document text is untrusted. Our prompt wraps it in tags, so
    /// neutralize anything that could close or reopen one of those tags.
    static func neutralizeDelimiters(_ text: String) -> String {
        var result = text
        for tag in ["page", "bibliotheque", "selection", "extraits", "question"] {
            for prefix in ["</", "<"] {
                result = result.replacingOccurrences(
                    of: prefix + tag,
                    with: prefix.replacingOccurrences(of: "<", with: "‹") + tag,
                    options: [.caseInsensitive]
                )
            }
        }
        return result
    }

    private static let stopWords: Set<String> = [
        "a", "au", "aux", "avec", "ce", "ces", "cet", "cette", "dans", "de", "des", "du", "elle", "en", "est",
        "et", "il", "ils", "je", "la", "le", "les", "leur", "lui", "ma", "mais", "me", "mes", "moi", "mon",
        "ne", "nous", "on", "ou", "par", "pas", "pour", "qu", "que", "qui", "sa", "se", "ses", "son", "sur",
        "ta", "te", "tes", "toi", "ton", "tu", "un", "une", "vos", "votre", "vous", "y", "quoi", "comment",
        "est-ce", "c", "d", "j", "l", "m", "n", "s", "t",
        "the", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "in", "is", "it", "of",
        "on", "or", "that", "this", "to", "was", "what", "when", "where", "which", "who", "why", "with", "you"
    ]

    /// Lowercased, accent-folded terms with stop words removed and a light
    /// plural strip, so "Équations" and "equation" match.
    static func searchTerms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var terms: [String] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard !current.isEmpty, !stopWords.contains(current) else { return }
            let isNumber = current.allSatisfy { $0.isNumber }
            guard isNumber || current.count >= 2 else { return }
            var term = current
            if !isNumber, term.count > 3, term.hasSuffix("s") || term.hasSuffix("x") {
                term.removeLast()
            }
            terms.append(term)
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return terms
    }
}

/// Okapi BM25 over a fixed set of passages. Fast enough to rank thousands of
/// passages per question in a few milliseconds without any network call.
struct SafariAgentLexicalIndex {
    private struct Entry {
        let termFrequencies: [String: Int]
        let length: Int
    }

    private let entries: [Entry]
    private let documentFrequency: [String: Int]
    private let averageLength: Double
    private let k1 = 1.2
    private let b = 0.75

    var count: Int { entries.count }

    init(texts: [String]) {
        var entries: [Entry] = []
        var documentFrequency: [String: Int] = [:]
        var totalLength = 0
        entries.reserveCapacity(texts.count)
        for text in texts {
            let terms = SafariAgentText.searchTerms(text)
            var frequencies: [String: Int] = [:]
            for term in terms {
                frequencies[term, default: 0] += 1
            }
            for term in frequencies.keys {
                documentFrequency[term, default: 0] += 1
            }
            totalLength += terms.count
            entries.append(Entry(termFrequencies: frequencies, length: terms.count))
        }
        self.entries = entries
        self.documentFrequency = documentFrequency
        self.averageLength = entries.isEmpty ? 0 : max(1, Double(totalLength) / Double(entries.count))
    }

    func scores(for query: String) -> [Double] {
        let queryTerms = Array(Set(SafariAgentText.searchTerms(query)))
        guard !queryTerms.isEmpty, !entries.isEmpty else {
            return Array(repeating: 0, count: entries.count)
        }
        let total = Double(entries.count)
        return entries.map { entry in
            var score = 0.0
            for term in queryTerms {
                guard let frequency = entry.termFrequencies[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (total - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                let norm = tf + k1 * (1 - b + b * Double(entry.length) / averageLength)
                score += idf * (tf * (k1 + 1)) / norm
            }
            return score
        }
    }

    /// Indices with a positive score, best first; ties keep document order.
    func rankedIndices(for query: String) -> [Int] {
        let scores = scores(for: query)
        return scores.indices
            .filter { scores[$0] > 0 }
            .sorted { lhs, rhs in
                scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
            }
    }
}
