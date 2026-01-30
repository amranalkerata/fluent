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
    @Published var partialTranscription: String?  // Real-time transcription during recording
    @Published var isModelLoading = false  // Track model loading state for UI feedback

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
        // Show onboarding if not completed or model not downloaded
        if !SettingsService.shared.isOnboardingComplete || !ModelManager.shared.isModelDownloaded {
            showOnboarding = true
        } else {
            // Load model on app start and track completion
            loadModelOnStartup()
        }
    }

    private func loadModelOnStartup() {
        isModelLoading = true
        Task {
            do {
                try await ModelManager.shared.loadModel()
            } catch {
                transcriptionError = "Failed to load model: \(error.localizedDescription)"
            }
            isModelLoading = false
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
                return
            }
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else {
            return
        }
        guard !workflowInProgress else {
            return
        }

        // Check if model is ready - provide specific feedback based on state
        let modelState = ModelManager.shared.state
        guard modelState.isReady else {
            switch modelState {
            case .loading:
                transcriptionError = "Model is still loading, please wait a moment..."
            case .downloading:
                transcriptionError = "Model is still downloading. Please wait for download to complete."
            case .retrying(let attempt, let maxAttempts):
                transcriptionError = "Download interrupted, retrying (\(attempt)/\(maxAttempts))..."
            case .downloaded:
                // Model downloaded but not loaded - try to load it now
                transcriptionError = "Loading model, please try again in a moment..."
                loadModelOnStartup()
            case .notDownloaded, .error:
                transcriptionError = "WhisperKit model not ready. Please download and load the model in Settings."
            case .ready:
                break // Won't reach here due to guard
            }
            return
        }

        // Set workflow lock at the START of the cycle
        workflowInProgress = true
        partialTranscription = nil  // Clear any previous partial transcription

        Task {
            do {
                try await audioService.startRecording()
                SoundService.shared.playRecordingSound()
                // Show overlay
                NotificationCenter.default.post(name: .showRecordingOverlay, object: self)
                // Note: Streaming transcription removed - file-based transcription is faster
                // (streaming had O(n²) complexity, re-transcribing all audio every second)
            } catch {
                transcriptionError = "Failed to start recording: \(error.localizedDescription)"
                workflowInProgress = false // Release lock on failure
            }
        }
    }

    func stopRecording() {
        guard isRecording else {
            return
        }
        guard !isStoppingRecording else {
            return
        }

        isStoppingRecording = true

        Task {
            // Capture duration before stopping (it gets reset)
            let duration = recordingDuration

            recordingURL = await audioService.stopRecording()
            SoundService.shared.playRecordingSound()
            // Don't hide overlay yet - let it show processing state

            if let url = recordingURL {
                // Validate minimum duration
                if duration < AudioRecordingService.minimumRecordingDuration {
                    audioService.deleteRecording(at: url)
                    transcriptionError = RecordingError.recordingTooShort.localizedDescription
                    NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                    cleanupAfterRecording()
                    return
                }

                // Check for speech activity before sending to Whisper (prevents hallucinations on silence)
                if !audioService.hasSpeechActivity() {
                    audioService.deleteRecording(at: url)
                    transcriptionError = RecordingError.noSpeechDetected.localizedDescription
                    NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                    cleanupAfterRecording()
                    return
                }

                await transcribeRecording(url: url, duration: duration)
            } else {
                // No URL means recording was cancelled or failed - hide now
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                cleanupAfterRecording()
            }
        }
    }

    private func cleanupAfterRecording() {
        partialTranscription = nil
        isStoppingRecording = false
        workflowInProgress = false
    }

    func cancelRecording() {
        guard isRecording else { return }

        Task {
            _ = await audioService.stopRecording()
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            // Don't transcribe, just discard - release all locks
            cleanupAfterRecording()
        }
    }

    // MARK: - Transcription

    private func transcribeRecording(url: URL, duration: TimeInterval) async {
        guard !isTranscribing else {
            // Reset flags and hide overlay since we're not proceeding
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            cleanupAfterRecording()
            return
        }

        isTranscribing = true
        transcriptionError = nil

        defer {
            // Always release all locks when transcription completes (success or failure)
            isTranscribing = false
            // Hide overlay after workflow completes
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            // Delete the audio file - no longer needed after transcription
            audioService.deleteRecording(at: url)
            cleanupAfterRecording()
        }

        do {
            // Use file-based transcription (fast, single-pass O(n) complexity)
            let transcriptionService = TranscriptionService()
            let result = try await transcriptionService.transcribe(audioURL: url)

            // Check for empty transcription (silence/no speech detected)
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptionError = RecordingError.noSpeechDetected.localizedDescription
                return
            }

            lastTranscription = result
            partialTranscription = nil  // Clear partial now that we have final

            // Determine target application for paste
            var targetApp: String? = nil

            // Auto-paste (only if we have text and weren't cancelled)
            if !result.isEmpty {
                targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
                PasteService.shared.pasteText(result)
            }

            // Save recording to history (enforces 100-item limit automatically)
            do {
                try recordingStorageService?.saveRecording(
                    duration: duration,
                    audioFileName: nil,  // Audio file is deleted after transcription
                    originalTranscription: result,
                    enhancedTranscription: nil,  // No GPT enhancement anymore
                    isPasted: !result.isEmpty,
                    targetApplication: targetApp
                )
            } catch {
                // Silently handle storage errors
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
        case .pasteLastTranscript:
            pasteLastTranscript()
        }
    }

    func openMainWindow() {
        // Restore Dock presence before showing window (if hidden)
        AppDelegate.shared?.restoreDockPresence()

        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func pasteLastTranscript() {
        guard let text = lastTranscription, !text.isEmpty else { return }
        PasteService.shared.pasteText(text)
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
