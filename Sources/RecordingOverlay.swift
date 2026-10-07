import SwiftUI
import AppKit

// MARK: - State

final class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
    @Published var recordingTriggerMode: RecordingTriggerMode = .hold
    @Published var isCommandMode = false
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var copiedSnippet: String?
    @Published var fullTranscriptToCopy: String?
    @Published var isCopiedToClipboard = false
    @Published var memoryResultSnippet: String?
    @Published var memoryResultFullText: String?
    @Published var memoryResultSourceApp: String?
    @Published var toastID: UUID?
}

enum OverlayPhase {
    case initializing
    case recording
    case transcribing
    case rewriting
    case feedback
    case copiedFallback
    case memoryResult
    case updateAvailable
}

// MARK: - NSScreen Helpers

extension NSScreen {
    /// CoreGraphics display identifier for this screen, or nil if the
    /// device description is missing the key (vanishingly rare). Stable
    /// across screen-arrangement changes for as long as the display is
    /// connected, which is what the overlay picker stores in UserDefaults.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Panel Helpers

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

struct NotchOverlayContainerView<V: View>: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let hasNotch: Bool
    @ObservedObject var state: RecordingOverlayState
    let rootView: V

    var body: some View {
        rootView
            .frame(width: width, height: height)
            .background(
                LiquidGlassPillBackground(
                    cornerRadius: cornerRadius,
                    audioLevel: state.audioLevel,
                    isRecording: state.phase == .recording,
                    isRewriting: state.phase == .rewriting,
                    hasNotch: hasNotch
                )
            )
            .clipShape(Capsule())
    }
}

