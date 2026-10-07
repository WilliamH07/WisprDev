import SwiftUI

// MARK: - Motion

/// Shared spring presets. Default UI motion is critically damped (no overshoot);
/// the bouncy preset is reserved for momentum-driven moments like a success pop.
public enum WisperMotion {
    /// Phase changes of the recording overlay (recording → transcribing → …).
    public static let stateChange = Animation.spring(response: 0.30, dampingFraction: 1.0)
    /// Small content swaps inside a stable surface (label, icon, button states).
    public static let contentChange = Animation.spring(response: 0.24, dampingFraction: 1.0)
    /// Momentum-driven feedback (success confirmation, arrival of a result).
    public static let momentum = Animation.spring(response: 0.40, dampingFraction: 0.8)
}

// MARK: - Palette

/// Semantic colors mapped to Apple's system palette, so the app reads like
/// something Apple would ship. The overlay renders on dark glass; these adapt
/// to the system appearance.
public enum WisperPalette {
    /// Live recording.
    public static let recording = Color(nsColor: .systemRed)
    /// Success confirmation.
    public static let success = Color(nsColor: .systemGreen)
    /// Failure — same family as recording so "red = attention" stays consistent.
    public static let error = Color(nsColor: .systemRed)
    /// Transcription / processing.
    public static let processing = Color(nsColor: .systemBlue)
    /// Rewrite / thinking.
    public static let rewriting = Color(nsColor: .systemPurple)
    /// Memory ("Deuxième Cerveau") — teal to indigo, matching the assistant brand.
    public static let memoryGradient = LinearGradient(
        colors: [Color(nsColor: .systemTeal), Color(nsColor: .systemIndigo)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// Accent fill for interactive chips.
    public static let actionGradient = LinearGradient(
        colors: [Color(nsColor: .systemBlue).opacity(0.45), Color(nsColor: .systemIndigo).opacity(0.35)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Native Liquid Glass (macOS 26+)

extension View {
    /// Applies Apple's native Liquid Glass material on macOS 26+ (the same
    /// rendering Wispr Flow gets for free). On older systems this is a no-op:
    /// callers must keep a manual fallback background for macOS 13–25.
    ///
    /// Draw only inert content (or nothing) inside the glass — content within
    /// the glass region is refracted, so interactive UI must sit above it.
    @ViewBuilder
    func wisperGlass(
        in shape: some Shape,
        tint: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.nativeGlass(tint: tint), in: shape)
        } else {
            self
        }
    }

    @available(macOS 26.0, *)
    private static func nativeGlass(tint: Color?) -> Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint)
    }
}

// MARK: - Glass Chips

/// The small frosted capsule that hosts inline status text ("Parler", "Écoute…",
/// "Transcription…") inside the overlay pill. Deliberately a plain translucent
/// fill, not nested glass — content sits directly on the pill's glass surface,
/// as Apple's own HUD overlays do.
struct GlassChip: ViewModifier {
    var verticalPadding: CGFloat = 5

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(
                Capsule().stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
    }
}

extension View {
    func glassChip(verticalPadding: CGFloat = 5) -> some View {
        modifier(GlassChip(verticalPadding: verticalPadding))
    }
}

// MARK: - Glass Action Button

/// The compact "Copier" capsule used by the fallback and memory-result panels.
/// `tint` selects the fill; plain frosted white when nil.
struct GlassCapsuleButton: View {
    let title: String
    var icon: String? = nil
    var useAccentFill = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .background(
                    Capsule().fill(useAccentFill ? WisperPalette.actionGradient : LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(useAccentFill ? 0.30 : 0.35), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }
}

// MARK: - Success Confirmation

/// Animated checkmark for "copied" confirmations: a gentle pop on arrival,
/// reduced to a plain symbol under Reduce Motion.
struct SuccessCheckmarkView: View {
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WisperPalette.success)
                .scaleEffect(appeared || reduceMotion ? 1.0 : 0.6)
                .opacity(appeared || reduceMotion ? 1.0 : 0.0)

            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(WisperMotion.momentum) {
                appeared = true
            }
        }
    }
}

// MARK: - Transitions

/// Symmetric enter/exit transition for overlay content: opacity plus a subtle
/// scale so surfaces read as a material arriving, not a flat fade. Collapses to
/// a cross-fade under Reduce Motion.
struct WisperContentTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.96))
        )
    }
}

extension View {
    func wisperContentTransition() -> some View {
        modifier(WisperContentTransition())
    }
}
