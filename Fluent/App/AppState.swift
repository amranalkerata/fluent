import SwiftUI
import SwiftData
import Combine
import AVFoundation
import UserNotifications

@MainActor
class AppState: ObservableObject {
    // MARK: - Recording State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastTranscription: String?
    @Published var isTranscribing = false
    @Published var transcriptionError: String?
    @Published var partialTranscription: String?  // Real-time transcription during recording
    @Published var isShowingLoadingOverlay = false  // Show floating bar with loading message

    /// Computed property that reflects the actual model loading state from ModelManager
    var isModelLoading: Bool {
        let state = ModelManager.shared.state
        switch state {
        case .loading, .downloading, .retrying, .downloaded:
            return true
        case .ready, .notDownloaded, .error:
            return false
        }
    }

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
    /// `LatencyLog.now()` of the shortcut press being handled, for the timing log.
    private var shortcutPressedAt: UInt64?
    /// Transcribes the current recording while it is recorded (Audar routes only).
    private var incrementalSession: IncrementalTranscriber?
    /// Types `incrementalSession`'s segments into the frontmost app while recording.
    private var liveTyping: LiveTypingRun?

    init() {
        _ = AudioDeviceManager.shared  // Start listening for audio device changes early
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

        // Observe ModelManager.state changes to trigger UI updates for isModelLoading
        ModelManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
                self?.shortcutPressedAt = notification.userInfo?[HotkeyService.pressedAtKey] as? UInt64
                self?.handleShortcutAction(action)
                self?.shortcutPressedAt = nil
            }
            .store(in: &cancellables)
    }

    private func checkOnboardingStatus() {
        // Show onboarding if not completed or the Whisper model is not downloaded
        // (the punctuation model is bundled with the app)
        let whisperReady = ModelManager.shared.isModelDownloaded

        if !SettingsService.shared.isOnboardingComplete || !whisperReady {
            showOnboarding = true
        } else {
            // Load models on app start and track completion
            loadModelsOnStartup()
        }
    }

    private func loadModelsOnStartup() {
        // isModelLoading is now a computed property based on ModelManager.state
        // No need to set it manually - it automatically reflects the true state
        Task {
            // Load Whisper model
            do {
                try await ModelManager.shared.loadModel()
            } catch {
                transcriptionError = "Failed to load Whisper model: \(error.localizedDescription)"
            }

            // Load punctuation model if format text is enabled
            // Model is bundled with the app, just need to load it into memory
            if settingsService.settings.formatTextEnabled {
                try? await PunctuationModelManager.shared.loadModel()
            }

            // Warm-up: the first prediction of each Core ML model is ~1 s slower than the
            // rest. Pay that now, in the background, instead of on the first dictation.
            _ = try? await PunctuationModelManager.shared.infer(text: "مرحبا كيف حالك اليوم")
            if ModelManager.shared.state.isReady {
                _ = try? await ModelManager.shared.detectLanguage(samples: [Float](repeating: 0, count: 16_000))
            }

            // Then the Audar Arabic engine, if downloaded, switched on and licensed.
            // It loads in the background; recordings use Whisper until it is ready.
            AudarModelManager.shared.loadIfConfigured()
        }
    }

    /// Load punctuation model on demand (called when format text setting is toggled on)
    func loadPunctuationModelIfNeeded() {
        guard settingsService.settings.formatTextEnabled else { return }

        Task {
            try? await PunctuationModelManager.shared.loadModel()
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
        let pressedAt = shortcutPressedAt ?? LatencyLog.now()
        guard !isRecording else {
            return
        }
        guard !workflowInProgress else {
            return
        }

        // Check if model is ready - provide specific feedback based on state.
        // Arabic and auto-detect can also run on Audar alone.
        let modelState = ModelManager.shared.state
        let language = settingsService.settings.language
        let audarCanTranscribe = AudarModelManager.shared.isUsable && (language == .arabic || language == .auto)
        guard modelState.isReady || audarCanTranscribe else {
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
                loadModelsOnStartup()
            case .notDownloaded, .error:
                transcriptionError = "WhisperKit model not ready. Please download and load the model in Settings."
            case .ready:
                break // Won't reach here due to guard
            }
            // Show loading overlay with error message so user sees feedback
            showLoadingOverlay()
            return
        }

        // Set workflow lock at the START of the cycle
        workflowInProgress = true
        partialTranscription = nil  // Clear any previous partial transcription

        Task {
            do {
                let engineStart = LatencyLog.now()
                try await audioService.startRecording()
                LatencyLog.log("start.engine", since: engineStart)
                startIncrementalTranscription()
                LatencyLog.log("start.shortcut_to_engine", since: pressedAt)
                // Show overlay as soon as audio is being captured
                NotificationCenter.default.post(name: .showRecordingOverlay, object: self)
                LatencyLog.log("start.shortcut_to_overlay", since: pressedAt)
                SoundService.shared.playRecordingSound()       // Play sound first (while unmuted)
                // Then mute for recording, once the start sound has played (off the main thread)
                SystemAudioService.shared.muteForRecording(after: SoundService.shared.recordingSoundDuration)
            } catch {
                transcriptionError = "Failed to start recording: \(error.localizedDescription)"
                showLoadingOverlay()  // Show error so user knows what happened
                workflowInProgress = false // Release lock on failure
            }
        }
    }

    /// Transcribe finished speech segments while the user talks (Audar for Arabic/auto, Whisper for other languages),
    /// so only the last one is left at stop. Everything else keeps the full-file path.
    private func startIncrementalTranscription() {
        incrementalSession = nil
        liveTyping?.cancel()
        liveTyping = nil
        // Stopped already (the stop handler ran while this start was finishing): nothing to do.
        guard audioService.isRecording, !isStoppingRecording,
              let stream = audioService.audioStream else { return }

        // Type the words into the app the user is dictating into while they speak, unless that
        // is Fluent itself (or posting keyboard events is not allowed): then the text is pasted
        // at stop. Only a typed recording re-reads its open segment (streaming).
        var liveTarget: NSRunningApplication?
        if settingsService.settings.liveTypingEnabled,
           AXIsProcessTrusted(),
           let target = NSWorkspace.shared.frontmostApplication,
           target.bundleIdentifier != Bundle.main.bundleIdentifier {
            liveTarget = target
        }
        guard let session = IncrementalTranscriber.makeIfApplicable(
            stream: stream, streaming: liveTarget == nil ? nil : StreamingConfig()
        ) else { return }
        incrementalSession = session
        Task { await session.start() }
        if let liveTarget {
            liveTyping = LiveTypingRun(session: session, target: liveTarget)
        }
    }

    private func discardIncrementalSession() {
        liveTyping?.cancel()
        liveTyping = nil
        guard let session = incrementalSession else { return }
        incrementalSession = nil
        Task { await session.cancel() }
    }

    func stopRecording() {
        guard isRecording else {
            return
        }
        guard !isStoppingRecording else {
            return
        }

        isStoppingRecording = true
        let pressedAt = shortcutPressedAt ?? LatencyLog.now()

        Task {
            // Capture duration before stopping (it gets reset)
            let duration = recordingDuration

            recordingURL = await audioService.stopRecording()
            LatencyLog.log("stop.file_ready", since: pressedAt)
            let session = incrementalSession
            incrementalSession = nil
            let live = liveTyping
            liveTyping = nil
            SystemAudioService.shared.restoreAfterRecording()  // Unmute first
            SoundService.shared.playRecordingSound()           // Then play sound (now audible)
            // Don't hide overlay yet - let it show processing state

            if let url = recordingURL {
                // Validate minimum duration
                if duration < AudioRecordingService.minimumRecordingDuration {
                    await session?.cancel()
                    live?.cancel()
                    audioService.deleteRecording(at: url)
                    transcriptionError = RecordingError.recordingTooShort.localizedDescription
                    NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                    cleanupAfterRecording()
                    return
                }

                // Check for speech activity before sending to Whisper (prevents hallucinations on silence)
                if !audioService.hasSpeechActivity() {
                    await session?.cancel()
                    live?.cancel()
                    audioService.deleteRecording(at: url)
                    transcriptionError = RecordingError.noSpeechDetected.localizedDescription
                    // Brief delay so user sees the error message on the overlay
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                    cleanupAfterRecording()
                    return
                }

                await transcribeRecording(url: url, duration: duration, stopPressedAt: pressedAt,
                                          incremental: session, live: live)
            } else {
                await session?.cancel()
                live?.cancel()
                // No URL means recording was cancelled or failed - hide now
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                cleanupAfterRecording()
            }
        }
    }

    private func cleanupAfterRecording() {
        // Note: restoreAfterRecording() is now called immediately in stopRecording()
        // so the stop sound can play while unmuted
        partialTranscription = nil
        isStoppingRecording = false
        workflowInProgress = false
    }

    func cancelRecording() {
        guard isRecording else { return }

        discardIncrementalSession()
        Task {
            _ = await audioService.stopRecording()
            SystemAudioService.shared.restoreAfterRecording()  // Unmute on cancel
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
            // Don't transcribe, just discard - release all locks
            cleanupAfterRecording()
        }
    }

    /// Show the loading overlay briefly when user tries to record before model is ready
    private func showLoadingOverlay() {
        isShowingLoadingOverlay = true
        NotificationCenter.default.post(name: .showRecordingOverlay, object: self)

        // Auto-hide after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            isShowingLoadingOverlay = false
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
        }
    }

    // MARK: - Transcription

    /// How the text of a finished recording reaches the user.
    private enum Delivery {
        /// Paste the whole text at stop (no live typing).
        case paste(String)
        /// Typed while recording; paste only what could not be typed.
        case live(LiveTypingRun)
        /// Live typing was interrupted (the session fell back to the full-file path after some
        /// text was typed): the full-file text goes to the clipboard, not into the field.
        case clipboard(String, LiveTypingRun)
    }

    private func transcribeRecording(url: URL, duration: TimeInterval, stopPressedAt: UInt64,
                                     incremental: IncrementalTranscriber?, live: LiveTypingRun?) async {
        guard !isTranscribing else {
            await incremental?.cancel()
            live?.cancel()
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
            // Note: Overlay is now hidden BEFORE paste attempt (not here) to ensure
            // focus returns to target app. This defer handles cleanup and error cases.
            // Delete the audio file - no longer needed after transcription
            audioService.deleteRecording(at: url)
            cleanupAfterRecording()
        }

        do {
            // Segments already transcribed while recording, or the whole file (fast, single pass).
            let transcriptionService = TranscriptionService()
            let delivery: Delivery
            if let incremental, let live {
                delivery = try await finishLiveTyping(live, session: incremental, service: transcriptionService,
                                                      audioURL: url, duration: duration, stopPressedAt: stopPressedAt)
            } else if let incremental {
                delivery = .paste(try await transcriptionService.transcribe(
                    incremental: incremental, audioURL: url, recordedDuration: duration
                ))
            } else {
                delivery = .paste(try await transcriptionService.transcribe(audioURL: url))
            }

            let result: String
            switch delivery {
            case .paste(let text): result = text
            case .live(let run): result = run.fullText
            case .clipboard(let text, _): result = text
            }

            // Check for empty transcription (silence/no speech detected by hallucination filter)
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Set isTranscribing to false FIRST so overlay shows error state (not "Finalizing...")
                isTranscribing = false
                transcriptionError = RecordingError.noSpeechDetected.localizedDescription
                // Brief delay so user sees the error message on the overlay
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Hide overlay after showing error
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                return
            }

            lastTranscription = result
            partialTranscription = nil  // Clear partial now that we have final

            // Determine target application for paste
            var targetApp: String? = nil
            var pasteSucceeded = false

            switch delivery {
            case .paste:
                // CRITICAL: Capture target app BEFORE hiding overlay
                // The overlay might steal focus, so we need to know where to return
                targetApp = NSWorkspace.shared.frontmostApplication?.localizedName

                // Hide overlay FIRST to return focus to the target app
                // This is crucial - the overlay can steal focus and cause paste to fail
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)

                // Small delay to let focus settle back to target app
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                // Cmd+V is sent synchronously at the start of pasteText
                LatencyLog.log("stop.to_paste", since: stopPressedAt)
                pasteSucceeded = await paste(result)

            case .live(let run):
                targetApp = run.targetName
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                if run.pendingText.isEmpty {
                    pasteSucceeded = true
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms, as above
                    // The leading separator only belongs after the text typed into the same app.
                    let sameTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier == run.targetPID
                    let pending = sameTarget ? run.pendingText : run.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    LatencyLog.log("stop.to_paste", since: stopPressedAt)
                    pasteSucceeded = await paste(pending)
                }

            case .clipboard(let text, let run):
                targetApp = run.targetName
                NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
                PasteService.shared.copyToClipboard(text)
                showLiveTypingInterruptedNotification()
            }

            // Save recording to history (enforces 100-item limit automatically)
            do {
                try recordingStorageService?.saveRecording(
                    duration: duration,
                    audioFileName: nil,  // Audio file is deleted after transcription
                    originalTranscription: result,
                    enhancedTranscription: nil,  // No GPT enhancement anymore
                    isPasted: pasteSucceeded,
                    targetApplication: targetApp
                )
            } catch {
                // Silently handle storage errors
            }

        } catch {
            // Set isTranscribing to false FIRST so overlay shows error state (not "Finalizing...")
            isTranscribing = false
            transcriptionError = error.localizedDescription
            // Brief delay so user sees the error message on the overlay
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Hide overlay after showing error
            NotificationCenter.default.post(name: .hideRecordingOverlay, object: nil)
        }
    }

    /// Stop path of a live-typed recording: finishes the session, waits until every segment
    /// is typed (or set aside), then decides what is left to deliver. When nothing was typed
    /// live (language never settled, target changed before the first segment…) the recording
    /// is delivered exactly as without live typing.
    private func finishLiveTyping(_ live: LiveTypingRun, session: IncrementalTranscriber,
                                  service: TranscriptionService, audioURL: URL,
                                  duration: TimeInterval, stopPressedAt: UInt64) async throws -> Delivery {
        let startedAt = LatencyLog.now()
        let outcome = await service.finish(incremental: session, recordedDuration: duration)
        // The session has released its last segment (or closed the stream): wait for the typing.
        await live.drain()
        LatencyLog.log("stop.live_typed_segments", count: live.typedCount)
        if let typedAt = live.lastTypedAt {
            // 0 when everything was typed before the stop press.
            LatencyLog.log("stop.to_last_typed", ms: typedAt > stopPressedAt ? Double(typedAt - stopPressedAt) / 1_000_000 : 0)
        }

        switch outcome {
        case .transcript(let raw, _):
            if live.hasTyped {
                LatencyLog.log("stop.transcribe_total", since: startedAt)
                return .live(live)
            }
            let text = await service.postProcess(raw)
            LatencyLog.log("stop.transcribe_total", since: startedAt)
            return .paste(text)

        case .fallback(let reason):
            let text = try await service.transcribe(audioURL: audioURL, afterIncrementalFallback: reason)
            guard live.hasTyped else { return .paste(text) }
            // Nothing better than what was typed: keep it, paste what was set aside.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .live(live) }
            return .clipboard(text, live)
        }
    }

    /// Pastes `text` with PasteService (clipboard + Cmd+V) and reports a failure.
    private func paste(_ text: String) async -> Bool {
        let pasteStart = LatencyLog.now()

        // Use continuation to await the paste result
        let pasteResult = await withCheckedContinuation { continuation in
            PasteService.shared.pasteText(text) { result in
                continuation.resume(returning: result)
            }
        }
        LatencyLog.log("stop.paste", since: pasteStart)

        // Show notification if paste failed
        if !pasteResult.succeeded {
            showPasteFailedNotification(pasteResult: pasteResult)
        }
        return pasteResult.succeeded
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
        PasteService.shared.pasteText(text) { [weak self] result in
            if !result.succeeded {
                self?.showPasteFailedNotification(pasteResult: result)
            }
        }
    }

    // MARK: - Notifications

    private func showLiveTypingInterruptedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Live typing was interrupted"
        content.body = "The full dictation is on the clipboard — press ⌘V where you need it."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "live-typing-interrupted-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show live typing notification: \(error)")
            }
        }
    }

    private func showPasteFailedNotification(pasteResult: PasteResult) {
        let content = UNMutableNotificationContent()
        content.title = "Paste Failed"

        switch pasteResult {
        case .debounced:
            content.body = "Too fast! Text copied to clipboard - press ⌘V to paste."
        case .alreadyPasting:
            content.body = "Previous paste still in progress. Text copied to clipboard - press ⌘V to paste."
        case .clipboardFailed, .eventSourceFailed, .eventCreationFailed:
            content.body = "Text copied to clipboard - press ⌘V to paste."
        default:
            content.body = "Text available in history. Copy from there to paste."
        }

        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "paste-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show paste notification: \(error)")
            }
        }
    }
}

