import SwiftUI
import SwiftData
import Combine
import AVFoundation

@MainActor
class AppState: ObservableObject {
    // MARK: - Recording State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastTranscription: String?
    @Published var isTranscribing = false
    @Published var transcriptionError: String?

    // MARK: - UI State
    @Published var selectedSidebarItem: SidebarItem = .home
    @Published var showOnboarding = false

    // MARK: - Services
    let audioService = AudioRecordingService()
    let hotkeyService = HotkeyService.shared
    let settingsService = SettingsService.shared

    // MARK: - Storage
    private var recordingStorageService: RecordingStorageService?

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private var recordingURL: URL?
    private var workflowInProgress = false // Lock for entire record→transcribe→paste cycle
    private var isStoppingRecording = false // Prevent duplicate stop Tasks

    init() {
        setupBindings()
        setupNotificationObservers()
        checkOnboardingStatus()
    }

    private func setupBindings() {
        // Sync audio service recording state
        audioService.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        audioService.$recordingDuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .performToggleRecording)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.toggleRecording()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .shortcutTriggered)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let action = notification.object as? ShortcutAction else { return }
                self?.handleShortcutAction(action)
            }
            .store(in: &cancellables)
    }

    private func checkOnboardingStatus() {
        // Show onboarding if API key not set
        if KeychainService.shared.getAPIKey() == nil {
            showOnboarding = true
        }
    }

    // MARK: - Storage Setup

    func setModelContext(_ context: ModelContext) {
        self.recordingStorageService = RecordingStorageService(modelContext: context)
    }

    // MARK: - Recording Actions

    func toggleRecording() {
        if isRecording {
            // Allow stopping even during workflow (that's expected)
            stopRecording()
        } else {
            // Prevent starting new recording while workflow is in progress
            guard !workflowInProgress else {
                print("Workflow in progress, ignoring start request")
                return
            }
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else {
            print("Already recording, ignoring start request")
            return
        }
        guard !workflowInProgress else {
            print("Workflow in progress, ignoring start request")
            return
        }

        // Set workflow lock at the START of the cycle
        workflowInProgress = true

        Task {
            do {
                try await audioService.startRecording()
                // Show overlay
                NotificationCenter.default.post(name: .showRecordingOverlay, object: self)
            } catch {
                transcriptionError = "Failed to start recording: \(error.localizedDescription)"
                workflowInProgress = false // Release lock on failure
            }
        }
    }

    func stopRecording() {
        guard isRecording else {
            print("Not recording, ignoring stop request")
            return
        }
        guard !isStoppingRecording else {
            print("Already stopping recording, ignoring duplicate request")
            return
        }

        isStoppingRecording = true

        Task {
            // Capture duration before stopping (it gets reset)
            let duration = recordingDuration

            recordingURL = await audioService.stopRecording()
            // Don't hide overlay yet - let it show processing state

            if let url = recordingURL {
                // Validate minimum duration
                if duration < AudioRecordingService.minimumRecordingDuration {
                    audioService.deleteRecording(at: url)
                    transcriptionError = RecordingError.recordingTooShort.localizedDescription
                    NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                    isStoppingRecording = false
                    workflowInProgress = false
                    return
                }

                await transcribeRecording(url: url)
            } else {
                // No URL means recording was cancelled or failed - hide now
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                isStoppingRecording = false
                workflowInProgress = false
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        Task {
            _ = await audioService.stopRecording()
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            // Don't transcribe, just discard - release all locks
            isStoppingRecording = false
            workflowInProgress = false
        }
    }

    // MARK: - Transcription

    private func transcribeRecording(url: URL) async {
        guard !isTranscribing else {
            print("Already transcribing, ignoring duplicate request")
            // Reset flags and hide overlay since we're not proceeding
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            isStoppingRecording = false
            workflowInProgress = false
            return
        }

        isTranscribing = true
        transcriptionError = nil

        // Capture recording metadata before transcription
        let duration = recordingDuration
        let audioFileName = url.lastPathComponent

        defer {
            // Always release all locks when transcription completes (success or failure)
            isTranscribing = false
            isStoppingRecording = false
            workflowInProgress = false
            // Hide overlay after workflow completes
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
        }

        do {
            let transcriptionService = TranscriptionService()
            let originalResult = try await transcriptionService.transcribe(audioURL: url)

            // Check for empty transcription (silence/no speech detected)
            if originalResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptionError = RecordingError.noSpeechDetected.localizedDescription
                return
            }

            var finalResult = originalResult
            var enhancedResult: String? = nil

            // Apply GPT enhancement if enabled
            if settingsService.settings.isGPTEnhancementEnabled {
                let enhancementService = GPTEnhancementService()
                finalResult = try await enhancementService.enhance(text: originalResult)
                enhancedResult = finalResult
            }

            lastTranscription = finalResult

            // Determine target application for paste
            var targetApp: String? = nil

            // Auto-paste if enabled (only if we have text and weren't cancelled)
            if settingsService.settings.autoPasteEnabled && !finalResult.isEmpty {
                targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
                PasteService.shared.pasteText(finalResult)
            }

            // Save recording to history (enforces 100-item limit automatically)
            do {
                try recordingStorageService?.saveRecording(
                    duration: duration,
                    audioFileName: audioFileName,
                    originalTranscription: originalResult,
                    enhancedTranscription: enhancedResult,
                    isPasted: settingsService.settings.autoPasteEnabled && !finalResult.isEmpty,
                    targetApplication: targetApp
                )
            } catch {
                print("Failed to save recording to history: \(error)")
            }

            // Play completion sound if enabled
            if settingsService.settings.playCompletionSound {
                NSSound.beep()
            }

        } catch {
            transcriptionError = error.localizedDescription
        }
    }

    // MARK: - Shortcut Actions

    private func handleShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .toggleRecording:
            toggleRecording()
        case .startRecording:
            startRecording()
        case .stopRecording:
            stopRecording()
        case .cancelRecording:
            cancelRecording()
        case .openMainWindow:
            openMainWindow()
        }
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Sidebar Items

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case history = "History"
    case shortcuts = "Shortcuts"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .shortcuts: return "keyboard"
        case .settings: return "gear"
        }
    }
}
