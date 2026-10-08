import SwiftUI
import AppKit

/// "Craie" design system: warm off-white, near-black ink for action, and a single
/// signal color reserved for what is happening right now. Light and dark variants
/// are provided; the light values are the reference palette.
enum Craie {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(craieHex: isDark ? dark : light)
        })
    }

    // Surfaces
    static let fond = dynamic(light: 0xF6F5F1, dark: 0x141413)
    static let panneau = dynamic(light: 0xFBFAF7, dark: 0x1C1C1A)
    static let surface = dynamic(light: 0xEEEDE8, dark: 0x262624)
    // Accents
    static let signal = Color(nsColor: NSColor(craieHex: 0xEE4B2B))
    static let signalText = dynamic(light: 0xC2381C, dark: 0xFF7A5C)
    static let action = dynamic(light: 0x18181A, dark: 0xF6F5F1)
    static let onAction = dynamic(light: 0xFBFAF7, dark: 0x18181A)
    // Text
    static let textPrimary = dynamic(light: 0x18181A, dark: 0xF3F2EE)
    static let textSecondary = dynamic(light: 0x55555B, dark: 0xB4B3AE)
    static let textTertiary = dynamic(light: 0x68686D, dark: 0x8E8D88)
    // Borders (encre 7 / 9 / 14 %)
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (isDark ? NSColor.white : NSColor(craieHex: 0x18181A)).withAlphaComponent(isDark ? 0.10 : 0.09)
    })

    // Typography (Geist is not bundled; the system face stays close and avoids a font license step)
    static func titre(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .semibold) }
    static let titrePublication = Font.system(size: 15, weight: .semibold)
    static let texte = Font.system(size: 14, weight: .regular)
    static let libelle = Font.system(size: 12, weight: .medium)
    /// Mono is reserved for durations, counters and hours.
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Motion
    static let survol = Animation.easeOut(duration: 0.16)
    static let pression = Animation.easeOut(duration: 0.12)
    static let panneauAppear = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.36)
}

extension NSColor {
    convenience init(craieHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Components

/// The card is the hero: everything else floats, fades or tucks away.
struct CraieCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Craie.panneau)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Craie.border, lineWidth: 1))
    }
}

struct CraieSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Craie.libelle)
            .foregroundStyle(Craie.textTertiary)
    }
}

/// Large figure with a label. Counters use mono, per the system.
struct CraieStat: View {
    let label: String
    let value: String
    var signal = false

    var body: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 6) {
                CraieSectionLabel(label)
                Text(value)
                    .font(Craie.mono(24, weight: .medium))
                    .foregroundStyle(signal ? Craie.signalText : Craie.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

struct CraiePillButtonStyle: ButtonStyle {
    enum Kind { case action, secondary }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(kind: kind, configuration: configuration)
    }

    private struct PillBody: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind == .action ? Craie.onAction : Craie.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(kind == .action ? Craie.action : Craie.surface)
                        .overlay(Capsule().fill(Color.white.opacity(hovering ? 0.06 : 0)))
                )
                .overlay(Capsule().stroke(kind == .action ? Color.clear : Craie.border, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Craie.pression, value: configuration.isPressed)
                .animation(Craie.survol, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Segmented pills ("Tout / Direct / Blogs" in the system sheet).
struct CraieSegmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.1 == selection
                Button { selection = option.1 } label: {
                    Text(option.0)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Craie.textPrimary : Craie.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selected ? Craie.panneau : Color.clear))
                        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Craie.surface))
        .animation(Craie.survol, value: selection)
    }
}

/// Signal dot. Pulses only while something is live, and never under "reduce motion".
struct CraieSignalDot: View {
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if live && !reduceMotion {
                Circle()
                    .fill(Craie.signal.opacity(0.5))
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 1)
            }
            Circle().fill(Craie.signal)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }
}
