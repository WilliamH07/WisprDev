import AppKit
import SwiftUI

@MainActor
final class VisualPointerOverlayManager: ObservableObject {
    static let shared = VisualPointerOverlayManager()

    private var overlayWindow: NSPanel?
    private var dismissTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    @Published var currentTarget: VisualGroundingTarget?
    @Published var isVisible: Bool = false

    @MainActor
    func show(target: VisualGroundingTarget) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeEventMonitors()

        guard let screen = NSScreen.main else { return }

        self.currentTarget = target
        self.isVisible = true

        let panel: NSPanel
        if let existing = overlayWindow {
            panel = existing
            panel.setFrame(screen.frame, display: true)
        } else {
            panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true // User can click directly on the highlighted element
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            overlayWindow = panel
        }

        let hosting = NSHostingView(
            rootView: VisualPointerView(target: target, screenFrame: screen.frame)
        )
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = hosting

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1.0
        }

        // Play feedback sound
        NSSound(named: "Glass")?.play()

        // Set up event monitors to dismiss when user clicks or presses a key
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.dismiss()
            }
            return event
        }

        // Auto dismiss after 4.5 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }

    @MainActor
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeEventMonitors()

        guard let panel = overlayWindow, panel.alphaValue > 0 else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                panel.orderOut(nil)
                self?.isVisible = false
                self?.currentTarget = nil
            }
        })
    }

    private func removeEventMonitors() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
}

// MARK: - SwiftUI View

struct VisualPointerView: View {
    let target: VisualGroundingTarget
    let screenFrame: NSRect

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8
    @State private var rotation: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Highlight Box positioned at target coordinates
            let rect = target.screenRect
            let padding: CGFloat = 6
            let boxX = rect.origin.x - padding
            let boxY = screenFrame.height - (rect.origin.y + rect.height) - padding
            let boxW = rect.width + (padding * 2)
            let boxH = rect.height + (padding * 2)

            ZStack {
                // Expanding radar pulse
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.8), Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2.5
                    )
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)

                // Steady glowing border
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 0.3, green: 0.6, blue: 1.0), Color(red: 0.8, green: 0.3, blue: 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.purple.opacity(0.12))
                    )
                    .shadow(color: Color.cyan.opacity(0.6), radius: 10, x: 0, y: 0)

                // Corner crosshairs
                CornerCrosshairsView()
            }
            .frame(width: boxW, height: boxH)
            .position(x: boxX + (boxW / 2), y: boxY + (boxH / 2))

            // Tooltip label above or below the element
            let tooltipY = (boxY > 50) ? (boxY - 32) : (boxY + boxH + 32)

            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotationEffect(.degrees(rotation))

                Text(target.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .rotationEffect(.degrees(boxY > 50 ? 0 : 180))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.85))
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.45), location: 0.0),
                                        .init(color: Color.cyan.opacity(0.3), location: 0.4),
                                        .init(color: Color.purple.opacity(0.35), location: 0.8),
                                        .init(color: Color.white.opacity(0.3), location: 1.0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
                    .shadow(color: Color.cyan.opacity(0.25), radius: 8, x: 0, y: 0)
            )
            .position(x: boxX + (boxW / 2), y: tooltipY)
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulseScale = 1.35
                pulseOpacity = 0.0
            }
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct CornerCrosshairsView: View {
    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 8
            let width: CGFloat = 2

            // Top-left
            Path { path in
                path.move(to: CGPoint(x: 0, y: size))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: size, y: 0))
            }
            .stroke(Color.white, lineWidth: width)

            // Top-right
            Path { path in
                path.move(to: CGPoint(x: geo.size.width - size, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: size))
            }
            .stroke(Color.white, lineWidth: width)

            // Bottom-left
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height - size))
                path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                path.addLine(to: CGPoint(x: size, y: geo.size.height))
            }
            .stroke(Color.white, lineWidth: width)

            // Bottom-right
            Path { path in
                path.move(to: CGPoint(x: geo.size.width - size, y: geo.size.height))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - size))
            }
            .stroke(Color.white, lineWidth: width)
        }
    }
}
