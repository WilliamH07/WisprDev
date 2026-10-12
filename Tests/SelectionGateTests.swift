import Foundation

struct SelectionGateTests {
    static func run() {
        TestSupport.expectEqual(SelectionGate.decide(.text("  hello world \n")), .rewrite("hello world"))
        TestSupport.expectEqual(SelectionGate.decide(.text("   \n ")), .abortNoSelection)
        TestSupport.expectEqual(SelectionGate.decide(.caretOnly), .abortNoSelection)
        TestSupport.expectEqual(SelectionGate.decide(.unknown), .tryClipboardCopy)

        TestSupport.expect(
            SelectionGate.usableCopiedText(copied: "stale text", changeCountChanged: false) == nil,
            "an unchanged pasteboard must not be treated as a selection"
        )
        TestSupport.expect(
            SelectionGate.usableCopiedText(copied: "  \n", changeCountChanged: true) == nil,
            "whitespace is not a selection"
        )
        TestSupport.expect(
            SelectionGate.usableCopiedText(copied: nil, changeCountChanged: true) == nil,
            "no string on the pasteboard"
        )
        TestSupport.expectEqual(
            SelectionGate.usableCopiedText(copied: " picked text ", changeCountChanged: true) ?? "",
            "picked text"
        )
    }
}
