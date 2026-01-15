import SwiftUI

// MARK: - Typography Scale

extension Font {
    enum Fluent {
        // Display - Large hero text
        static let displayLarge = Font.system(size: 34, weight: .bold)
        static let displayMedium = Font.system(size: 28, weight: .bold)

        // Headlines - Section headers
        static let headlineLarge = Font.largeTitle.bold()
        static let headlineMedium = Font.title2.bold()
        static let headlineSmall = Font.headline

        // Titles - Component titles
        static let titleLarge = Font.title3
        static let titleMedium = Font.headline
        static let titleSmall = Font.subheadline.weight(.medium)

        // Body - Main content
        static let bodyLarge = Font.body
        static let bodyMedium = Font.subheadline
        static let bodySmall = Font.footnote

        // Captions - Secondary text
        static let caption = Font.caption
        static let captionSmall = Font.caption2

        // Labels - UI labels
        static let labelLarge = Font.subheadline.weight(.medium)
        static let labelMedium = Font.caption.weight(.medium)
        static let labelSmall = Font.caption2.weight(.medium)

        // Monospace - Code, durations, keys
        static let mono = Font.system(.body, design: .monospaced)
        static let monoSmall = Font.system(.caption, design: .monospaced)

        // Rounded - Badges, tags
        static let rounded = Font.system(.body, design: .rounded)
        static let roundedSmall = Font.system(.caption, design: .rounded).weight(.medium)
    }
}

// MARK: - Text Style View Modifiers

extension View {
    func fluentDisplayLarge() -> some View {
        self.font(.Fluent.displayLarge)
    }

    func fluentHeadline() -> some View {
        self.font(.Fluent.headlineMedium)
    }

    func fluentTitle() -> some View {
        self.font(.Fluent.titleMedium)
    }

    func fluentBody() -> some View {
        self.font(.Fluent.bodyLarge)
    }

    func fluentCaption() -> some View {
        self.font(.Fluent.caption)
            .foregroundStyle(FluentColors.textSecondary)
    }

    func fluentMono() -> some View {
        self.font(.Fluent.mono)
    }
}