private func makeNotchContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    hasNotch: Bool,
    state: RecordingOverlayState,
    rootView: V
) -> NSView {
    let shaped = NotchOverlayContainerView(
        width: width,
        height: height,
        cornerRadius: cornerRadius,
        hasNotch: hasNotch,
        state: state,
        rootView: rootView
    )

    let hosting = NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

// MARK: - Manager

final class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private let overlayState = RecordingOverlayState()
    private var lockedOverlayWidth: CGFloat?

    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?

    /// The screen the overlay should drop down on. The user picks one of
    /// three modes in Settings, stored in UserDefaults under
    /// `overlay_display_id`:
    ///
    /// - `0` (default) — Active window: follows focus across monitors via
    ///   NSScreen.main. Default for backward compatibility — the original
    ///   behavior on a single-display setup is unchanged.
    /// - `-1` — Primary display: always NSScreen.screens.first (the display
    ///   designated as primary in System Settings → Displays).
    /// - any positive integer — specific NSScreen displayID. Falls back to
    ///   primary if that display is unplugged.
    private var targetScreen: NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let match = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == savedID }) {
                return match
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private var screenHasNotch: Bool {
        guard let screen = targetScreen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidth: CGFloat {
        guard let screen = targetScreen, screenHasNotch else { return 0 }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    private var notchOverlap: CGFloat {
        guard let screen = targetScreen else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private var overlayAcceptsMouseEvents: Bool {
        (overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle)
            || overlayState.phase == .updateAvailable
            || overlayState.phase == .copiedFallback
            || overlayState.phase == .memoryResult
    }

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: false)
        }
    }

    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .recording
            self.updateOverlayLayout(animated: true)
        }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async {
            self.overlayState.recordingTriggerMode = mode
            self.updateOverlayLayout(animated: animated)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.overlayState.audioLevel = level
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.setTranscribingPhase()
        }
    }

    func showRewriting() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .rewriting
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async {
            self.showFeedbackPanel()
        }
    }

    /// Maximum length of an in-pill error message. Anything longer is
    /// truncated with an ellipsis to keep the pill from stretching across
    /// the menu bar; the full text remains available in `os_log` for
    /// forensic review.
    private static let maxToastMessageLength = 90

    /// Surface a transient error in the menu-bar pill. The pill resizes to
    /// fit the message (subject to the truncation cap), holds for a few
    /// seconds, then dismisses. Intended for non-fatal user-facing errors
    /// that previously only landed in `os_log` — rate limits, network
    /// failures, permission gaps, etc.
    func showError(_ message: String) {
        let truncated: String = {
            if message.count <= Self.maxToastMessageLength { return message }
            let cutoff = message.index(message.startIndex, offsetBy: Self.maxToastMessageLength - 1)
            return String(message[..<cutoff]) + "…"
        }()
        DispatchQueue.main.async { [self] in
            let toastID = UUID()
            self.overlayState.errorMessage = truncated
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .feedback
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .feedback,
                      self.overlayState.errorMessage == truncated,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.overlayState.errorMessage = nil
                self.overlayState.toastID = nil
                self.dismissAll()
            }
        }
    }

    /// Shows an interactive notch pill allowing the user to copy the transcript when focus is lost or not in an input
    func showCopiedFallback(snippet: String, fullTranscript: String? = nil) {
        let textToUse = fullTranscript ?? snippet
        let truncated: String = {
            if snippet.count <= 42 { return snippet }
            let cutoff = snippet.index(snippet.startIndex, offsetBy: 41)
            return String(snippet[..<cutoff]) + "…"
        }()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let toastID = UUID()
            self.overlayState.copiedSnippet = truncated
            self.overlayState.fullTranscriptToCopy = textToUse
            self.overlayState.isCopiedToClipboard = false
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .copiedFallback
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .copiedFallback,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.dismissAll()
            }
        }
    }

    /// Shows a memory search match in the Liquid Glass bubble with a copy button
    func showMemoryResult(snippet: String, fullText: String, sourceApp: String = "") {
        let truncated: String = {
            if snippet.count <= 42 { return snippet }
            let cutoff = snippet.index(snippet.startIndex, offsetBy: 41)
            return String(snippet[..<cutoff]) + "…"
        }()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let toastID = UUID()
            self.overlayState.memoryResultSnippet = truncated
            self.overlayState.memoryResultFullText = fullText
            self.overlayState.memoryResultSourceApp = sourceApp
            self.overlayState.isCopiedToClipboard = false
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .memoryResult
            self.showOverlayPanel(animatedResize: true)
            HapticFeedbackService.shared.trigger(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .memoryResult,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.dismissAll()
            }
        }
    }

    func showUpdateAvailable(version: String) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.isCommandMode = false
            self.overlayState.updateVersion = version
            self.overlayState.phase = .updateAvailable
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.dismissAll()
        }
    }

    private func showOverlayPanel(animatedResize: Bool) {
        let frame = overlayFrame

        if let panel = overlayWindow {
            panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
            panel.contentView = makeOverlayContent(frame: frame)
            resize(panel: panel, to: frame, animated: animatedResize)
            panel.invalidateShadow()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: frame.width, height: frame.height)
        panel.hasShadow = true
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)

        guard let screen = targetScreen else { return }

        let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(hiddenFrame, display: true)
        panel.invalidateShadow()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
        }

        overlayWindow = panel
    }

    private func updateOverlayLayout(animated: Bool) {
        guard let panel = overlayWindow else { return }
        let frame = overlayFrame
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)
        resize(panel: panel, to: frame, animated: animated)
        panel.invalidateShadow()
    }

    private func setTranscribingPhase() {
        lockedOverlayWidth = overlayWindow?.frame.width ?? overlayWidth
        overlayState.phase = .transcribing
        showOverlayPanel(animatedResize: true)
    }

    private func makeOverlayContent(frame: NSRect) -> NSView {
        if useWingedLayout {
            // Winged layout: notch x-range stays solid black so the cutout masks it.
            let rootView = WingedRecordingView(
                state: overlayState,
                leftWingWidth: Self.leftWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: Self.rightWingWidth,
                height: frame.height,
                onStopButtonPressed: { [weak self] in
                    self?.onStopButtonPressed?()
                }
            )
            return makeNotchContent(
                width: frame.width,
                height: frame.height,
                cornerRadius: 14,
                hasNotch: screenHasNotch,
                state: overlayState,
                rootView: AnyView(rootView)
            )
        }

        return makeNotchContent(
            width: frame.width,
            height: frame.height,
            cornerRadius: screenHasNotch ? 18 : 12,
            hasNotch: screenHasNotch,
            state: overlayState,
            rootView: AnyView(
                RecordingOverlayView(
                    state: overlayState,
                    onStopButtonPressed: { [weak self] in
                        self?.onStopButtonPressed?()
                    },
                    onUpdateOverlayPressed: { [weak self] in
                        self?.onUpdateOverlayPressed?()
                    },
                    onCopyFallbackPressed: { [weak self] in
                        guard let self else { return }
                        if let text = self.overlayState.fullTranscriptToCopy ?? self.overlayState.copiedSnippet {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(text, forType: .string)
                        }
                        withAnimation {
                            self.overlayState.isCopiedToClipboard = true
                        }
                        HapticFeedbackService.shared.trigger(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            self?.dismissAll()
                        }
                    },
                    onCopyFallbackDismissed: { [weak self] in
                        self?.dismissAll()
                    },
                    onMemoryCopyPressed: { [weak self] in
                        guard let self else { return }
                        if let text = self.overlayState.memoryResultFullText ?? self.overlayState.memoryResultSnippet {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(text, forType: .string)
                        }
                        withAnimation {
                            self.overlayState.isCopiedToClipboard = true
                        }
                        HapticFeedbackService.shared.trigger(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            self?.dismissAll()
                        }
                    },
                    onMemoryDismissed: { [weak self] in
                        self?.dismissAll()
                    }
                )
            )
        )
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// True iff the overlay renders as wings flanking the notch (notched display
    /// + use_compact_overlay on). updateAvailable and error toasts still use
    /// the drop-down pill.
    private var useWingedLayout: Bool {
        guard screenHasNotch else { return false }
        let useCompact = (UserDefaults.standard.object(forKey: "use_compact_overlay") as? Bool) ?? false
        guard useCompact else { return false }
        switch overlayState.phase {
        case .recording, .initializing, .transcribing, .rewriting:
            return true
        case .feedback:
            return overlayState.errorMessage?.isEmpty ?? true
        case .copiedFallback, .memoryResult:
            return false
        case .updateAvailable:
            return false
        }
    }

    /// Wing width — tight to the compact waveform / stop button so the
    /// panel stays clear of right-side menu-bar items.
    static let wingWidth: CGFloat = 36
    static let leftWingWidth: CGFloat = wingWidth
    static let rightWingWidth: CGFloat = wingWidth

    private var overlayFrame: NSRect {
        guard let screen = targetScreen else { return .zero }

        if useWingedLayout {
            // Anchor to the screen's auxiliary-area boundaries of the notch;
            // panel height matches the menu-bar overlap so nothing protrudes below.
            let nWidth = notchWidth
            let nLeftX = screen.auxiliaryTopLeftArea?.maxX
                ?? (screen.frame.midX - nWidth / 2)
            let leftWing = Self.leftWingWidth
            let rightWing = Self.rightWingWidth
            let panelHeight = notchOverlap
            let panelWidth = leftWing + nWidth + rightWing
            let panelX = nLeftX - leftWing
            let panelY = screen.frame.maxY - panelHeight
            return NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        }

        let width = overlayWidth
        let height: CGFloat = 44
        let x = screen.frame.midX - width / 2

        // Detached Floating Bubble: positioned gracefully below the menu bar or notch
        let topBoundary = screen.visibleFrame.maxY
        let y = topBoundary - height - 12
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private var overlayWidth: CGFloat {
        if let lockedOverlayWidth, overlayState.phase == .transcribing {
            return lockedOverlayWidth
        }

        if overlayState.phase == .copiedFallback {
            return 330
        }

        if overlayState.phase == .memoryResult {
            return 350
        }

        if overlayState.phase == .feedback {
            guard let msg = overlayState.errorMessage, !msg.isEmpty else {
                return 120
            }
            let estimated = CGFloat(msg.count) * 7.5 + 70
            return min(440, max(200, estimated))
        }

        if overlayState.phase == .updateAvailable {
            return 210
        }

        if overlayState.phase == .rewriting {
            return 240
        }

        if overlayState.phase == .initializing {
            return 180
        }

        if overlayState.isCommandMode {
            return 240
        } else if overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle {
            return 260
        } else {
            return 220
        }
    }

    private func showFeedbackPanel() {
        lockedOverlayWidth = nil
        overlayState.phase = .feedback
        showOverlayPanel(animatedResize: true)
    }

    private func dismissAll() {
        lockedOverlayWidth = nil
        overlayState.isCommandMode = false
        overlayState.updateVersion = ""
        overlayState.copiedSnippet = nil
        overlayState.fullTranscriptToCopy = nil
        overlayState.isCopiedToClipboard = false
        overlayState.memoryResultSnippet = nil
        overlayState.memoryResultFullText = nil
        overlayState.memoryResultSourceApp = nil
        overlayState.toastID = nil
        if let panel = overlayWindow {
            panel.orderOut(nil)
            // orderOut alone leaves the panel retained in NSApp.windows with its
            // SwiftUI hierarchy mounted — repeatForever animations keep flushing
            // Core Animation forever. Unmount and close so the panel deallocates.
            panel.contentView = nil
            panel.close()
            overlayWindow = nil
        }
    }
}

// MARK: - Winged Recording View

/// Wing layout: waveform left, stop button right, solid-black notch in the middle
/// (the camera cutout masks those pixels).
struct WingedRecordingView: View {
    @ObservedObject var state: RecordingOverlayState
    let leftWingWidth: CGFloat
    let notchWidth: CGFloat
    let rightWingWidth: CGFloat
    let height: CGFloat
    let onStopButtonPressed: () -> Void

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    var body: some View {
        wingsHStack
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(WisperMotion.stateChange, value: state.phase)
    }

    private var wingsHStack: some View {
        HStack(spacing: 0) {
            // Left wing — empty during feedback so the right-wing X reads as the sole signal.
            HStack {
                Spacer(minLength: 0)
                Group {
                    if state.phase == .feedback {
                        Color.clear
                    } else if state.phase == .initializing {
                        InitializingDotsView()
                            .wisperContentTransition()
                    } else if state.phase == .rewriting {
                        CompactRewritingIndicatorView()
                            .wisperContentTransition()
                    } else if showsLiveRecordingContent {
                        // Command-mode pencil sits directly above and centered
                        // over the compact waveform inside the same wing
                        // rectangle. Closes the gap between pill and winged
                        // layouts: pill users already see a pencil during
                        // command-mode dictation; winged users now do too.
                        VStack(spacing: 1) {
                            if state.isCommandMode {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .wisperContentTransition()
                            }
                            CompactWaveformView(
                                audioLevel: state.audioLevel,
                                showsActivityPulse: state.phase == .recording
                            )
                        }
                        .wisperContentTransition()
                    } else {
                        CompactProcessingIndicatorView()
                            .wisperContentTransition()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: leftWingWidth, height: height)

            // Notch spacer — solid black; camera cutout hides it.
            Color.black
                .frame(width: notchWidth, height: height)

            // Right wing — stop button (recording) OR failure X (feedback),
            // horizontally centered.
            HStack {
                Spacer(minLength: 0)
                Group {
                    if state.phase == .feedback {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.red.opacity(0.92)))
                            .wisperContentTransition()
                    } else if showsStopButton {
                        Button(action: onStopButtonPressed) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.red.opacity(0.92)))
                        }
                        .buttonStyle(.plain)
                        .wisperContentTransition()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: rightWingWidth, height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(WisperMotion.stateChange, value: state.phase)
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 22

    @AppStorage("overlay_glass_style") private var glassStyle = OverlayGlassStyle.liquidGlass.rawValue

    var body: some View {
        Capsule()
            .fill(
                glassStyle == OverlayGlassStyle.liquidGlass.rawValue
                    ? AnyShapeStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 0.45, green: 0.85, blue: 1.0), location: 0.0),
                                .init(color: .white, location: 0.4),
                                .init(color: Color(red: 0.85, green: 0.55, blue: 1.0), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    : AnyShapeStyle(Color.white)
            )
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
            .shadow(
                color: glassStyle == OverlayGlassStyle.liquidGlass.rawValue
                    ? Color(red: 0.4, green: 0.7, blue: 1.0).opacity(Double(amplitude) * 0.45)
                    : Color.clear,
                radius: 3,
                x: 0,
                y: 0
            )
    }
}

struct WaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    waveformBars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformBars(pulseTime: nil)
            }
        }
        .frame(height: 24)
    }

    private func waveformBars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(
                            response: barResponse(for: index),
                            dampingFraction: 0.88
                        )
                        .delay(barDelay(for: index)),
                        value: audioLevel
                    )
            }
        }
    }

    private func barAmplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * Self.multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.22 + shimmer * 0.06

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }

    private func barResponse(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        let normalizedDistance = distance / Self.centerIndex
        return 0.18 + Double(normalizedDistance) * 0.06
    }

    private func barDelay(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance) * 0.01
    }
}