// MARK: - Live Typing

/// One recording's live typing: reads the session's events in order and types each committed
/// word into the app that was frontmost when the recording started, as soon as it comes. The
/// punctuation after a word is typed with the next word (or at the end of its segment), once
/// the punctuation model has seen what follows it. Nothing typed is ever deleted. From the
/// first part that cannot be typed there (another app came to the front, secure input, typing
/// failed) every later part is set aside in `pendingText`, pasted at stop.
@MainActor
final class LiveTypingRun {
    let targetPID: pid_t
    let targetName: String?
    /// All delivered text so far (typed, then pending), joined the way it is typed.
    private(set) var fullText = ""
    /// The part of `fullText` that could not be typed, with its leading separator.
    private(set) var pendingText = ""
    /// Parts typed so far (a part is one or more words, or a punctuation mark).
    private(set) var typedCount = 0
    /// `LatencyLog.now()` when the last part finished typing.
    private(set) var lastTypedAt: UInt64?
    private var typingActive = true
    private var cancelled = false
    private var consumer: Task<Void, Never>?
    /// Punctuation state of the segment being typed.
    private var segment = StreamingSegmentTyping()

    var hasTyped: Bool { typedCount > 0 }

    init(session: IncrementalTranscriber, target: NSRunningApplication) {
        targetPID = target.processIdentifier
        targetName = target.localizedName
        let events = session.liveEvents
        consumer = Task { [weak self] in
            for await event in events {
                guard let self, !self.cancelled else { return }
                await self.handle(event)
            }
        }
    }

