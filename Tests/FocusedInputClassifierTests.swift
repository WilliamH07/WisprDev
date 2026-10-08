import Foundation

struct FocusedInputClassifierTests {
    static func run() {
        func focused(_ probe: FocusedInputProbe) -> Bool {
            FocusedInputClassifier.isTextInputFocused(probe)
        }
        // Apps that do not answer Accessibility queries must not block pasting.
        TestSupport.expect(focused(FocusedInputProbe(status: .unavailable)), "unavailable AX should paste")
        TestSupport.expect(!focused(FocusedInputProbe(status: .nothingFocused)), "explicit no-focus should not paste")
        TestSupport.expect(focused(FocusedInputProbe(status: .found, role: "AXTextArea")), "text area")
        TestSupport.expect(focused(FocusedInputProbe(status: .found, role: "AXSearchField")), "search field")
        TestSupport.expect(focused(FocusedInputProbe(status: .found, role: "AXWebArea")), "web content")
        TestSupport.expect(
            focused(FocusedInputProbe(status: .found, role: "AXGroup", hasSelectedTextRange: true)),
            "custom editor exposing a caret"
        )
        TestSupport.expect(
            focused(FocusedInputProbe(status: .found, role: "AXGroup", isMarkedEditable: true)),
            "AXEditable element"
        )
        TestSupport.expect(!focused(FocusedInputProbe(status: .found, role: "AXButton")), "button is not a text input")
        TestSupport.expect(!focused(FocusedInputProbe(status: .found, role: "AXGroup")), "bare group is not a text input")
    }
}