/// Tighter 5-bar waveform sized for the 36pt wing layout.
struct CompactWaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false

    private static let barCount = 5
    private static let multipliers: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    bars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(pulseTime: nil)
            }
        }
        .frame(height: 18)
    }

    private func bars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                CompactWaveformBar(amplitude: amplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(response: 0.18, dampingFraction: 0.88),
                        value: audioLevel
                    )
            }
        }
    }

    private func amplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let base = min(level * Self.multipliers[index], 1.0)
        guard let pulseTime else { return base }
        let traveling = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = traveling * 0.22 + shimmer * 0.06
        let saturationRelief = base * (0.74 + pulse)
        let quietPulse = (1.0 - base) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }
}

struct CompactWaveformBar: View {
    let amplitude: CGFloat
    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 14

    @AppStorage("overlay_glass_style") private var glassStyle = OverlayGlassStyle.liquidGlass.rawValue

    var body: some View {
        Capsule()
            .fill(
                glassStyle == OverlayGlassStyle.liquidGlass.rawValue
                    ? AnyShapeStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 0.5, green: 0.85, blue: 1.0), location: 0.0),
                                .init(color: .white, location: 0.5),
                                .init(color: Color(red: 0.85, green: 0.55, blue: 1.0), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    : AnyShapeStyle(Color.white)
            )
            .frame(width: 2, height: minHeight + (maxHeight - minHeight) * amplitude)
            .shadow(
                color: glassStyle == OverlayGlassStyle.liquidGlass.rawValue
                    ? Color.cyan.opacity(Double(amplitude) * 0.35)
                    : Color.clear,
                radius: 2,
                x: 0,
                y: 0
            )
    }
}

