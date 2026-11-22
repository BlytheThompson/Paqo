import SwiftUI

/// Paqo's look: dark charcoal, one electric-mint accent, big clean numbers.
/// Shared by the app and the Live Activity widget.
enum Theme {
    static let background = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x15181D)
    static let surfaceRaised = Color(hex: 0x1E2229)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(hex: 0x34F5C5)
    static let accentDim = Color(hex: 0x34F5C5, opacity: 0.16)
    static let walk = Color(hex: 0x7A8494)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0x8B95A5)
    static let danger = Color(hex: 0xFF5A5F)

    /// Large numeric readouts.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// Small caps-style labels under numbers ("TIME", "DISTANCE").
    static let label = Font.system(size: 11, weight: .semibold).width(.expanded)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
