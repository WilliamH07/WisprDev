import Foundation

public enum SemanticMemoryCategory: String, Codable, CaseIterable, Sendable {
    case clipboard = "clipboard"
    case dictation = "dictation"
    case rewrite = "rewrite"
    case terminal = "terminal"
    case manualNote = "manual_note"

    public var displayName: String {
        switch self {
        case .clipboard: return "Presse-papiers"
        case .dictation: return "Dictée vocale"
        case .rewrite: return "Réécriture"
        case .terminal: return "Terminal"
        case .manualNote: return "Note"
        }
    }

    public var iconName: String {
        switch self {
        case .clipboard: return "doc.on.doc.fill"
        case .dictation: return "waveform"
        case .rewrite: return "sparkles"
        case .terminal: return "terminal.fill"
        case .manualNote: return "note.text"
        }
    }
}

public struct SemanticMemoryItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let text: String
    public let snippet: String
    public let sourceAppName: String
    public let sourceWindowTitle: String?
    public let category: SemanticMemoryCategory
    public var embedding: [Double]?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        snippet: String? = nil,
        sourceAppName: String = "",
        sourceWindowTitle: String? = nil,
        category: SemanticMemoryCategory = .clipboard,
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        if let snippet {
            self.snippet = snippet
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 90 {
                self.snippet = trimmed
            } else {
                let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 89)
                self.snippet = String(trimmed[..<cutoff]) + "…"
            }
        }
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.category = category
        self.embedding = embedding
    }
}

public struct SemanticSearchResult: Identifiable, Sendable {
    public var id: UUID { item.id }
    public let item: SemanticMemoryItem
    public let score: Double
    public let matchReason: String

    public init(item: SemanticMemoryItem, score: Double, matchReason: String) {
        self.item = item
        self.score = score
        self.matchReason = matchReason
    }
}
