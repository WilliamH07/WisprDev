import Foundation

/// What Accessibility could tell us about the current selection.
enum SelectionEvidence: Equatable {
    /// The focused element reports selected text.
    case text(String)
    /// The focused element answered and confirmed that nothing is selected
    /// (the caret is just sitting in a field).
    case caretOnly
    /// The app does not expose selection state (some browsers, Electron, custom editors).
    case unknown
}

enum SelectionDecision: Equatable {
    case rewrite(String)
    /// Nothing is selected: do nothing, press no keys.
    case abortNoSelection
    /// Selection could not be read directly; the clipboard fallback may be tried.
    case tryClipboardCopy
}

/// Decides whether a rewrite may start. A rewrite must never operate on text the
/// user did not select, so a confirmed empty selection stops everything before any
/// synthetic keystroke (a Cmd-C with no selection copies the whole line in some editors).
enum SelectionGate {
    static func decide(_ evidence: SelectionEvidence) -> SelectionDecision {
        switch evidence {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .abortNoSelection : .rewrite(trimmed)
        case .caretOnly:
            return .abortNoSelection
        case .unknown:
            return .tryClipboardCopy
        }
    }

    /// Accepts text obtained through the Cmd-C fallback only if the pasteboard
    /// really changed and holds something other than whitespace.
    static func usableCopiedText(copied: String?, changeCountChanged: Bool) -> String? {
        guard changeCountChanged, let copied else { return nil }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