struct ProcessingWaveformView: View {
    private static let barCount = 5
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 4) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    ProcessingPill(
                        amplitude: amplitude(for: index, time: time),
                        opacity: opacity(for: index, time: time)
                    )
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .fixedSize()
    }

    private func phase(for index: Int, time: TimeInterval) -> Double {
        let cycle = 1.05
        let stagger = 0.11
        return ((time - Double(index) * stagger).truncatingRemainder(dividingBy: cycle)) / cycle
    }

    private func pulse(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = phase(for: index, time: time)
        let wave = 0.5 + 0.5 * sin((phase * 2.0 * .pi) - (.pi / 2.0))
        return CGFloat(pow(wave, 1.9))
    }

    private func amplitude(for index: Int, time: TimeInterval) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - Self.centerIndex) / Self.centerIndex
        let baseline = 0.18 + (1.0 - centerDistance) * 0.1
        return min(baseline + pulse(for: index, time: time) * 0.68, 1.0)
    }

    private func opacity(for index: Int, time: TimeInterval) -> CGFloat {
        0.42 + pulse(for: index, time: time) * 0.52
    }
}

private struct ProcessingPill: View {
    let amplitude: CGFloat
    let opacity: CGFloat

    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 18

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 4, height: minHeight + (maxHeight - minHeight) * amplitude)
            .opacity(opacity)
    }
}

