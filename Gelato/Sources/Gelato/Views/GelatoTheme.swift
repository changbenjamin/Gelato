import SwiftUI

enum GelatoTheme {
    static let sidebarBackground = Color(hex: 0xF7F3EC)
    static let detailBackground = Color(hex: 0xFEFEFC)
    static let canvasBackground = Color(hex: 0xFFFFFF)
    static let backgroundElevated = Color(hex: 0xF1E8DA)
    static let backgroundCard = Color(hex: 0xFFFDF9)
    static let backgroundSelection = Color(hex: 0xEAE3DA)
    static let ink = Color(hex: 0x2A1C0B)
    static let inkStrong = Color(hex: 0x000000)
    static let secondaryInk = Color(hex: 0x251A14)
    static let tertiaryInk = Color(hex: 0x444444)
    static let mutedInk = Color(hex: 0x666666)
    static let lightInk = Color(hex: 0x999999)
    static let accent = Color(hex: 0x9D7257)
    static let accentSoft = Color(hex: 0xEEDFD5)
    static let border = Color(hex: 0xD8CEC0)
    static let borderStrong = Color(hex: 0xBEAF99)
    static let success = Color(hex: 0x6CBF5B)
    static let danger = Color(hex: 0xC26A57)
    static let youTint = Color(hex: 0xEEE7DE)
    static let themTint = Color(hex: 0xF4E7D3)
}

extension Font {
    static func gelatoSerif(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension Color {
    init(hex: Int, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

extension Color {
    static let youColor = Color(hex: 0x6F655A)
    static let themColor = Color(hex: 0xA78362)
    static let accentTeal = GelatoTheme.accent

    static let warmBackground = GelatoTheme.detailBackground
    static let warmSidebarBg = GelatoTheme.sidebarBackground
    static let warmCanvasBg = GelatoTheme.canvasBackground
    static let warmCardBg = GelatoTheme.backgroundCard
    static let warmSelectionBg = GelatoTheme.backgroundSelection
    static let warmTextPrimary = GelatoTheme.ink
    static let warmTextSecondary = GelatoTheme.tertiaryInk
    static let warmTextMuted = GelatoTheme.mutedInk
    static let readingText = GelatoTheme.inkStrong.opacity(0.92)
    static let warmBorder = GelatoTheme.border
    static let warmHover = GelatoTheme.backgroundElevated
    static let warmYouTint = GelatoTheme.youTint
    static let warmThemTint = GelatoTheme.themTint
}
