import Foundation

/// Raw Accessibility observations about the element that has keyboard focus.
/// Kept free of AppKit types so the decision rules can be unit tested.
struct FocusedInputProbe: Equatable {
    enum FocusStatus: Equatable {
        /// The app returned a focused element.
        case found
        /// The app explicitly reported that nothing is focused.
        case nothingFocused
        /// The app does not answer Accessibility queries (Electron, Java, games,
        /// timeouts). Absence of an answer is not evidence that no field is focused.
        case unavailable
    }

    var status: FocusStatus
    var role: String?
    var hasSelectedTextRange = false
    var hasInsertionPointLine = false
    var isValueSettable = false
    var isMarkedEditable = false
}

enum FocusedInputClassifier {
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]
    // Browser content and custom editors (Notion, VS Code, Slack...) often expose
    // only a container role while a caret is active.
    private static let containerRoles: Set<String> = [
        "AXWebArea", "AXGroup", "AXScrollArea"
    ]

    /// Returns true when pasting is likely to land in an editable field.
    /// Errs on the side of pasting: a stray Cmd-V is harmless, while wrongly
    /// showing only a "copy" popup discards the user's dictation.
    static func isTextInputFocused(_ probe: FocusedInputProbe) -> Bool {
        switch probe.status {
        case .unavailable:
            return true
        case .nothingFocused:
            return false
        case .found:
            break
        }
        if let role = probe.role, textRoles.contains(role) { return true }
        if probe.isMarkedEditable || probe.hasSelectedTextRange || probe.hasInsertionPointLine || probe.isValueSettable {
            return true
        }
        if let role = probe.role, containerRoles.contains(role) {
            return role == "AXWebArea"
        }
        return false
    }
}