struct ProcessingIndicatorView: View {
    @State private var showsExtendedSpinner = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if showsExtendedSpinner {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(rotation))
                    .frame(height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .wisperContentTransition()
                    .onAppear {
                        rotation = 0
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                ProcessingWaveformView()
                    .wisperContentTransition()
            }
        }
        .task {
            showsExtendedSpinner = false
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsExtendedSpinner = true
                }
            } catch {}
        }
    }
}

/// Same hybrid waveform-then-spinner as `ProcessingIndicatorView`, sized to
/// fit the 18pt winged menu-bar overlay. Uses tighter pills and a smaller
/// spinner so the indicator stays inside the wing without the jolt to
/// oversized capsules that the full-size indicator produced.
struct CompactProcessingIndicatorView: View {
    @State private var showsExtendedSpinner = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if showsExtendedSpinner {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(rotation))
                    .frame(height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .wisperContentTransition()
                    .onAppear {
                        rotation = 0
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                CompactProcessingWaveformView()
                    .wisperContentTransition()
            }
        }
        .task {
            showsExtendedSpinner = false
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsExtendedSpinner = true
                }
            } catch {}
        }
    }
}

struct CompactProcessingWaveformView: View {
    private static let barCount = 5
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    CompactProcessingPill(
                        amplitude: amplitude(for: index, time: time),
                        opacity: opacity(for: index, time: time)
                    )
                }
            }
            .frame(height: 18)
        }
        .frame(height: 18)
        .fixedSize()
    }

    private func phase(for index: Int, time: TimeInterval) -> Double {
        let cycle = 1.05
        let stagger = 0.11
        return ((time - Double(index) * stagger).truncatingRemainder(dividingBy: cycle)) / cycle
    }

    private func pulse(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = phase(for: index, time: time)
        let wave = 0.5 + 0.5 * sin((phase * 2.0 * .pi) - (.pi / 2.0))
        return CGFloat(pow(wave, 1.9))
    }

    private func amplitude(for index: Int, time: TimeInterval) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - Self.centerIndex) / Self.centerIndex
        let baseline = 0.18 + (1.0 - centerDistance) * 0.1
        return min(baseline + pulse(for: index, time: time) * 0.68, 1.0)
    }

    private func opacity(for index: Int, time: TimeInterval) -> CGFloat {
        0.42 + pulse(for: index, time: time) * 0.52
    }
}

