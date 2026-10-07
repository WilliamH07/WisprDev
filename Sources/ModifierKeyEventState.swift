import AppKit
import Carbon.HIToolbox

enum ModifierKeyEventState {
    static func isKeyDown(for event: NSEvent) -> Bool? {
        guard let mappedFlag = mappedFlag(for: event.keyCode) else {
            return nil
        }
        if event.modifierFlags.contains(mappedFlag) {
            return true
        }
        // Fallback: Check the generic logical modifier flag
        if let logical = ShortcutBinding.logicalModifier(forKeyCode: event.keyCode),
           let generic = genericFlag(for: logical) {
            return event.modifierFlags.contains(generic)
        }
        return false
    }

    static func pressedModifierKeyCodes(
        for event: NSEvent,
        trustedFunctionKeyIsDown: Bool? = nil,
        currentlyPressedKeyCodes: Set<UInt16> = []
    ) -> Set<UInt16> {
        var result: Set<UInt16> = []
        let flags = event.modifierFlags
        let hasDeviceBits = (flags.rawValue & 0xFFFF) != 0

        // 1. Shift (Left: 56, Right: 60)
        if flags.contains(.shift) {
            var shiftAdded = false
            if hasDeviceBits {
                if flags.contains(.leftShift) { result.insert(56); shiftAdded = true }
                if flags.contains(.rightShift) { result.insert(60); shiftAdded = true }
            }
            if !shiftAdded {
                if currentlyPressedKeyCodes.contains(60) {
                    result.insert(60)
                } else if currentlyPressedKeyCodes.contains(56) {
                    result.insert(56)
                } else {
                    result.insert(56)
                }
            }
        }

        // 2. Control (Left: 59, Right: 62)
        if flags.contains(.control) {
            var controlAdded = false
            if hasDeviceBits {
                if flags.contains(.leftControl) { result.insert(59); controlAdded = true }
                if flags.contains(.rightControl) { result.insert(62); controlAdded = true }
            }
            if !controlAdded {
                if currentlyPressedKeyCodes.contains(62) {
                    result.insert(62)
                } else if currentlyPressedKeyCodes.contains(59) {
                    result.insert(59)
                } else {
                    result.insert(59)
                }
            }
        }

        // 3. Option (Left: 58, Right: 61)
        if flags.contains(.option) {
            var optionAdded = false
            if hasDeviceBits {
                if flags.contains(.leftOption) { result.insert(58); optionAdded = true }
                if flags.contains(.rightOption) { result.insert(61); optionAdded = true }
            }
            if !optionAdded {
                if currentlyPressedKeyCodes.contains(61) {
                    result.insert(61)
                } else if currentlyPressedKeyCodes.contains(58) {
                    result.insert(58)
                } else {
                    result.insert(58)
                }
            }
        }

        // 4. Command (Left: 55, Right: 54)
        if flags.contains(.command) {
            var commandAdded = false
            if hasDeviceBits {
                if flags.contains(.leftCommand) { result.insert(55); commandAdded = true }
                if flags.contains(.rightCommand) { result.insert(54); commandAdded = true }
            }
            if !commandAdded {
                if currentlyPressedKeyCodes.contains(54) {
                    result.insert(54)
                } else if currentlyPressedKeyCodes.contains(55) {
                    result.insert(55)
                } else {
                    result.insert(55)
                }
            }
        }

        // 5. Function (Fn: 63)
        if let trustedFunctionKeyIsDown {
            if trustedFunctionKeyIsDown {
                result.insert(fnKeyCode)
            }
        } else if flags.contains(.function) {
            result.insert(fnKeyCode)
        }

        return result
    }

    static let fnKeyCode: UInt16 = 63

    /// Reads the current system-wide Fn state. Useful for seeding a backend's
    /// tracked Fn state at start or after a tap reset, since flagsChanged events
    /// don't fire for keys already held when a monitor begins.
    static func currentFunctionKeyIsDown() -> Bool {
        NSEvent.modifierFlags.contains(.function)
    }

    private static func mappedFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54:
            return .rightCommand
        case 55:
            return .leftCommand
        case 56:
            return .leftShift
        case 58:
            return .leftOption
        case 59:
            return .leftControl
        case 60:
            return .rightShift
        case 61:
            return .rightOption
        case 62:
            return .rightControl
        case 63:
            return .function
        default:
            return nil
        }
    }

    private static func genericFlag(for modifier: ShortcutModifiers) -> NSEvent.ModifierFlags? {
        if modifier.contains(.command) { return .command }
        if modifier.contains(.control) { return .control }
        if modifier.contains(.option) { return .option }
        if modifier.contains(.shift) { return .shift }
        if modifier.contains(.function) { return .function }
        return nil
    }
}

private extension NSEvent.ModifierFlags {
    static let leftControl = Self(rawValue: UInt(NX_DEVICELCTLKEYMASK))
    static let leftShift = Self(rawValue: UInt(NX_DEVICELSHIFTKEYMASK))
    static let rightShift = Self(rawValue: UInt(NX_DEVICERSHIFTKEYMASK))
    static let leftCommand = Self(rawValue: UInt(NX_DEVICELCMDKEYMASK))
    static let rightCommand = Self(rawValue: UInt(NX_DEVICERCMDKEYMASK))
    static let leftOption = Self(rawValue: UInt(NX_DEVICELALTKEYMASK))
    static let rightOption = Self(rawValue: UInt(NX_DEVICERALTKEYMASK))
    static let rightControl = Self(rawValue: UInt(NX_DEVICERCTLKEYMASK))
}
