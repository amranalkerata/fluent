import SwiftUI
import SwiftData

@main
struct FluentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Recording.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        #if DEBUG
        PunctuationSelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        // Main application window with sidebar navigation
        Window("Fluent", id: "main") {
            MainWindow()
                .environmentObject(appState)
                .onAppear {
                    // Inject model context into AppState for saving recordings
                    appState.setModelContext(sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Recording") {
                Button("Start Recording") {
                    appState.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appState.isRecording)

                Button("Stop Recording") {
                    appState.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!appState.isRecording)
            }
        }

        // Menu bar presence
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .modelContainer(sharedModelContainer)
    }
}

#if DEBUG
/// Terminal check for text formatting, without showing any UI:
///   Fluent.app/Contents/MacOS/Fluent --punctuation-selftest "some text"
/// Prints the formatted result (same TextFormattingService path, formatting forced on) and exits.
enum PunctuationSelfTest {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--audio-device-selftest") {
            // Which input the next recording will use, without touching the microphone
            print(AudioDeviceManager.shared.preferredDeviceName ?? "system default input")
            fflush(stdout)
            exit(0)
        }
        if arguments.contains("--mute-selftest") {
            // Cost of the Core Audio calls behind the recording mute, without changing the mute state
            print(SystemAudioService.shared.benchmarkCoreAudioCalls())
            fflush(stdout)
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--transcribe-dir"), index + 2 < arguments.count {
            // Batch accuracy check: raw Whisper output for every .wav in a folder, as TSV
            //   Fluent --transcribe-dir /path/to/wavs ar|auto
            runTranscriptionDirectory(arguments[index + 1], language: arguments[index + 2])
        }
        if let index = arguments.firstIndex(of: "--audar-dir"), index + 4 < arguments.count {
            // Same TSV check with the offline Audar engine (llama.cpp), model files given explicitly
            //   Fluent --audar-dir /path/to/wavs ar|auto model.gguf mmproj.gguf
            runAudarDirectory(arguments[index + 1], language: arguments[index + 2],
                              modelPath: arguments[index + 3], mmprojPath: arguments[index + 4])
        }
        if let index = arguments.firstIndex(of: "--audar-routing-selftest"), index + 2 < arguments.count {
            // Engine routing check through the real TranscriptionService path:
            //   Fluent --audar-routing-selftest /path/to/audio.wav ar|auto|en
            runAudarRouting(audioPath: arguments[index + 1], language: arguments[index + 2])
        }
        if let index = arguments.firstIndex(of: "--latency-selftest"), index + 2 < arguments.count {
            // Stop-path stage timings through the real TranscriptionService path, one row per clip:
            //   Fluent --latency-selftest /path/to/clips ar|auto
            runLatencySelfTest(arguments[index + 1], language: arguments[index + 2])
        }
        if let index = arguments.firstIndex(of: "--transcribe-selftest"), index + 1 < arguments.count {
            runTranscription(audioPath: arguments[index + 1])
        }
        guard let index = arguments.firstIndex(of: "--punctuation-selftest") else { return }
        let text = index + 1 < arguments.count ? arguments[index + 1] : ""

        Task { @MainActor in
            let loadStart = Date()
            try? await PunctuationModelManager.shared.loadModel()
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)

            let formatStart = Date()
            let result = await TextFormattingService().formatIgnoringSetting(text: text)
            let formatMs = Int(Date().timeIntervalSince(formatStart) * 1000)

            let state = PunctuationModelManager.shared.state
            FileHandle.standardError.write(Data("[selftest] state=\(state) load=\(loadMs)ms format=\(formatMs)ms\n".utf8))
            print(result)
            fflush(stdout)
            exit(0)
        }
        // Serve the main queue until the task exits; never returns.
        dispatchMain()
    }

    private static func runTranscriptionDirectory(_ path: String, language: String) -> Never {
        Task { @MainActor in
            do {
                let manager = ModelManager.shared
                if !manager.isModelDownloaded { try await manager.downloadModel() }
                try await manager.loadModel()
                let files = try FileManager.default.contentsOfDirectory(atPath: path)
                    .filter { $0.hasSuffix(".wav") }.sorted()
                for file in files {
                    let url = URL(fileURLWithPath: path).appendingPathComponent(file)
                    let samples = try await AudioConverter.convertToWhisperSamples(url: url)
                    let start = Date()
                    let text = try await manager.transcribe(samples: samples, language: language == "auto" ? nil : language)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("\(file)\t\(ms)\t\(text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))")
                    fflush(stdout)
                }
            } catch {
                FileHandle.standardError.write(Data("[selftest] error: \(error.localizedDescription)\n".utf8))
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func runAudarDirectory(_ path: String, language: String, modelPath: String, mmprojPath: String) -> Never {
        Task.detached(priority: .userInitiated) {
            do {
                let loadStart = Date()
                let engine = try AudarEngine(modelPath: modelPath, mmprojPath: mmprojPath)
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                FileHandle.standardError.write(Data("[selftest] audar load=\(loadMs)ms\n".utf8))
                let files = try FileManager.default.contentsOfDirectory(atPath: path)
                    .filter { $0.hasSuffix(".wav") }.sorted()
                for file in files {
                    let url = URL(fileURLWithPath: path).appendingPathComponent(file)
                    let samples = try await AudioConverter.convertToWhisperSamples(url: url)
                    let start = Date()
                    let text = try engine.transcribe(samples: samples, language: language == "auto" ? nil : language)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("\(file)\t\(ms)\t\(text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))")
                    fflush(stdout)
                }
            } catch {
                FileHandle.standardError.write(Data("[selftest] error: \(error.localizedDescription)\n".utf8))
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Audar model files from the local Hugging Face cache, used instead of downloading 2.8 GB
    /// again. DEBUG only: release builds always download from AudarAI's official repository.
    private static var audarCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--audarai--Audar-ASR-V1-Turbo/snapshots")
            .appendingPathComponent(AudarModelManager.revision)
    }

    /// Installs (if missing) and SHA-256-verifies the Audar files in the app's AudarModels folder,
    /// loads Whisper + Audar, runs TranscriptionService.transcribe(audioURL:) with the given
    /// language and prints the engine that was chosen and the text. Settings are restored on exit.
    private static func runAudarRouting(audioPath: String, language: String) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[selftest] \(line)\n".utf8)) }
            let settingsService = SettingsService.shared
            let originalSettings = settingsService.settings
            do {
                settingsService.settings.language = language == "auto"
                    ? .auto
                    : (AppSettings.TranscriptionLanguage(rawValue: language) ?? .auto)
                settingsService.settings.audarEnabled = true
                if !settingsService.settings.audarLicenseAccepted {
                    settingsService.settings.audarLicenseAcceptedAt = Date()
                }

                let audar = AudarModelManager.shared
                log("audar dir: \(AudarModelManager.modelsDirectory.path)")
                if !audar.isModelDownloaded {
                    log("installing Audar files from \(audarCacheDirectory.path)")
                    let start = Date()
                    try await audar.installFromLocalDirectory(audarCacheDirectory)
                    log("installed in \(Int(Date().timeIntervalSince(start) * 1000))ms")
                }
                let verifyStart = Date()
                try await audar.verifyInstalledFiles()
                log("sha256 verify: OK (\(Int(Date().timeIntervalSince(verifyStart) * 1000))ms)")

                let whisper = ModelManager.shared
                if !whisper.isModelDownloaded { try await whisper.downloadModel() }
                let loadStart = Date()
                try await whisper.loadModel()
                try? await PunctuationModelManager.shared.loadModel()
                try await audar.loadModel()
                log("engines loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000))ms, audar usable=\(audar.isUsable)")

                let service = TranscriptionService()
                let start = Date()
                let text = try await service.transcribe(audioURL: URL(fileURLWithPath: audioPath))
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                log("language=\(language) engine=\(service.lastEngine?.rawValue ?? "none") reason=\(service.lastRouteReason ?? "") time=\(ms)ms")
                print("\(service.lastEngine?.rawValue ?? "none")\t\(text)")
            } catch {
                log("error: \(error.localizedDescription)")
            }
            settingsService.settings = originalSettings
            AudarModelManager.shared.unloadModel() // llama.cpp asserts at exit if the engine is alive
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }

    /// Loads Whisper, punctuation and Audar (already installed in AudarModels), then runs
    /// TranscriptionService.transcribe(audioURL:) on every .wav/.m4a in `path` (sorted; files
    /// starting with "00_" are warm-up and left out of the averages) and prints a TSV of stage
    /// timings in ms. Formatting is forced on; settings are restored on exit.
    private static func runLatencySelfTest(_ path: String, language: String) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[latency] \(line)\n".utf8)) }
            let settingsService = SettingsService.shared
            let originalSettings = settingsService.settings
            do {
                settingsService.settings.language = language == "auto"
                    ? .auto
                    : (AppSettings.TranscriptionLanguage(rawValue: language) ?? .auto)
                settingsService.settings.formatTextEnabled = true
                settingsService.settings.audarEnabled = true
                if !settingsService.settings.audarLicenseAccepted {
                    settingsService.settings.audarLicenseAcceptedAt = Date()
                }

                let whisper = ModelManager.shared
                let audar = AudarModelManager.shared
                guard whisper.isModelDownloaded, audar.isModelDownloaded else {
                    throw TranscriptionError.modelNotReady
                }
                let loadStart = Date()
                try await whisper.loadModel()
                try await PunctuationModelManager.shared.loadModel()
                try await audar.loadModel()
                log("engines loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000))ms, audar usable=\(audar.isUsable)")

                let files = try FileManager.default.contentsOfDirectory(atPath: path)
                    .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") }.sorted()
                print("file\taudio_s\tconvert\tdetect\tasr\troute_asr\tformat\ttotal\tengine\treason\ttext")
                var rows: [TranscriptionService.StageTimings] = []
                for file in files {
                    let service = TranscriptionService()
                    let text = try await service.transcribe(audioURL: URL(fileURLWithPath: path).appendingPathComponent(file))
                    let t = service.lastTimings
                    let f = { (value: Double?) in value.map { String(format: "%.0f", $0) } ?? "-" }
                    print([file, String(format: "%.1f", t.audioSeconds), f(t.conversionMs), f(t.detectionMs),
                           f(t.asrMs), f(t.routeAndAsrMs), f(t.formattingMs), f(t.totalMs),
                           service.lastEngine?.rawValue ?? "none", service.lastRouteReason ?? "",
                           text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")]
                        .joined(separator: "\t"))
                    fflush(stdout)
                    if !file.hasPrefix("00_") { rows.append(t) }
                }
                if !rows.isEmpty {
                    let mean = { (key: (TranscriptionService.StageTimings) -> Double) in
                        String(format: "%.0f", rows.map(key).reduce(0, +) / Double(rows.count))
                    }
                    let detections = rows.compactMap(\.detectionMs)
                    let detect = detections.isEmpty ? "-" : String(format: "%.0f", detections.reduce(0, +) / Double(detections.count))
                    print(["MEAN(\(rows.count))", String(format: "%.1f", rows.map(\.audioSeconds).reduce(0, +) / Double(rows.count)),
                           mean(\.conversionMs), detect, mean(\.asrMs), mean(\.routeAndAsrMs),
                           mean(\.formattingMs), mean(\.totalMs)].joined(separator: "\t"))
                }
            } catch {
                log("error: \(error.localizedDescription)")
            }
            settingsService.settings = originalSettings
            AudarModelManager.shared.unloadModel() // llama.cpp asserts at exit if the engine is alive
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }

    /// Full pipeline check (Whisper + formatting) on an audio file:
    ///   Fluent.app/Contents/MacOS/Fluent --transcribe-selftest /path/to/audio.wav
    /// Downloads the Whisper model first if it is missing. Never returns.
    private static func runTranscription(audioPath: String) -> Never {
        Task { @MainActor in
            do {
                let manager = ModelManager.shared
                if !manager.isModelDownloaded {
                    FileHandle.standardError.write(Data("[selftest] downloading Whisper model…\n".utf8))
                    try await manager.downloadModel()
                }
                let loadStart = Date()
                try await manager.loadModel()
                try? await PunctuationModelManager.shared.loadModel()
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)

                let samples = try await AudioConverter.convertToWhisperSamples(url: URL(fileURLWithPath: audioPath))
                let raw = try await manager.transcribe(samples: samples, language: nil)
                FileHandle.standardError.write(Data("[selftest] raw whisper: \(raw)\n".utf8))

                let start = Date()
                let text = try await TranscriptionService().transcribe(audioURL: URL(fileURLWithPath: audioPath))
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                FileHandle.standardError.write(Data("[selftest] load=\(loadMs)ms transcribe+format=\(ms)ms\n".utf8))
                print(text)
            } catch {
                FileHandle.standardError.write(Data("[selftest] error: \(error.localizedDescription)\n".utf8))
            }
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }
}
#endif
