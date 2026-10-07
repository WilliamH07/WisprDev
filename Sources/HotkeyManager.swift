import Cocoa
import os

final class HotkeyManager {
    private let recordingLog = OSLog(subsystem: "com.williamh07.wisper", category: "Recording")
    private let backend = GlobalShortcutBackend()
    private var configuration = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle
    )
    private var inputState = ShortcutInputState()

    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onEscapeKeyPressed: (() -> Bool)?

    var currentPressedModifiers: ShortcutModifiers {
        inputState.currentModifiers
    }

    var hasPressedShortcutInputs: Bool {
        inputState.hasPressedShortcutInputs(configuration: configuration)
    }

    var isRunning: Bool {
        backend.isRunning
    }

    func updateConfiguration(_ configuration: ShortcutConfiguration) {
        self.configuration = configuration
        inputState = ShortcutInputState()
    }

    func start(configuration: ShortcutConfiguration) throws {
        stop()
        self.configuration = configuration
        backend.onInputEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? .passthrough
        }
        backend.onEscapeKeyPressed = { [weak self] in
            self?.onEscapeKeyPressed?() ?? false
        }
        do {
            try backend.start()
        } catch {
            backend.onInputEvent = nil
            backend.onEscapeKeyPressed = nil
            inputState = ShortcutInputState()
            throw error
        }
    }

    func stop() {
        backend.stop()
        backend.onInputEvent = nil
        backend.onEscapeKeyPressed = nil
        inputState = ShortcutInputState()
    }

    deinit {
        stop()
    }

    private func handleInputEvent(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        for event in result.emittedEvents {
            os_log(.info, log: recordingLog, "HotkeyManager emitted event: %{public}@", String(describing: event))
            onShortcutEvent?(event)
        }
        return result.consumeDecision
    }
}
