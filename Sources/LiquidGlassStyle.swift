import AppKit
import SwiftUI

// MARK: - Liquid Glass Preference

public enum OverlayGlassStyle: String, CaseIterable, Identifiable {
    case liquidGlass = "liquid_glass"
    case classicBlack = "classic_black"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .liquidGlass:
            return "Verre Liquide (Liquid Glass)"
        case .classicBlack:
            return "Noir Mat (OLED)"
        }
    }

    public var description: String {
        switch self {
        case .liquidGlass:
            return "Finition translucide avec flou d'arrière-plan, reflets prismatiques et lueur fluide réactive."
        case .classicBlack:
            return "Finition noire opaque uniforme classique."
        }
    }
}

// MARK: - AppKit Visual Effect Background

/// Highly optimized backdrop blur wrapper for macOS with behindWindow or withinWindow blending
public struct LiquidGlassBackdrop: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Prismatic Specular Border

/// A multi-stop specular gradient stroke mimicking light catching the beveled edge of cut glass
public struct PrismaticGlassBorder: ShapeStyle {
    public var opacity: Double

    public init(opacity: Double = 1.0) {
        self.opacity = opacity
    }

    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.42 * opacity), location: 0.0),
                .init(color: Color.white.opacity(0.18 * opacity), location: 0.22),
                .init(color: Color(red: 0.5, green: 0.8, blue: 1.0).opacity(0.15 * opacity), location: 0.45),
                .init(color: Color.white.opacity(0.04 * opacity), location: 0.65),
                .init(color: Color(red: 0.8, green: 0.5, blue: 1.0).opacity(0.20 * opacity), location: 0.88),
                .init(color: Color.white.opacity(0.35 * opacity), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Fluid Liquid Aura (Ambient Aurora)

/// Subtle organic fluid glow shifting behind the glass surface
public struct FluidLiquidAura: View {
    public var audioLevel: Float
    public var isPulsing: Bool
    public var tint: Color?

    @State private var phase: CGFloat = 0

    public init(audioLevel: Float = 0, isPulsing: Bool = false, tint: Color? = nil) {
        self.audioLevel = audioLevel
        self.isPulsing = isPulsing
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let normalizedLevel = CGFloat(min(max(audioLevel, 0), 1.0))

            ZStack {
                // Secondary cyan fluid droplet
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (tint ?? Color(red: 0.2, green: 0.7, blue: 1.0)).opacity(0.22 + Double(normalizedLevel) * 0.28),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: max(width * 0.45, 30)
                        )
                    )
                    .frame(width: width * 0.7, height: height * 1.6)
                    .offset(x: -width * 0.22, y: -height * 0.1)
                    .blur(radius: 12)

                // Primary violet/magenta fluid droplet
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (tint ?? Color(red: 0.7, green: 0.35, blue: 1.0)).opacity(0.20 + Double(normalizedLevel) * 0.25),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: max(width * 0.5, 35)
                        )
                    )
                    .frame(width: width * 0.75, height: height * 1.7)
                    .offset(x: width * 0.20, y: height * 0.15)
                    .blur(radius: 14)
            }
            .frame(width: width, height: height)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Liquid Glass Pill Background

/// Reusable Liquid Glass background view for the overlay pill
public struct LiquidGlassPillBackground: View {
    public var cornerRadius: CGFloat
    public var audioLevel: Float
    public var isRecording: Bool
    public var isRewriting: Bool
    public var hasNotch: Bool

    @AppStorage("overlay_glass_style") private var glassStyle = OverlayGlassStyle.liquidGlass.rawValue

    public init(
        cornerRadius: CGFloat = 16,
        audioLevel: Float = 0,
        isRecording: Bool = false,
        isRewriting: Bool = false,
        hasNotch: Bool = false
    ) {
        self.cornerRadius = cornerRadius
        self.audioLevel = audioLevel
        self.isRecording = isRecording
        self.isRewriting = isRewriting
        self.hasNotch = hasNotch
    }

