import AppKit
import Foundation
import NaturalLanguage

public final class SemanticMemoryService: @unchecked Sendable {
    public static let shared = SemanticMemoryService()

    private let store: SemanticMemoryStore
    private let embedding: NLEmbedding?
    private let processingQueue = DispatchQueue(label: "com.williamh07.wisper.semantic_memory.service", qos: .utility)

    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "semantic_memory_enabled") as? Bool ?? true
    }

    public var captureClipboardEnabled: Bool {
        UserDefaults.standard.object(forKey: "semantic_memory_capture_clipboard") as? Bool ?? false
    }

    public var captureTerminalHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: "semantic_memory_capture_terminal") as? Bool ?? false
    }

    public var retentionDays: Int {
        let saved = UserDefaults.standard.integer(forKey: "semantic_memory_retention_days")
        return saved > 0 ? saved : 7
    }

    public init(store: SemanticMemoryStore = .shared) {
        self.store = store
        self.embedding = NLEmbedding.sentenceEmbedding(for: .french) ?? NLEmbedding.sentenceEmbedding(for: .english)
    }

    // MARK: - Capture & Indexing

    public func record(
        text: String,
        category: SemanticMemoryCategory,
        sourceAppName: String = "",
        sourceWindowTitle: String? = nil,
        sync: Bool = false
    ) {
        guard isEnabled else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Security check: Ignore passwords or sensitive private keys
        if isSensitiveContent(trimmed, sourceApp: sourceAppName) {
            return
        }

        let work = { [weak self] in
            guard let self else { return }

            // Compute embedding vector locally
            let vector = self.embedding?.vector(for: trimmed)

            let item = SemanticMemoryItem(
                text: trimmed,
                sourceAppName: sourceAppName,
                sourceWindowTitle: sourceWindowTitle,
                category: category,
                embedding: vector
            )

            self.store.insert(item, sync: true)
            self.store.deleteOlderThan(days: self.retentionDays)
        }

        if sync {
            processingQueue.sync(execute: work)
        } else {
            processingQueue.async(execute: work)
        }
    }

    /// Stores a note the user typed deliberately. Unlike captured content, manual
    /// notes bypass the sensitive-content filter: the user chose to save this text.
    @discardableResult
    public func addManualNote(_ text: String) -> Bool {
        guard isEnabled else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let vector = embedding?.vector(for: trimmed)
        let item = SemanticMemoryItem(
            text: trimmed,
            sourceAppName: "Note",
            category: .manualNote,
            embedding: vector
        )
        store.insert(item, sync: true)
        store.deleteOlderThan(days: retentionDays)
        return true
    }

    // MARK: - Security Filtering

    private static let ignoredPasswordApps: Set<String> = [
        "1password",
        "bitwarden",
        "keepassxc",
        "lastpass",
        "enpass",
        "dashlane",
        "keychain access",
        "trousseaux d'accès"
    ]

    public func isSensitiveContent(_ text: String, sourceApp: String) -> Bool {
        let appLower = sourceApp.lowercased()
        for ignored in Self.ignoredPasswordApps {
            if appLower.contains(ignored) {
                return true
            }
        }

        // Ignore private cryptographic keys
        if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") {
            return true
        }

        // Ignore single-token high-entropy strings without spaces resembling passwords
        if text.count >= 16 && text.count <= 64 && !text.contains(" ") && !text.contains("/") && !text.contains(".") {
            let hasLower = text.contains { $0.isLowercase }
            let hasUpper = text.contains { $0.isUppercase }
            let hasNumber = text.contains { $0.isNumber }
            if hasLower && hasUpper && hasNumber {
                return true
            }
        }

        return false
    }

    // MARK: - Terminal History Sync (~/.zsh_history)

    /// Known noise commands that provide zero long-term memory value
    private static let ignoredTerminalCommands: Set<String> = [
        "ls", "ll", "la", "cd", "cd ..", "cd -", "pwd", "clear", "exit", "history",
        "top", "htop", "btop", "q", "w", "whoami", "echo", "cat", "source ~/.zshrc",
        "gsync", "yes", "man"
    ]

    /// Keywords indicating sensitive credentials passed as CLI arguments
    private static let sensitiveTerminalKeywords: [String] = [
        "--password", "-password", "passwd", "--token", "bearer", "authorization:",
        "aws_secret_access_key", "id_rsa", "id_ed25519", "ghp_", "glpat-",
        "npm_token", "sk-proj-", "sk-ant-", "xoxb-", "xoxp-", "BEGIN PRIVATE KEY"
    ]

    public func isSensitiveTerminalCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        for kw in Self.sensitiveTerminalKeywords {
            if lower.contains(kw) {
                return true
            }
        }
        if lower.contains("-p ") {
            let isSafeP = lower.contains("mkdir ") || lower.contains("scp ") || lower.contains("tar ") || lower.contains("git ")
            if !isSafeP {
                return true
            }
        }
        if lower.contains("secret") && !lower.contains("secrets/") {
            return true
        }
        if lower.contains("export ") && (lower.contains("key=") || lower.contains("secret=") || lower.contains("token=") || lower.contains("password=")) {
            return true
        }
        return false
    }

    public func isNoiseTerminalCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 { return true }
        if Self.ignoredTerminalCommands.contains(trimmed) { return true }
        if trimmed.hasPrefix("cd ") && trimmed.count < 15 && !trimmed.contains("&&") && !trimmed.contains(";") { return true }

        let lower = trimmed.lowercased()

        // Filter out accidental natural language pastes, chat prompts, and questions into terminal
        if lower.contains("?") { return true }

        let conversationalPrefixes = [
            "comment ", "pourquoi ", "est-ce ", "en fait ", "alors ", "et il faut ",
            "avez-vous ", "pouvez-vous ", "notre but ", "je vais ", "on va ", "j'ai ",
            "je suis ", "c'est ", "il y a ", "salut ", "bonjour ", "merci ",
            "s'il vous plaît", "stp ", "svp ", "voici ", "voilà ", "pour info ",
            "donc ", "accueil :", "oui :", "non :", "ps :", "nb :",
            "hey ", "hi ", "hello ", "yo ", "please ", "thanks ", "thank you ",
            "can you ", "could you ", "do you ", "did you ", "you know ",
            "i think ", "i guess ", "i will ", "i'm ", "im ", "we are ", "we should ",
            "we need ", "let's ", "lets ", "it's ", "its ", "there's ", "whats ",
            "what's ", "what is ", "why does ", "how do ", "how does ", "note :", "note:"
        ]
        for prefix in conversationalPrefixes {
            if lower.hasPrefix(prefix) { return true }
        }

        // Conversational phrases inside lines
        if lower.contains(" j'ai ") || lower.contains(" je suis ") || lower.contains(" on a ") ||
           lower.contains(" c'est ") || lower.contains(" il faut ") || lower.contains(" on va ") ||
           lower.contains(" nous avons ") || lower.contains(" vous avez ") || lower.contains(" d'un des ") ||
           lower.contains(" l'application ") || lower.contains(" pour l'instant ") || lower.contains(" pour un mockup ") ||
           lower.contains(" i think ") || lower.contains(" i guess ") || lower.contains(" i will ") ||
           lower.contains(" we should ") || lower.contains(" we need ") || lower.contains(" you know ") ||
           lower.contains(" let's ") || lower.contains(" it's ") || lower.contains(" there's ") {
            return true
        }

        // A valid shell command's first token should look like a command:
        // Not ending in colon, not non-ASCII accented words
        let firstToken = trimmed.split(separator: " ").first.map(String.init) ?? ""
        if firstToken.hasSuffix(":") { return true }

        if firstToken.contains(where: { $0.isLetter && !("A"..."Z").contains($0) && !("a"..."z").contains($0) }) {
            return true
        }

        // Capitalized first word followed by punctuation like commas or periods
        if let first = firstToken.first, first.isUppercase {
            if !trimmed.contains("=") && !trimmed.contains("/") && !trimmed.contains("-") && (trimmed.contains(",") || trimmed.contains(".")) {
                return true
            }
        }

        return false
    }

    /// Parses a raw line from ~/.zsh_history or ~/.bash_history.
    /// Supports both extended format (`: 1699999999:0;command`) and plain format (`command`).
    public static func parseTerminalHistoryLine(_ line: String) -> (command: String, date: Date)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Extended zsh format: : 1699999999:0;command
        if trimmed.hasPrefix(": ") {
            let withoutColon = trimmed.dropFirst(2)
            if let semicolonIndex = withoutColon.firstIndex(of: ";") {
                let metadata = withoutColon[..<semicolonIndex]
                let cmd = String(withoutColon[withoutColon.index(after: semicolonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cmd.isEmpty else { return nil }

                var date = Date()
                if let colonIndex = metadata.firstIndex(of: ":"),
                   let timestamp = Double(metadata[..<colonIndex].trimmingCharacters(in: .whitespaces)) {
                    date = Date(timeIntervalSince1970: timestamp)
                }
                return (cmd, date)
            }
        }

        // Plain format
        return (trimmed, Date())
    }

    /// Extracts individual commands from history content, handling multi-line continuations (trailing `\`).
    public static func extractCommands(from content: String) -> [(command: String, date: Date)] {
        let lines = content.components(separatedBy: .newlines)
        var entries: [(command: String, date: Date)] = []
        var pendingParts: [String] = []
        var pendingDate = Date()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let hasTrailingSlash = line.hasSuffix("\\")
            let clean = hasTrailingSlash ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) : line

            // A line is an argument/flag continuation if it was indented, or starts with a flag/pipe/redirect
            let isContinuation = rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t") ||
                                 clean.hasPrefix("-") || clean.hasPrefix("|") ||
                                 clean.hasPrefix(">") || clean.hasPrefix("<")

            if isContinuation && !pendingParts.isEmpty {
                pendingParts.append(clean)
            } else {
                if !pendingParts.isEmpty {
                    let full = pendingParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !full.isEmpty {
                        entries.append((command: full, date: pendingDate))
                    }
                    pendingParts.removeAll()
                }

                if let parsed = parseTerminalHistoryLine(clean) {
                    pendingParts.append(parsed.command)
                    pendingDate = parsed.date
                } else {
                    pendingParts.append(clean)
                    pendingDate = Date()
                }
            }

            if !hasTrailingSlash {
                if !pendingParts.isEmpty {
                    let full = pendingParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !full.isEmpty {
                        entries.append((command: full, date: pendingDate))
                    }
                    pendingParts.removeAll()
                }
            }
        }

        if !pendingParts.isEmpty {
            let full = pendingParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !full.isEmpty {
                entries.append((command: full, date: pendingDate))
            }
        }

        return entries
    }

    /// Reads ~/.zsh_history (and ~/.bash_history) in read-only mode, extracts the most recent unique commands,
    /// filters out noise and sensitive credentials, and indexes them into local SQLite memory.
    public func syncTerminalHistory(limit: Int = 800, sync: Bool = false) {
        guard isEnabled, captureTerminalHistoryEnabled else { return }

        let work = { [weak self] in
            guard let self else { return }

            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let historyFiles = [
                homeDir.appendingPathComponent(".zsh_history"),
                homeDir.appendingPathComponent(".bash_history")
            ]

            var parsedCommands: [(command: String, date: Date)] = []

            for fileURL in historyFiles {
                guard FileManager.default.fileExists(atPath: fileURL.path),
                      let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ??
                                    (try? String(contentsOf: fileURL, encoding: .isoLatin1)) else {
                    continue
                }

                let entries = Self.extractCommands(from: content)
                // Iterate in reverse (most recent commands first)
                for parsed in entries.reversed() {
                    let cmd = parsed.command

                    if self.isNoiseTerminalCommand(cmd) || self.isSensitiveTerminalCommand(cmd) {
                        continue
                    }

                    // Avoid duplicate consecutive or already seen commands in this batch
                    if parsedCommands.contains(where: { $0.command == cmd }) {
                        continue
                    }

                    parsedCommands.append(parsed)
                    if parsedCommands.count >= limit {
                        break
                    }
                }
            }

            guard !parsedCommands.isEmpty else { return }

            for item in parsedCommands {
                // Compute vector embedding locally on Apple Silicon
                let vector = self.embedding?.vector(for: item.command)

                let memItem = SemanticMemoryItem(
                    timestamp: item.date,
                    text: item.command,
                    sourceAppName: "Terminal",
                    category: .terminal,
                    embedding: vector
                )
                self.store.insert(memItem, sync: true)
            }
        }

        if sync {
            processingQueue.sync(execute: work)
        } else {
            processingQueue.async(execute: work)
        }
    }

    // MARK: - Hybrid Search Engine

    private static let searchStopWords: Set<String> = [
        // Articles & prepositions
        "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "en", "pour",
        "dans", "avec", "sur", "par", "et", "ou", "ce", "cet", "cette", "ces",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
        "notre", "nos", "votre", "vos", "leur", "leurs",
        "the", "a", "an", "in", "on", "at", "for", "with", "from", "to", "of", "and", "or",
        // Pronouns
        "je", "j", "tu", "t", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "qui", "que", "qu", "quoi", "dont", "où", "ou",
        // Auxiliaries & common verbs
        "est", "sont", "c", "etait", "était", "etre", "être",
        "ai", "as", "a", "avons", "avez", "ont", "avoir", "été", "ete",
        "fait", "faire", "mis", "mettre", "tape", "tapé", "taper", "tappé",
        "is", "are", "was", "were", "my", "your", "his", "her",
        // Question & conversational framing words
        "quel", "quelle", "quels", "quelles", "comment", "pourquoi", "quand", "combien",
        "tout", "tous", "toute", "toutes", "heure", "heures", "moment", "instant", "fois",
        "aujourd", "hui", "aujourdhui", "hier", "matin", "soir",
        "commande", "commandes", "terminal", "console", "historique", "souvenir", "souvenirs", "mémoire", "memoire",
        "dernier", "derniere", "dernière", "derniers", "dernières",
        "retrouve", "cherche", "donne", "moi", "trouve", "dis", "svp", "stp", "merci",
        "juste", "genre", "alors", "donc", "aussi", "bien", "encore"
    ]

    public func search(query: String, limit: Int = 5) -> [SemanticSearchResult] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }

        let queryTokens = tokenize(cleanQuery)
        let queryVector = embedding?.vector(for: cleanQuery)

        let candidates = store.loadAllForSearch(limit: 1500)
        let now = Date()

        let lowerQuery = cleanQuery.lowercased()
        let wantsCommand = lowerQuery.contains("commande") || lowerQuery.contains("terminal") ||
                           lowerQuery.contains("script") || lowerQuery.contains("shell") ||
                           lowerQuery.contains("bash") || lowerQuery.contains("cli") ||
                           lowerQuery.contains("docker") || lowerQuery.contains("ssh") ||
                           lowerQuery.contains("lancer") || lowerQuery.contains("build") ||
                           lowerQuery.contains("nas")

        let wantsClipboard = lowerQuery.contains("copi") || lowerQuery.contains("presse-papier") ||
                             lowerQuery.contains("clipboard")

        // Map conversational intention verbs to common CLI tokens
        var actionSynonyms: Set<String> = []
        if lowerQuery.contains("lancer") || lowerQuery.contains("demarrer") || lowerQuery.contains("démarrer") || lowerQuery.contains("start") {
            actionSynonyms.formUnion(["up", "start", "run"])
        } else if lowerQuery.contains("arreter") || lowerQuery.contains("arrêter") || lowerQuery.contains("stopper") || lowerQuery.contains("stop") {
            actionSynonyms.formUnion(["down", "stop", "kill"])
        } else if lowerQuery.contains("build") || lowerQuery.contains("construire") || lowerQuery.contains("compiler") {
            actionSynonyms.formUnion(["build", "compile", "make"])
        } else if lowerQuery.contains("log") || lowerQuery.contains("voir") || lowerQuery.contains("afficher") {
            actionSynonyms.formUnion(["logs", "log", "ps", "status"])
        }

        var results: [SemanticSearchResult] = []

        for item in candidates {
            let itemLower = item.text.lowercased()
            let rawCandidateTokens = Set(itemLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let itemTokens = tokenize(item.text)

            // 1. Lexical score (keyword overlap on informative tokens)
            let intersection = queryTokens.intersection(itemTokens).count
            let lexicalScore = queryTokens.isEmpty ? 0.0 : Double(intersection) / Double(queryTokens.count)

            // 2. Semantic score (cosine distance or embedding proximity)
            var semanticScore = 0.0
            if let queryVector, let itemVector = item.embedding, queryVector.count == itemVector.count {
                let sim = cosineSimilarity(queryVector, itemVector)
                semanticScore = max(0, min(1.0, (sim + 1.0) / 2.0))
            } else if let emb = embedding {
                let dist = emb.distance(between: cleanQuery, and: item.text)
                semanticScore = max(0, min(1.0, 1.0 - dist))
            }

            // 3. Recency boost (items from last 48h get up to +12% boost)
            let ageHours = max(0, now.timeIntervalSince(item.timestamp) / 3600.0)
            let recencyBonus = max(0.0, (1.0 - min(ageHours / 48.0, 1.0)) * 0.12)

            // 4. Intent boost for category
            var categoryBonus = 0.0
            if wantsCommand {
                if item.category == .terminal {
                    categoryBonus = 0.22
                } else if item.category == .clipboard {
                    categoryBonus = -0.15
                }
            } else if wantsClipboard {
                if item.category == .clipboard {
                    categoryBonus = 0.22
                }
            }

            // 5. Subject keyword alignment (favors items containing the specific subject tokens)
            var subjectBonus = 0.0
            if !queryTokens.isEmpty {
                let matchedTokens = queryTokens.filter { rawCandidateTokens.contains($0) }
                if !matchedTokens.isEmpty {
                    let hitRatio = Double(matchedTokens.count) / Double(queryTokens.count)
                    subjectBonus = 0.30 * hitRatio
                } else {
                    subjectBonus = -0.35
                }
            }

            // 6. Action alignment bonus (e.g. "lancer" query with "up" command)
            let actionBonus = actionSynonyms.isDisjoint(with: rawCandidateTokens) ? 0.0 : 0.18

            // Combined composite score
            let compositeScore = (lexicalScore * 0.35) + (semanticScore * 0.25) + recencyBonus + categoryBonus + subjectBonus + actionBonus

            if compositeScore >= 0.28 || lexicalScore >= 0.35 {
                let reason: String
                if lexicalScore >= 0.60 {
                    reason = "Correspondance exacte"
                } else if semanticScore >= 0.70 {
                    reason = "Similarité sémantique"
                } else {
                    reason = "Pertinence contextuelle"
                }

                results.append(SemanticSearchResult(item: item, score: compositeScore, matchReason: reason))
            }
        }

        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    private func tokenize(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let tokens = words.map(String.init).filter { $0.count >= 2 }
        let filtered = tokens.filter { !Self.searchStopWords.contains($0) }
        return filtered.isEmpty ? Set(tokens) : Set(filtered)
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
        }
        for v in a { normA += v * v }
        for v in b { normB += v * v }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Voice Intent Detection

    private static let memoryQueryTriggers: [String] = [
        "wisper retrouve",
        "dis wisper retrouve",
        "wisper cherche",
        "retrouve-moi",
        "retrouve moi",
        "retrouve",
        "c'était quoi",
        "c etait quoi",
        "cherche dans ma mémoire",
        "cherche dans la mémoire",
        "cherche dans mon historique",
        "quel était le",
        "quelle était la",
        "qu'est-ce que j'ai copié",
        "qu est ce que j ai copie",
        "qu'ai-je copié",
        "qu ai je copie",
        "find my",
        "what was the"
    ]

    public static func isMemorySearchQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var cleaned = trimmed.lowercased()
        cleaned = cleaned.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "!", with: " ")

        let words = cleaned.split(separator: " ").map(String.init)
        // A memory lookup is a short spoken command, not a paragraph of dictation.
        guard words.count <= maxMemoryQueryWords else { return false }
        var normalized = words.joined(separator: " ")

        // Only a command at the START of the utterance counts, after an optional
        // wake word. Matching anywhere hijacked ordinary sentences such as
        // "j'ai retrouvé mes clés" or "what was the plan", so the dictation was
        // swallowed and an old memory was offered for copying instead.
        for wakeWord in ["dis wisper ", "wisper "] where normalized.hasPrefix(wakeWord) {
            normalized.removeFirst(wakeWord.count)
            break
        }

        for trigger in memoryQueryTriggers where normalized.hasPrefix(trigger) {
            let rest = normalized.dropFirst(trigger.count)
            // Whole-word match: "retrouve" must not match "retrouvé" or "retrouvera".
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            return true
        }
        return false
    }

    private static let maxMemoryQueryWords = 14

    public static func extractSearchQuery(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        for trigger in memoryQueryTriggers {
            if let range = lower.range(of: trigger) {
                cleaned.removeSubrange(range)
                break
            }
        }

        // Clean up common leading words
        let prefixesToTrim = ["dis wisper", "wisper", " le ", " la ", " les ", " l'", " mon ", " ma ", " mes ", " que j'ai copié ", " d'hier", " ce matin"]
        for p in prefixesToTrim {
            if let range = cleaned.range(of: p, options: .caseInsensitive) {
                let replacement = (p.hasPrefix(" ") && p.hasSuffix(" ")) ? " " : ""
                cleaned.replaceSubrange(range, with: replacement)
            }
        }

        let result = cleaned.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return result.isEmpty ? text : result
    }
}