private struct CompactProcessingPill: View {
    let amplitude: CGFloat
    let opacity: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 12

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 2, height: minHeight + (maxHeight - minHeight) * amplitude)
            .opacity(opacity)
    }
}

struct RewritingWaveView: View {
    private static let barCount = 7
    private static let multipliers: [CGFloat] = [0.45, 0.70, 0.90, 1.0, 0.90, 0.70, 0.45]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let amp = amplitude(for: index, time: time)
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 0.85, green: 0.55, blue: 1.0), location: 0.0),
                                    .init(color: Color.white, location: 0.45),
                                    .init(color: Color(red: 0.45, green: 0.85, blue: 1.0), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2.8, height: 3 + 14 * amp)
                        .shadow(color: Color(red: 0.75, green: 0.40, blue: 1.0).opacity(Double(amp) * 0.4), radius: 2)
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .fixedSize()
    }

    private func amplitude(for index: Int, time: TimeInterval) -> CGFloat {
        let wave = 0.5 + 0.5 * sin((time * 5.5) - Double(index) * 0.7)
        return min(max(CGFloat(wave) * Self.multipliers[index], 0.15), 1.0)
    }
}

struct RewritingIndicatorView: View {
    @State private var rotation: Double = 0
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.75, green: 0.50, blue: 1.0), Color(red: 1.0, green: 0.60, blue: 0.90)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(pulse ? 1.12 : 0.90)

                Text("Réécriture")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.65, green: 0.35, blue: 1.0).opacity(0.35),
                                Color(red: 0.45, green: 0.20, blue: 0.85).opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.85, green: 0.60, blue: 1.0).opacity(0.55),
                                Color(red: 0.55, green: 0.30, blue: 0.90).opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .layoutPriority(1)

            RewritingWaveView()
        }
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct CompactRewritingIndicatorView: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.6, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.5, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            CompactProcessingWaveformView()
        }
    }
}

