import SwiftUI

// MARK: - Color Tokens

enum FluentColors {
    // Brand
    static let primary = Color.accentColor
    static let primaryHover = Color.accentColor.opacity(0.8)

    // Semantic
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue

    // Surfaces
    static let background = Color(NSColor.windowBackgroundColor)
    static let surface = Color(NSColor.controlBackgroundColor)
    static let surfaceSecondary = Color(NSColor.unemphasizedSelectedContentBackgroundColor)
    static let surfaceHover = Color(NSColor.controlBackgroundColor).opacity(0.8)
    static let surfaceElevated = Color(NSColor.textBackgroundColor)

    // Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(NSColor.tertiaryLabelColor)

    // Borders
    static let border = Color(NSColor.separatorColor)
    static let borderLight = Color.white.opacity(0.1)
}

// MARK: - Spacing Scale (4pt base grid)

enum FluentSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32

    // Semantic spacing
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let elementSpacing: CGFloat = 8
}

// MARK: - Corner Radius

enum FluentRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let full: CGFloat = 999
}

// MARK: - Shadows / Elevation

enum FluentElevation {
    case none
    case low
    case medium
    case high

    var shadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        switch self {
        case .none:
            return (.clear, 0, 0, 0)
        case .low:
            return (.black.opacity(0.05), 4, 0, 2)
        case .medium:
            return (.black.opacity(0.1), 8, 0, 4)
        case .high:
            return (.black.opacity(0.15), 16, 0, 8)
        }
    }
}

// MARK: - Animation Presets

enum FluentAnimation {
    static let fast = Animation.easeOut(duration: 0.15)
    static let normal = Animation.easeInOut(duration: 0.2)
    static let slow = Animation.easeInOut(duration: 0.3)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
}

// MARK: - Transition Presets

extension AnyTransition {
    static let fluentSlide = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    static let fluentScale = AnyTransition.scale(scale: 0.95).combined(with: .opacity)

    static let fluentFade = AnyTransition.opacity
}
