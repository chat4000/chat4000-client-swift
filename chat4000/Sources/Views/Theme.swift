import SwiftUI

// MARK: - Colors

enum AppColors {
    static let background = Color(hex: 0x0F0F0F)
    static let cardBackground = Color(hex: 0x141414)
    static let inputBackground = Color(hex: 0x1E1E1E)
    static let inputBorder = Color(hex: 0x2A2A2A)
    static let inputBorderFocused = Color(hex: 0x505050)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0x9CA3AF)
    static let textTimestamp = Color(hex: 0x666666)

    static let agentBubble = Color(hex: 0x1A1A1A)
    static let agentBubbleText = Color(hex: 0xE0E0E0)

    static let connected = Color(hex: 0x10B981)
    static let reconnecting = Color(hex: 0xF59E0B)
    static let disconnected = Color(hex: 0xEF4444)

    static let error = Color(hex: 0xFF4A4A)
    static let errorBackground = Color(hex: 0xFF4A4A).opacity(0.1)

    static let destructive = Color(hex: 0xFF4A4A)
}

// MARK: - Typography

enum AppFonts {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    #if os(macOS)
    static let title = mono(20, weight: .bold)
    static let subtitle = mono(11, weight: .regular)
    static let label = mono(11, weight: .medium)
    static let input = mono(12, weight: .regular)
    static let button = mono(12, weight: .medium)
    static let body = mono(12, weight: .regular)
    #else
    static let title = mono(28, weight: .bold)
    static let subtitle = mono(14, weight: .regular)
    static let label = mono(14, weight: .medium)
    static let input = mono(16, weight: .regular)
    static let button = mono(16, weight: .medium)
    static let body = mono(15, weight: .regular)
    #endif
    #if os(macOS)
    static let timestamp = mono(10, weight: .regular)
    static let caption = mono(10, weight: .regular)
    static let navTitle = mono(14, weight: .bold)
    static let sheetTitle = mono(16, weight: .bold)
    static let sectionTitle = mono(11, weight: .medium)
    #else
    static let timestamp = mono(12, weight: .regular)
    static let caption = mono(12, weight: .regular)
    static let navTitle = mono(20, weight: .bold)
    static let sheetTitle = mono(22, weight: .bold)
    static let sectionTitle = mono(14, weight: .medium)
    #endif
}

// MARK: - Spacing

enum AppSpacing {
    static let cardPadding: CGFloat = 24
    static let inputPadding: CGFloat = 16
    #if os(macOS)
    static let messageRowInset: CGFloat = 10
    static let messagePaddingH: CGFloat = 14
    static let messagePaddingV: CGFloat = 10
    static let messageGap: CGFloat = 8
    static let messageGroupGap: CGFloat = 18
    static let chatListVerticalInset: CGFloat = 8
    static let inputBarBottomInset: CGFloat = 4
    static let navBarBottomInset: CGFloat = 2
    #else
    static let messageRowInset: CGFloat = 16
    static let messagePaddingH: CGFloat = 16
    static let messagePaddingV: CGFloat = 12
    static let messageGap: CGFloat = 12
    static let messageGroupGap: CGFloat = 24
    static let chatListVerticalInset: CGFloat = 16
    static let inputBarBottomInset: CGFloat = 8
    static let navBarBottomInset: CGFloat = 5
    #endif
}

// MARK: - Radii

enum AppRadius {
    static let card: CGFloat = 14
    static let button: CGFloat = 8
    static let input: CGFloat = 8
    static let messageBubble: CGFloat = 18
    static let messageTail: CGFloat = 4
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