    /// Returns once every released event has been typed or set aside (the session's stream
    /// must have finished, or `cancel` been called).
    func drain() async {
        await consumer?.value
    }

    /// Recording cancelled: stop typing. What was typed stays where it is.
    func cancel() {
        cancelled = true
        typingActive = false
        consumer?.cancel()
    }

    private func handle(_ event: LiveEvent) async {
        let formatting = SettingsService.shared.settings.formatTextEnabled
        let new: [String]
        let lookahead: [String]
        let isEnd: Bool
        switch event {
        case .words(let words, let rest):
            new = Self.prepare(words, formatting: formatting)
            lookahead = Self.prepare(rest, formatting: formatting)
            isEnd = false
            guard !new.isEmpty else { return }
        case .segmentEnd(let words):
            new = Self.prepare(words, formatting: formatting)
            lookahead = []
            isEnd = true
            guard !new.isEmpty || !segment.typed.isEmpty else { return }
        }

        let formatted = formatting ? await Self.punctuate(segment.modelInput(new: new, lookahead: lookahead)) : nil
        guard !cancelled else { return }
        let step = segment.step(new: new, lookahead: lookahead, formatted: formatted, isEnd: isEnd)
        if isEnd { segment = StreamingSegmentTyping() }
        await deliver(LiveTyping.part(after: fullText, step))
    }

    /// Committed words as typed: bracketed words unwrapped (sound tags dropped) and, when the
    /// punctuation model formats the text, without the engine's own sentence punctuation.
    static func prepare(_ words: [String], formatting: Bool) -> [String] {
        words.flatMap { word -> [String] in
            let unwrapped = SpeechCleanup.unwrapBrackets(word, nonSpeechPhrases: TranscriptionService.hallucinationPhrases)
            let text = formatting ? PunctuationEngine.stripTrailingSentencePunctuation(unwrapped) : unwrapped
            return StreamingText.words(text)
        }
    }

    /// The punctuation model's output for `text`, or nil when it is not available.
    static func punctuate(_ text: String) async -> String? {
        let model = PunctuationModelManager.shared
        if !model.state.isReady { try? await model.loadModel() }
        guard model.state.isReady else { return nil }
        return try? await model.infer(text: text)
    }

    private func deliver(_ part: String) async {
        guard !part.isEmpty else { return }
        fullText += part

        if typingActive, !cancelled,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
           !TypingService.shared.isSecureInputActive,
           await TypingService.shared.type(part) {
            typedCount += 1
            lastTypedAt = LatencyLog.now()
            return
        }
        typingActive = false
        pendingText += part
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