    public var body: some View {
        Group {
            if glassStyle == OverlayGlassStyle.classicBlack.rawValue {
                Capsule()
                    .fill(Color.black)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            } else if #available(macOS 26.0, *) {
                // Native Liquid Glass surface. Content stays OUT of the glass:
                // anything drawn inside gets refracted, so the glass is a plain
                // tinted material and all UI renders crisply above it.
                Color.clear
                    .glassEffect(
                        .regular.tint(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.55)),
                        in: Capsule()
                    )
            } else {
                legacyGlassBody
            }
        }
    }

    @ViewBuilder
    private var stateAura: some View {
        // Ambient liquid aura reacting to voice or state
        if isRecording {
            FluidLiquidAura(audioLevel: audioLevel)
        } else if isRewriting {
            FluidLiquidAura(
                audioLevel: 0.45,
                tint: Color(red: 0.8, green: 0.4, blue: 1.0)
            )
        } else {
            FluidLiquidAura(audioLevel: 0)
        }
    }

    /// Manual frosted-glass stack for macOS 13–25.
    private var legacyGlassBody: some View {
        ZStack {
            // Deep optical frosted blur base
            LiquidGlassBackdrop(material: .fullScreenUI, blendingMode: .behindWindow)

            // Semi-translucent dark glass tint layer (frosted, not opaque black)
            Color(red: 0.10, green: 0.11, blue: 0.15)
                .opacity(0.48)

            stateAura

            // Inner soft top specular sheen
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.30), location: 0.0),
                    .init(color: Color.white.opacity(0.06), location: 0.45),
                    .init(color: Color.clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(Capsule())
        .overlay(
            // Outer beveled glass edge with golden/white luminous refraction as in Apple reference
            Capsule()
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.72), location: 0.0),
                            .init(color: Color(red: 1.0, green: 0.94, blue: 0.78).opacity(0.75), location: 0.20),
                            .init(color: Color(red: 0.50, green: 0.80, blue: 1.0).opacity(0.40), location: 0.45),
                            .init(color: Color(red: 0.85, green: 0.55, blue: 1.0).opacity(0.45), location: 0.70),
                            .init(color: Color(red: 1.0, green: 0.92, blue: 0.70).opacity(0.70), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.3
                )
        )
    }
}

// MARK: - Liquid Glass Window Background

/// Liquid Glass background view for larger floating windows (e.g., AIAssistantView)
public struct LiquidGlassWindowBackground: View {
    public var cornerRadius: CGFloat
    public var isThinking: Bool

    public init(cornerRadius: CGFloat = 18, isThinking: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isThinking = isThinking
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Native Liquid Glass surface; content above it stays crisp.
                Color.clear
                    .glassEffect(
                        .regular.tint(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.60)),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .shadow(color: Color.black.opacity(0.40), radius: 24, x: 0, y: 12)
                    .shadow(color: Color.black.opacity(0.20), radius: 6, x: 0, y: 2)
            } else {
                legacyWindowBody
            }
        }
    }

    /// Manual frosted-glass stack for macOS 13–25.
    private var legacyWindowBody: some View {
        ZStack {
            // Hardware accelerated deep blur
            LiquidGlassBackdrop(material: .fullScreenUI, blendingMode: .behindWindow)

            // Dark tinted glass layer
            Color(red: 0.08, green: 0.09, blue: 0.13)
                .opacity(0.82)

            // Ambient liquid aurora
            FluidLiquidAura(
                audioLevel: isThinking ? 0.6 : 0.1,
                tint: isThinking ? Color(red: 0.8, green: 0.4, blue: 1.0) : nil
            )

            // Specular sheen along the top edge
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.12), location: 0.0),
                    .init(color: Color.white.opacity(0.01), location: 0.3),
                    .init(color: Color.clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.40), location: 0.0),
                            .init(color: Color.white.opacity(0.12), location: 0.3),
                            .init(color: Color(red: 0.5, green: 0.7, blue: 1.0).opacity(0.18), location: 0.55),
                            .init(color: Color(red: 0.7, green: 0.4, blue: 1.0).opacity(0.20), location: 0.85),
                            .init(color: Color.white.opacity(0.28), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Color.black.opacity(0.40), radius: 24, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.20), radius: 6, x: 0, y: 2)
    }
}
