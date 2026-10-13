import Foundation

/// A named folder of PDFs the Safari agent can draw on ("bibliothèque").
/// Only the list of files is persisted; extracted text lives in memory.
struct ReferenceLibrary: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var files: [ReferenceLibraryFile]
}

struct ReferenceLibraryFile: Codable, Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var path: String
    /// Finder bookmark so a moved or renamed PDF is still found.
    var bookmark: Data?
}

struct ReferencePassage: Equatable {
    let documentName: String
    let pageStart: Int
    let pageEnd: Int
    let text: String

    var tokens: Int { SafariAgentText.estimateTokens(text) }

    var citation: String {
        pageStart == pageEnd
            ? "\(documentName) p. \(pageStart)"
            : "\(documentName) p. \(pageStart)-\(pageEnd)"
    }
}

struct ReferencePageText: Equatable {
    let number: Int
    let text: String
}

/// Splits extracted PDF pages into passages of roughly `targetCharacters`,
/// breaking on paragraph and then sentence boundaries, and remembering the
/// page range each passage comes from so answers can cite it.
enum ReferencePassageChunker {
    static func passages(
        documentName: String,
        pages: [ReferencePageText],
        targetCharacters: Int = 1100,
        maxCharacters: Int = 1600
    ) -> [ReferencePassage] {
        var passages: [ReferencePassage] = []
        var buffer = ""
        var bufferStart = 0
        var bufferEnd = 0

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                passages.append(ReferencePassage(documentName: documentName, pageStart: bufferStart, pageEnd: bufferEnd, text: text))
            }
            buffer = ""
        }

        func append(_ piece: String, page: Int) {
            if buffer.isEmpty {
                bufferStart = page
            } else if buffer.count + piece.count + 1 > maxCharacters {
                flush()
                bufferStart = page
            }
            buffer += buffer.isEmpty ? piece : "\n" + piece
            bufferEnd = page
            if buffer.count >= targetCharacters {
                flush()
            }
        }

        for page in pages {
            for paragraph in paragraphs(in: page.text) {
                if paragraph.count <= maxCharacters {
                    append(paragraph, page: page.number)
                } else {
                    for piece in sentencePieces(paragraph, maxCharacters: maxCharacters) {
                        append(piece, page: page.number)
                    }
                }
            }
        }
        flush()
        return passages
    }

    static func paragraphs(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { SafariAgentText.collapseWhitespace($0) }
            .filter { !$0.isEmpty }
    }

    /// Breaks an oversized paragraph after sentence punctuation; falls back to
    /// hard cuts for text without punctuation (tables, OCR noise).
    static func sentencePieces(_ text: String, maxCharacters: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var sentence = ""
        for character in text {
            sentence.append(character)
            if ".!?;".contains(character) || sentence.count >= maxCharacters {
                if current.count + sentence.count > maxCharacters, !current.isEmpty {
                    pieces.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
                current += sentence
                sentence = ""
            }
        }
        if current.count + sentence.count > maxCharacters, !current.isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        current += sentence
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            pieces.append(tail)
        }
        return pieces
    }
}

/// An indexed, ready-to-query view of one library.
struct ReferenceLibrarySnapshot {
    let libraryName: String
    let passages: [ReferencePassage]
    let index: SafariAgentLexicalIndex
    let totalTokens: Int

    init(libraryName: String, passages: [ReferencePassage]) {
        self.libraryName = libraryName
        self.passages = passages
        self.index = SafariAgentLexicalIndex(texts: passages.map(\.text))
        self.totalTokens = passages.reduce(0) { $0 + $1.tokens }
    }

    /// Best passages for `query` that fit in `budgetTokens`, in rank order.
    func passages(for query: String, budgetTokens: Int) -> [ReferencePassage] {
        var remaining = budgetTokens
        var selected: [ReferencePassage] = []
        for index in index.rankedIndices(for: query) {
            let passage = passages[index]
            guard passage.tokens <= remaining else { continue }
            selected.append(passage)
            remaining -= passage.tokens
            if remaining < 80 { break }
        }
        return selected
    }
}

enum ReferenceLibraryCatalog {
    static func load(from url: URL) -> [ReferenceLibrary] {
        guard let data = try? Data(contentsOf: url),
              let libraries = try? JSONDecoder().decode([ReferenceLibrary].self, from: data) else {
            return []
        }
        return libraries
    }

    static func save(_ libraries: [ReferenceLibrary], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(libraries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
