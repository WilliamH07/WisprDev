import Cocoa
import os.log

private let shortcutLog = OSLog(subsystem: "com.williamh07.wisper", category: "Shortcuts")
private let recordingLog = OSLog(subsystem: "com.williamh07.wisper", category: "Recording")

enum GlobalShortcutBackendError: LocalizedError {
    case eventTapUnavailable
    case eventTapRunLoopSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "Global shortcut monitoring could not start. \(AppName.displayName) requires keyboard monitoring permission for global shortcuts."
        case .eventTapRunLoopSourceUnavailable:
            return "Global shortcut monitoring could not start because the event tap run loop source could not be created."
        }
    }
}

final class GlobalShortcutBackend {
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var fnKeyIsDown = false
    private var pressedModifierKeyCodes: Set<UInt16> = []

    var onInputEvent: ((ShortcutInputEvent) -> ShortcutConsumeDecision)?
    var onEscapeKeyPressed: (() -> Bool)?

    var isRunning: Bool {
        eventTap != nil
    }

    func start() throws {
        stop()
        try installEventTap()
        fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
    }

    func stop() {
        tearDownEventTap()
        notifyBackendReset()
    }

    deinit {
        stop()
    }

    private func installEventTap() throws {
        let eventMask = [
            CGEventType.flagsChanged,
            CGEventType.keyDown,
            CGEventType.keyUp
        ].reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let backend = Unmanaged<GlobalShortcutBackend>.fromOpaque(userInfo).takeUnretainedValue()
            return backend.handleEventTap(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            os_log(.error, log: shortcutLog, "Failed to install global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            os_log(.error, log: shortcutLog, "Failed to create run loop source for global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapRunLoopSourceUnavailable
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
        os_log(.info, log: recordingLog, "GlobalShortcutBackend: Event tap installed successfully")
    }

    private func tearDownEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapRunLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private func notifyBackendReset() {
        fnKeyIsDown = false
        pressedModifierKeyCodes.removeAll()
        _ = onInputEvent?(.backendReset)
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            notifyBackendReset()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }

            let shouldConsume: Bool
            switch type {
            case .flagsChanged:
                shouldConsume = handleFlagsChanged(nsEvent)
            case .keyDown:
                shouldConsume = handleKeyDown(nsEvent)
            case .keyUp:
                shouldConsume = handleKeyUp(nsEvent)
            default:
                shouldConsume = false
            }

            return shouldConsume ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else {
            return false
        }
        guard let isDown = ModifierKeyEventState.isKeyDown(for: event) else {
            os_log(.info, log: recordingLog, "flagsChanged: keyCode=%d could not determine isDown, flags=0x%lx", event.keyCode, event.modifierFlags.rawValue)
            return false
        }

        if isDown {
            pressedModifierKeyCodes.insert(event.keyCode)
        } else {
            pressedModifierKeyCodes.remove(event.keyCode)
        }

        if event.keyCode == ModifierKeyEventState.fnKeyCode {
            fnKeyIsDown = isDown
        }

        os_log(.info, log: recordingLog, "flagsChanged: keyCode=%d isDown=%d pressedModifiers=%{public}@", event.keyCode, isDown ? 1 : 0, String(describing: pressedModifierKeyCodes))

        return onInputEvent?(.modifierChanged(keyCode: event.keyCode, isDown: isDown)) == .consume
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            guard !event.isARepeat else { return false }
            return onEscapeKeyPressed?() ?? false
        }

        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotModifiers = ModifierKeyEventState.pressedModifierKeyCodes(
            for: event,
            trustedFunctionKeyIsDown: fnKeyIsDown,
            currentlyPressedKeyCodes: pressedModifierKeyCodes
        )
        pressedModifierKeyCodes = snapshotModifiers
        let snapshotDecision = onInputEvent?(.modifierSnapshot(snapshotModifiers)) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: true, isRepeat: event.isARepeat)
        ) ?? .passthrough
        os_log(.info, log: recordingLog, "keyDown: keyCode=%d repeat=%d modifiers=%{public}@ decision=%{public}@", event.keyCode, event.isARepeat ? 1 : 0, String(describing: snapshotModifiers), keyDecision == .consume ? "consume" : "passthrough")
        return snapshotDecision == .consume || keyDecision == .consume
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotModifiers = ModifierKeyEventState.pressedModifierKeyCodes(
            for: event,
            trustedFunctionKeyIsDown: fnKeyIsDown,
            currentlyPressedKeyCodes: pressedModifierKeyCodes
        )
        pressedModifierKeyCodes = snapshotModifiers
        let snapshotDecision = onInputEvent?(.modifierSnapshot(snapshotModifiers)) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: false, isRepeat: false)
        ) ?? .passthrough
        return snapshotDecision == .consume || keyDecision == .consume
    }
}
