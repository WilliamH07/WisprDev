import Foundation
import AppKit

enum ShortcutCoreTests {
    static func run() {
        testBareFnHoldLifecycle()
        testDefaultShortcutSpecificityOrdering()
        testRightOptionPresetIsSideSpecific()
        testExactModifierMatching()
        testReducerHonorsExactModifierMatching()
        testRepeatedKeyDownDoesNotReactivate()
        testPasteAgainFiresOnLeadingEdgeOnly()
        testRewriteSelectionFiresOnLeadingEdgeOnly()
        testRewriteSelectionRightOptionLifecycle()
        testRewriteSelectionCustomKeyHasPressedShortcutInputs()
        testModifierKeyEventStateMissingDeviceBitsFallback()
        testModifierKeyEventStateIsKeyDown()
        testRewriteSelectionKeyComboLifecycleWithSnapshotReconciliation()
        testBackendResetClearsActiveBindings()
        testBindingMigrationAndIdentity()
        testConflictDetection()
        testHoldSessionControllerLifecycle()
        testToggleSessionControllerLifecycle()
        testHoldToToggleSessionControllerLifecycle()
    }

    private static func testBareFnHoldLifecycle() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .disabled)
        let down = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: down.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        TestSupport.expectEqual(down.emittedEvents, [.holdActivated])
        TestSupport.expectEqual(down.consumeDecision, .consume)
        TestSupport.expectEqual(up.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(up.consumeDecision, .consume)
    }

    private static func testDefaultShortcutSpecificityOrdering() {
        let configuration = ShortcutConfiguration(
            hold: .defaultHold,
            toggle: .defaultToggle
        )
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let fnUp = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        TestSupport.expectEqual(fnDown.emittedEvents, [.toggleActivated, .holdActivated])
        TestSupport.expectEqual(fnUp.emittedEvents, [.holdDeactivated, .toggleDeactivated])
    }

    private static func testRightOptionPresetIsSideSpecific() {
        let configuration = ShortcutConfiguration(
            hold: ShortcutPreset.rightOption.binding,
            toggle: .disabled
        )
        let leftOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 58, isDown: true),
            configuration: configuration
        )
        let rightOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )

        TestSupport.expectEqual(leftOption.emittedEvents, [])
        TestSupport.expectEqual(rightOption.emittedEvents, [.holdActivated])
    }

    private static func testExactModifierMatching() {
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch([54], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Right Command"
        )
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch([55], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Left Command"
        )
        TestSupport.expect(
            !ShortcutBinding.exactModifierKeyCodesMatch([55, 56], exactModifierKeyCodes: [55]),
            "Unexpected Shift should invalidate an exact Command binding"
        )
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch(
                [55, 56],
                exactModifierKeyCodes: [55],
                permittedAdditionalExactMatchModifiers: [.shift]
            ),
            "Explicitly permitted Shift should not invalidate an exact Command binding"
        )
    }

    private static func testReducerHonorsExactModifierMatching() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )

        let rightCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 54, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let rightCommandKey = ShortcutMatcher.reduce(
            state: rightCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(rightCommandKey.emittedEvents, [])

        let leftCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let leftCommandKey = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(leftCommandKey.emittedEvents, [.holdActivated])

        let shiftedState = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .modifierChanged(keyCode: 56, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let shiftedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(shiftedKey.emittedEvents, [])

        let permittedConfiguration = ShortcutConfiguration(
            hold: binding,
            toggle: .disabled,
            permittedAdditionalExactMatchModifiers: [.shift]
        )
        let permittedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: permittedConfiguration
        )
        TestSupport.expectEqual(permittedKey.emittedEvents, [.holdActivated])
    }

    private static func testRepeatedKeyDownDoesNotReactivate() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: binding, toggle: .disabled)
        let first = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: first.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )

        TestSupport.expectEqual(first.emittedEvents, [.holdActivated])
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(repeated.state, first.state)
        TestSupport.expectEqual(repeated.consumeDecision, .consume)
    }

    private static func testPasteAgainFiresOnLeadingEdgeOnly() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, copyAgain: binding)
        let firstDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: firstDown.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: repeated.state,
            event: .keyChanged(keyCode: 96, isDown: false, isRepeat: false),
            configuration: configuration
        )
        let secondDown = ShortcutMatcher.reduce(
            state: up.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )

        TestSupport.expectEqual(firstDown.emittedEvents, [.copyAgainTriggered])
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(up.emittedEvents, [])
        TestSupport.expectEqual(secondDown.emittedEvents, [.copyAgainTriggered])
    }

    private static func testRewriteSelectionFiresOnLeadingEdgeOnly() {
        let binding = ShortcutBinding(
            keyCode: 15,
            keyDisplay: "R",
            modifiers: [.control, .option],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, rewriteSelection: binding)
        let firstDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(pressedModifierKeyCodes: [58, 59]), // Option (58) + Control (59)
            event: .keyChanged(keyCode: 15, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: firstDown.state,
            event: .keyChanged(keyCode: 15, isDown: true, isRepeat: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: repeated.state,
            event: .keyChanged(keyCode: 15, isDown: false, isRepeat: false),
            configuration: configuration
        )
        let secondDown = ShortcutMatcher.reduce(
            state: up.state,
            event: .keyChanged(keyCode: 15, isDown: true, isRepeat: false),
            configuration: configuration
        )

        TestSupport.expectEqual(firstDown.emittedEvents, [.rewriteSelectionTriggered])
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(up.emittedEvents, [])
        TestSupport.expectEqual(secondDown.emittedEvents, [.rewriteSelectionTriggered])
    }

    private static func testRewriteSelectionRightOptionLifecycle() {
        let configuration = ShortcutConfiguration(
            hold: .defaultHold,
            toggle: .disabled,
            rewriteSelection: ShortcutPreset.rightOption.binding
        )
        // Left Option down should trigger rewrite selection
        let leftOptionDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 58, isDown: true),
            configuration: configuration
        )
        TestSupport.expectEqual(leftOptionDown.emittedEvents, [.rewriteSelectionTriggered])
        TestSupport.expectEqual(leftOptionDown.consumeDecision, .consume)
        TestSupport.expect(leftOptionDown.state.hasPressedShortcutInputs(configuration: configuration), "Left Option should be detected as pressed input")

        let leftOptionUp = ShortcutMatcher.reduce(
            state: leftOptionDown.state,
            event: .modifierChanged(keyCode: 58, isDown: false),
            configuration: configuration
        )
        TestSupport.expectEqual(leftOptionUp.emittedEvents, [])
        TestSupport.expect(!leftOptionUp.state.hasPressedShortcutInputs(configuration: configuration), "Left Option should no longer be detected after release")

        // Right Option down should also trigger rewrite selection
        let rightOptionDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )
        TestSupport.expectEqual(rightOptionDown.emittedEvents, [.rewriteSelectionTriggered])
        TestSupport.expectEqual(rightOptionDown.consumeDecision, .consume)
        TestSupport.expect(rightOptionDown.state.hasPressedShortcutInputs(configuration: configuration), "Right Option should be detected as pressed input")

        let rightOptionUp = ShortcutMatcher.reduce(
            state: rightOptionDown.state,
            event: .modifierChanged(keyCode: 61, isDown: false),
            configuration: configuration
        )
        TestSupport.expectEqual(rightOptionUp.emittedEvents, [])
        TestSupport.expect(!rightOptionUp.state.hasPressedShortcutInputs(configuration: configuration), "Right Option should no longer be detected after release")
    }

    private static func testRewriteSelectionCustomKeyHasPressedShortcutInputs() {
        let binding = ShortcutBinding(
            keyCode: 15,
            keyDisplay: "R",
            modifiers: [.control, .option],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(
            hold: .defaultHold,
            toggle: .disabled,
            rewriteSelection: binding
        )
        let modState = ShortcutInputState(pressedModifierKeyCodes: [58, 59])
        TestSupport.expect(modState.hasPressedShortcutInputs(configuration: configuration), "Modifiers for custom shortcut should be detected as pressed")

        let keyState = ShortcutInputState(pressedKeyCodes: [15], pressedModifierKeyCodes: [58, 59])
        TestSupport.expect(keyState.hasPressedShortcutInputs(configuration: configuration), "Key and modifiers should be detected as pressed")

        let releasedState = ShortcutInputState()
        TestSupport.expect(!releasedState.hasPressedShortcutInputs(configuration: configuration), "Released state should not have pressed inputs")
    }

    private static func testModifierKeyEventStateMissingDeviceBitsFallback() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "r",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15
        ) else {
            TestSupport.expect(false, "Failed to create synthetic keyDown NSEvent")
            return
        }

        // When device-specific raw flags are not present (typical for .keyDown events),
        // pressedModifierKeyCodes must fall back to generic flags rather than returning an empty set.
        let detectedCanonical = ModifierKeyEventState.pressedModifierKeyCodes(for: event)
        TestSupport.expectEqual(detectedCanonical, [58, 59])

        // When currentlyPressedKeyCodes has side-specific information (e.g. Right Option 61 and Right Control 62),
        // reconciliation should preserve the specific key codes.
        let detectedPreserved = ModifierKeyEventState.pressedModifierKeyCodes(
            for: event,
            currentlyPressedKeyCodes: [61, 62]
        )
        TestSupport.expectEqual(detectedPreserved, [61, 62])
    }

    private static func testModifierKeyEventStateIsKeyDown() {
        let cgEvent = CGEvent(source: nil)
        cgEvent?.type = .flagsChanged
        cgEvent?.setIntegerValueField(.keyboardEventKeycode, value: 61) // Right Option
        cgEvent?.flags = [.maskAlternate]

        guard let cg = cgEvent, let nsEvent = NSEvent(cgEvent: cg) else {
            TestSupport.expect(false, "Failed to create synthetic flagsChanged NSEvent")
            return
        }

        // Even if device-specific bits are not set in the event flags, isKeyDown must recognize Option is pressed
        let isDown = ModifierKeyEventState.isKeyDown(for: nsEvent)
        TestSupport.expectEqual(isDown, true)

        // When option flag is removed, isKeyDown should report false
        cg.flags = []
        if let releasedEvent = NSEvent(cgEvent: cg) {
            TestSupport.expectEqual(ModifierKeyEventState.isKeyDown(for: releasedEvent), false)
        }
    }

    private static func testRewriteSelectionKeyComboLifecycleWithSnapshotReconciliation() {
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            rewriteSelection: .defaultRewriteSelection
        )

        // 1. User presses Control (59)
        let ctrlDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 59, isDown: true),
            configuration: configuration
        )
        TestSupport.expectEqual(ctrlDown.state.pressedModifierKeyCodes, [59])

        // 2. User presses Option (58)
        let optDown = ShortcutMatcher.reduce(
            state: ctrlDown.state,
            event: .modifierChanged(keyCode: 58, isDown: true),
            configuration: configuration
        )
        TestSupport.expectEqual(optDown.state.pressedModifierKeyCodes, [58, 59])

        // 3. User presses 'R' (keyCode 15):
        // GlobalShortcutBackend reconciles modifierSnapshot and emits keyChanged
        let snapshotResult = ShortcutMatcher.reduce(
            state: optDown.state,
            event: .modifierSnapshot([58, 59]),
            configuration: configuration
        )
        TestSupport.expectEqual(snapshotResult.state.pressedModifierKeyCodes, [58, 59])

        let keyDownResult = ShortcutMatcher.reduce(
            state: snapshotResult.state,
            event: .keyChanged(keyCode: 15, isDown: true, isRepeat: false),
            configuration: configuration
        )
        TestSupport.expectEqual(keyDownResult.emittedEvents, [.rewriteSelectionTriggered])
        TestSupport.expectEqual(keyDownResult.consumeDecision, .consume)

        // 4. Test that right-side modifiers (61 and 62) also trigger defaultRewriteSelection
        let rightSideState = ShortcutInputState(pressedModifierKeyCodes: [61, 62])
        let rightSideKeyDown = ShortcutMatcher.reduce(
            state: rightSideState,
            event: .keyChanged(keyCode: 15, isDown: true, isRepeat: false),
            configuration: configuration
        )
        TestSupport.expectEqual(rightSideKeyDown.emittedEvents, [.rewriteSelectionTriggered])
    }

    private static func testBackendResetClearsActiveBindings() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let reset = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .backendReset,
            configuration: configuration
        )

        TestSupport.expectEqual(reset.emittedEvents, [.holdDeactivated, .toggleDeactivated])
        TestSupport.expectEqual(reset.consumeDecision, .passthrough)
        TestSupport.expect(reset.state.pressedKeyCodes.isEmpty, "Backend reset should clear pressed keys")
        TestSupport.expect(reset.state.pressedModifierKeyCodes.isEmpty, "Backend reset should clear modifiers")
        TestSupport.expect(!reset.state.holdIsActive && !reset.state.toggleIsActive, "Backend reset should clear active bindings")
    }

    private static func testBindingMigrationAndIdentity() {
        let stored = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [999, 61]
        )
        let normalized = stored.normalizedForStorageMigration()
        TestSupport.expectEqual(normalized.exactModifierKeyCodes, [61])
        TestSupport.expectEqual(normalized.modifiers, [.option])

        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55, 58]
        )
        let second = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.option, .command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [58, 55]
        )
        TestSupport.expectEqual(first.id, second.id)
    }

    private static func testConflictDetection() {
        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let same = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let different = ShortcutBinding(
            keyCode: 97,
            keyDisplay: "F6",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )

        TestSupport.expect(first.conflicts(with: same), "Equivalent bindings should conflict")
        TestSupport.expect(same.conflicts(with: first), "Conflict detection should be symmetric")
        TestSupport.expect(!first.conflicts(with: different), "Different primary keys should not conflict")
        TestSupport.expect(!first.conflicts(with: .disabled), "Disabled bindings should not conflict")
    }

    private static func testHoldSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: true), nil)
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.toggleStopArmed, true)
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testHoldToToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.activeMode, .toggle)
        TestSupport.expectEqual(controller.handle(event: .copyAgainTriggered, isTranscribing: false), nil)
        controller.beginManual(mode: .hold)
        TestSupport.expectEqual(controller.activeMode, .hold)
        controller.forceToggleMode()
        TestSupport.expectEqual(controller.activeMode, .toggle)
        controller.reset()
        TestSupport.expectEqual(controller.activeMode, nil)
        TestSupport.expectEqual(controller.toggleStopArmed, false)
    }
}
