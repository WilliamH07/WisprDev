import AppKit
import SwiftUI

@MainActor
final class AIAssistantWindowManager: ObservableObject {
    static let shared = AIAssistantWindowManager()

    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private init() {}

    func toggle(appState: AppState) {
        if isVisible {
            hide()
        } else {
            show(appState: appState)
        }
    }

    func show(appState: AppState) {
        HapticFeedbackService.shared.trigger(.toggle)

        // Record the frontmost app so we can paste back to it if requested
        previousApp = NSWorkspace.shared.frontmostApplication

        guard let screen = NSScreen.main else { return }

        let windowWidth: CGFloat = 580
        let windowHeight: CGFloat = 380

        let x = screen.visibleFrame.midX - (windowWidth / 2)
        // Position comfortably in the upper half of the screen
        let y = screen.visibleFrame.maxY - windowHeight - 80
        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        let targetPanel: NSPanel
        if let existing = panel {
            targetPanel = existing
            targetPanel.setFrame(frame, display: true)
        } else {
            targetPanel = NSPanel(
                contentRect: frame,
                styleMask: [.titled, .fullSizeContentView, .closable],
                backing: .buffered,
                defer: false
            )
            targetPanel.titleVisibility = .hidden
            targetPanel.titlebarAppearsTransparent = true
            targetPanel.isFloatingPanel = true
            targetPanel.level = .floating
            targetPanel.backgroundColor = .clear
            targetPanel.isOpaque = false
            targetPanel.hasShadow = true
            targetPanel.isMovableByWindowBackground = true
            targetPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            targetPanel.isReleasedWhenClosed = false
            self.panel = targetPanel
        }

        let hostingView = NSHostingView(
            rootView: AIAssistantView(
                appState: appState,
                onClose: { [weak self] in
                    self?.hide()
                },
                onInsertAtCursor: { [weak self] text in
                    self?.insertAtCursor(text: text, appState: appState)
                }
            )
        )
        targetPanel.contentView = hostingView

        targetPanel.alphaValue = 0
        targetPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            targetPanel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        })
    }

    func hideTemporarilyForCapture(completion: @escaping () -> Void) {
        guard let panel, panel.isVisible else {
            completion()
            return
        }
        panel.alphaValue = 0
        // Small delay to allow WindowServer to refresh the display before screencapture starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            completion()
        }
    }

    func restoreAfterCapture() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }

    private func insertAtCursor(text: String, appState: AppState) {
        hide()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Reactivate the previous application
        if let app = previousApp {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Delay slightly for application activation before synthetic Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let src = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // 'v'
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