struct InitializingDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    activeDot = (activeDot + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onStopButtonPressed: () -> Void
    let onUpdateOverlayPressed: () -> Void
    let onCopyFallbackPressed: () -> Void
    let onCopyFallbackDismissed: () -> Void
    let onMemoryCopyPressed: () -> Void
    let onMemoryDismissed: () -> Void

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    var body: some View {
        Group {
            if state.phase == .copiedFallback {
                CopiedFallbackView(
                    state: state,
                    onCopy: onCopyFallbackPressed,
                    onDismiss: onCopyFallbackDismissed
                )
            } else if state.phase == .memoryResult {
                MemoryResultOverlayView(
                    state: state,
                    onCopy: onMemoryCopyPressed,
                    onDismiss: onMemoryDismissed
                )
            } else if state.phase == .feedback, let message = state.errorMessage {
                ErrorOverlayView(message: message)
            } else if state.phase == .feedback {
                FailureIndicatorView()
            } else if state.phase == .updateAvailable {
                UpdateAvailableOverlayView(onPress: onUpdateOverlayPressed)
            } else if state.phase == .rewriting {
                RewritingIndicatorView()
                    .wisperContentTransition()
            } else if state.phase == .initializing {
                HStack(spacing: 8) {
                    InitializingDotsView()
                        .fixedSize()
                    Text("Écoute…")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                }
                .glassChip()
                .wisperContentTransition()
            } else if showsLiveRecordingContent {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(WisperPalette.recording)
                            .frame(width: 7, height: 7)
                            .shadow(color: WisperPalette.recording.opacity(0.9), radius: 3)
                        Text("Parler")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .glassChip()
                    .layoutPriority(1)

                    WaveformView(
                        audioLevel: state.audioLevel,
                        showsActivityPulse: true
                    )
                    .fixedSize()

                    if state.isCommandMode {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    if showsStopButton {
                        Button(action: onStopButtonPressed) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(WisperPalette.recording.opacity(0.92)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .wisperContentTransition()
            } else {
                HStack(spacing: 8) {
                    ProcessingIndicatorView()
                        .fixedSize()
                    Text("Transcription…")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                }
                .glassChip()
                .wisperContentTransition()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(WisperMotion.stateChange, value: state.phase)
        .animation(WisperMotion.stateChange, value: state.recordingTriggerMode)
        .animation(WisperMotion.stateChange, value: state.isCommandMode)
    }
}

// MARK: - Transcribing Indicator

struct CommandModeIndicator: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 16, height: 16, alignment: .center)
    }
}

struct FailureIndicatorView: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(WisperPalette.error.opacity(0.92)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// In-pill error toast. Red exclamation icon plus the message text,
/// rendered inside the standard menu-bar pill. Sized by the manager's
/// `overlayWidth` based on message length.
struct ErrorOverlayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WisperPalette.error.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }
}

struct CopiedFallbackView: View {
    @ObservedObject var state: RecordingOverlayState
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state.isCopiedToClipboard {
                SuccessCheckmarkView(label: "Copié !")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    Text(state.copiedSnippet ?? "Texte prêt")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                GlassCapsuleButton(title: "Copier", action: onCopy)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct MemoryResultOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state.isCopiedToClipboard {
                SuccessCheckmarkView(label: "Mémoire copiée !")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WisperPalette.memoryGradient)

                    Text(state.memoryResultSnippet ?? "Souvenir retrouvé")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                GlassCapsuleButton(title: "Copier", useAccentFill: true, action: onCopy)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
