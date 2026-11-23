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
        if let index = arguments.firstIndex(of: "--transcribe-dir"), index + 2 < arguments.count {
            // Batch accuracy check: raw Whisper output for every .wav in a folder, as TSV
            //   Fluent --transcribe-dir /path/to/wavs ar|auto
            runTranscriptionDirectory(arguments[index + 1], language: arguments[index + 2])
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
