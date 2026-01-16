import Foundation
import Combine
import ServiceManagement

class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @Published var settings: AppSettings {
        didSet {
            saveSettings()
        }
    }

    private let settingsKey = "com.fluent.settings"
    private let shortcutsKey = "com.fluent.shortcuts"
    private let onboardingCompleteKey = "com.fluent.onboardingComplete"
    private let hasSeenWelcomeKey = "com.fluent.hasSeenWelcome"

    private init() {
        settings = Self.loadSettings() ?? .default
    }

    // MARK: - Settings Persistence

    private static func loadSettings() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: "com.fluent.settings") else {
            return nil
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return nil
        }
    }

    private func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: settingsKey)
        } catch {
            // Silently handle encoding errors
        }
    }

    // MARK: - Shortcut Configuration

    func loadShortcutConfiguration() -> ShortcutConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: shortcutsKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        } catch {
            return nil
        }
    }

    func saveShortcutConfiguration(_ config: ShortcutConfiguration) {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: shortcutsKey)
        } catch {
            // Silently handle encoding errors
        }
    }

    // MARK: - Onboarding

    var isOnboardingComplete: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingCompleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingCompleteKey) }
    }

    var hasSeenWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: hasSeenWelcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasSeenWelcomeKey) }
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
        } catch {
            // Silently handle launch at login errors
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Reset

    func resetAllSettings() {
        settings = .default
        UserDefaults.standard.removeObject(forKey: shortcutsKey)
        UserDefaults.standard.removeObject(forKey: onboardingCompleteKey)
    }
}
