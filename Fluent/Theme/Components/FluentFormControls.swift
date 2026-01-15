import SwiftUI

// MARK: - Toggle

struct FluentToggle: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    init(title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text(title)
                    .font(.Fluent.titleSmall)

                if let description {
                    Text(description)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }
            }

            Spacer(minLength: FluentSpacing.lg)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Text Field

struct FluentTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String?

    init(_ placeholder: String, text: Binding<String>, icon: String? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: FluentSpacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(FluentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .stroke(FluentColors.border, lineWidth: 1)
        )
    }
}

// MARK: - Secure Field

struct FluentSecureField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        print("[FluentSecureField] init called")
        self.placeholder = placeholder
        self._text = text
        print("[FluentSecureField] init completed")
    }

    var body: some View {
        print("[FluentSecureField] body START")
        return HStack(spacing: FluentSpacing.sm) {
            Image(systemName: "key")
                .foregroundStyle(FluentColors.textSecondary)

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(FluentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .stroke(FluentColors.border, lineWidth: 1)
        )
    }
}

// MARK: - Search Field

struct FluentSearchField: View {
    @Binding var text: String
    let placeholder: String

    init(_ placeholder: String = "Search...", text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        HStack(spacing: FluentSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FluentColors.textSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FluentColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(FluentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surfaceElevated)
        )
    }
}

// MARK: - Preview

#Preview("Form Controls") {
    VStack(spacing: 20) {
        FluentToggle(
            title: "Auto-Paste",
            description: "Automatically paste transcription at cursor",
            isOn: .constant(true)
        )

        FluentTextField("Enter your name", text: .constant(""), icon: "person")

        FluentSecureField("API Key", text: .constant("sk-abc123"))

        FluentSearchField(text: .constant(""))
    }
    .padding()
    .frame(width: 400)
    .background(Color(NSColor.windowBackgroundColor))
}
