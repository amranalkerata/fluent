import SwiftUI
import SwiftData
import AVFoundation
#if DEBUG
import WhisperKit
import CoreML
#endif

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
        if let index = arguments.firstIndex(of: "--incremental-selftest"), index + 2 < arguments.count {
            // Transcription while recording, fed in 100 ms chunks like the microphone tap, then
            // compared with the full-file path (one file, or every .wav/.m4a in a folder):
            //   Fluent --incremental-selftest /path/to/audio.m4a ar|auto [--fast] [--live] [--min-segment 2.5]
            runIncrementalSelfTest(arguments[index + 1], language: arguments[index + 2], arguments: arguments)
        }
        if arguments.contains("--streaming-selftest") {
            // Streaming live typing simulated in real time: partial passes on the open segment,
            // commit policies compared offline on the same hypotheses (posts no keyboard events):
            //   Fluent --streaming-selftest clip.wav|dir [...] [--interval 0.5|0] [--refs refs.json]
            //          [--max-partial-ms 1500] [--min-partial 1.0] [--max-segment 25] [--relax-after 8] [--language en]
            runStreamingSelfTest(arguments)
        }
        if arguments.contains("--whisper-timing-selftest") {
            // Where a Whisper pass spends its time (encoder vs decoder loop) under different
            // compute units and decoding options, on every .wav of a folder:
            //   Fluent --whisper-timing-selftest dir [--decoder ane|gpu] [--encoder ane|gpu] [--no-timestamps]
            runWhisperTimingSelfTest(arguments)
        }
        if arguments.contains("--detect-prefix-selftest") {
            // Whisper language detection at the in-recording trigger points: for every clip and
            // speech threshold, detects on the audio up to where the segmenter has heard that much
            // speech, and says what the recording would do (settle on Audar, hold, abandon):
            //   Fluent --detect-prefix-selftest clip.wav|dir [...] [--speech 1,1.5,2,3]
            runDetectPrefixSelfTest(arguments)
        }
        if arguments.contains("--live-typing-selftest") {
            // Live typing rules without posting any keyboard event: chunking, spacing between
            // typed segments, and the session's hold-until-settled ordering:
            //   Fluent --live-typing-selftest   (exit code 1 if any case fails)
            runLiveTypingSelfTest()
        }
        if arguments.contains("--cleanup-selftest") {
            // Bracket cleanup + speech cleanup + punctuation through TranscriptionService.postProcess:
            //   Fluent --cleanup-selftest   (exit code 1 if any case fails)
            runCleanupSelfTest()
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

    /// Feeds each file's 16 kHz samples into an `IncrementalTranscriber` in 100 ms chunks at
    /// real-time pace (`--fast`: as fast as possible, latency then meaningless), "stops", and
    /// prints the stop-to-text latency, segment count and text; then runs the full-file path
    /// on the same file for comparison. TSV on stdout:
    ///   mode  file  ms  segments  segment_ms  reason  text
    /// Files starting with "00_" are warm-up. Formatting forced on; settings restored on exit.
    private static func runIncrementalSelfTest(_ path: String, language: String, arguments: [String]) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[incremental] \(line)\n".utf8)) }
            let settingsService = SettingsService.shared
            let originalSettings = settingsService.settings
            let fast = arguments.contains("--fast")
            // As a live-typed recording: partial passes, words streamed (see the "live" rows).
            let live = arguments.contains("--live")
            var config = SpeechSegmenter.Config()
            if let index = arguments.firstIndex(of: "--min-segment"), index + 1 < arguments.count,
               let value = Double(arguments[index + 1]) {
                config.minSegmentSeconds = value
            }
            if let index = arguments.firstIndex(of: "--pause"), index + 1 < arguments.count,
               let value = Double(arguments[index + 1]) {
                config.pauseSeconds = value
            }
            if let index = arguments.firstIndex(of: "--relax-after"), index + 1 < arguments.count,
               let value = Double(arguments[index + 1]) {
                config.relaxAfterSeconds = value
            }
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
                try await whisper.loadModel()
                try await PunctuationModelManager.shared.loadModel()
                try await audar.loadModel()
                log("engines loaded, audar usable=\(audar.isUsable) fast=\(fast) live=\(live) min_segment=\(config.minSegmentSeconds) pause=\(config.pauseSeconds) relax_after=\(config.relaxAfterSeconds)")

                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                let urls: [URL] = isDirectory.boolValue
                    ? try FileManager.default.contentsOfDirectory(atPath: path)
                        .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") }.sorted()
                        .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
                    : [URL(fileURLWithPath: path)]

                let clean = { (text: String) in text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                let ms = { (value: Double) in String(format: "%.0f", value) }
                print(["mode", "file", "ms", "segments", "segment_ms", "reason", "text"].joined(separator: "\t"))
                for url in urls {
                    let file = url.lastPathComponent
                    let samples = try await AudioConverter.convertToWhisperSamples(url: url)
                    let seconds = Double(samples.count) / AudioConverter.targetSampleRate

                    // Incremental: the file at its own rate and channel count, in 4096-frame
                    // buffers (~90 ms) through the tap's StreamingResampler, at recording pace.
                    var continuation: AsyncStream<[Float]>.Continuation!
                    let stream = AsyncStream<[Float]> { continuation = $0 }
                    guard let session = IncrementalTranscriber.makeIfApplicable(
                        stream: stream, config: config, streaming: live ? StreamingConfig() : nil
                    ) else {
                        log("\(file): incremental path not applicable (Audar unusable or language not ar/auto)")
                        continue
                    }
                    await session.start()
                    // What live typing would receive: each released event, and whether it
                    // came before the "stop" (posts no keyboard events).
                    let liveEvents = session.liveEvents
                    let liveCollector = Task { () -> [(event: LiveEvent, at: UInt64)] in
                        var released: [(event: LiveEvent, at: UInt64)] = []
                        for await event in liveEvents { released.append((event, LatencyLog.now())) }
                        return released
                    }
                    let format = try AVAudioFile(forReading: url).processingFormat
                    let streamed = try await feed(url, into: continuation, fast: fast)
                    continuation.finish()
                    let stopAt = LatencyLog.now()
                    let service = TranscriptionService()
                    let text = try await service.transcribe(incremental: session, audioURL: url, recordedDuration: seconds)
                    let stopMs = LatencyLog.ms(since: stopAt)
                    let t = service.lastTimings
                    // Stream vs file converter (both AVAudioConverter): sample count and SNR.
                    let common = min(streamed.count, samples.count)
                    var signal: Double = 0, noise: Double = 0
                    for i in 0..<common {
                        signal += Double(samples[i] * samples[i])
                        let d = Double(samples[i] - streamed[i]); noise += d * d
                    }
                    log("\(file): \(format.sampleRate) Hz x\(format.channelCount) -> stream \(streamed.count) vs file \(samples.count) samples, SNR \(String(format: "%.1f", 10 * log10(signal / max(noise, 1e-20)))) dB")
                    print(["incremental", file, ms(stopMs), t.segments.map(String.init) ?? "-",
                           t.segmentMs.map(ms).joined(separator: ","), service.lastRouteReason ?? "", clean(text)]
                        .joined(separator: "\t"))
                    fflush(stdout)
                    let released = await liveCollector.value
                    let liveTyped = await typeOffline(released.map(\.event))
                    log("\(file): live stream released \(released.count) events, \(released.filter { $0.at < stopAt }.count) before stop")
                    print(["live", file, "-", String(released.count), "-", "", clean(liveTyped)]
                        .joined(separator: "\t"))
                    fflush(stdout)
                    log("\(file) \(String(format: "%.1f", seconds))s: stop→text \(ms(stopMs))ms (last segments \(ms(t.asrMs))ms, format \(ms(t.formattingMs))ms), segments \(t.segments ?? 0) [\(zip(t.segmentSeconds, t.segmentMs).map { String(format: "%.1fs:%.0f", $0, $1) }.joined(separator: " "))]")

                    // Full-file path on the same audio, for comparison.
                    let fullService = TranscriptionService()
                    let fullStart = LatencyLog.now()
                    let fullText = try await fullService.transcribe(audioURL: url)
                    let fullMs = LatencyLog.ms(since: fullStart)
                    print(["fullfile", file, ms(fullMs), "-", "-", fullService.lastRouteReason ?? "", clean(fullText)]
                        .joined(separator: "\t"))
                    fflush(stdout)
                    log("\(file): full-file \(ms(fullMs))ms")
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

    /// Every Audar run of a session, in completion order (filled from the session's actor).
    private final class HypothesisLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [IncrementalTranscriber.HypothesisRecord] = []
        func append(_ item: IncrementalTranscriber.HypothesisRecord) {
            lock.lock(); items.append(item); lock.unlock()
        }
        var records: [IncrementalTranscriber.HypothesisRecord] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    /// Totals of one commit policy over several clips.
    private struct PolicyTotals {
        var latencies: [Double] = []
        var committedBeforeFinal = 0
        var disagreeing = 0
        var editsVsFinal = 0
        var finalWords = 0
        var editsVsRef = 0
        var finalEditsVsRef = 0
        var refWords = 0
        var stopMs: [Double] = []
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }

    /// Feeds each clip at recording pace into a session with partial passes on the open
    /// segment (`--interval`, 0 = none, today's behaviour), records every Audar run with its
    /// time and audio window, then replays the commit policies (LA2, HOLD-1, HOLD-2) on the
    /// same hypotheses, plus FINAL (every word typed when its segment's final pass ends, as
    /// before streaming). Per word: commit time minus the end of the first audio window it
    /// appeared in (with `--interval 0` that window is the whole segment, so FINAL there
    /// understates latency: compare FINAL rows of a streaming run instead). TSV on stdout, one row per clip and policy, then totals. Files starting with
    /// "00_" are warm-up. Language Arabic, formatting on; settings restored on exit.
    private static func runWhisperTimingSelfTest(_ arguments: [String]) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[whisper-timing] \(line)\n".utf8)) }
            let option = { (name: String) -> String? in
                guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            let units = { (name: String?) -> MLComputeUnits in name == "gpu" ? .cpuAndGPU : .cpuAndNeuralEngine }
            let dir = arguments[arguments.firstIndex(of: "--whisper-timing-selftest")! + 1]
            let noTimestamps = arguments.contains("--no-timestamps")
            do {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let folder = appSupport.appendingPathComponent("Fluent/WhisperKitModels/openai_whisper-large-v3-v20240930_626MB")
                let kit = try await WhisperKit(modelFolder: folder.path,
                                               computeOptions: ModelComputeOptions(audioEncoderCompute: units(option("--encoder")),
                                                                                   textDecoderCompute: units(option("--decoder"))),
                                               verbose: false, prewarm: true)
                let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 0,
                                              sampleLength: 224, usePrefillPrompt: true, usePrefillCache: true,
                                              detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: noTimestamps,
                                              clipTimestamps: [0], suppressBlank: true, supressTokens: nil,
                                              compressionRatioThreshold: 2.4, logProbThreshold: -1.0,
                                              firstTokenLogProbThreshold: nil, noSpeechThreshold: 0.6)
                let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
                print(["file", "total_ms", "encoding_ms", "decoding_loop_ms", "tokens", "text"].joined(separator: "\t"))
                for file in files {
                    let samples = try await AudioConverter.convertToWhisperSamples(url: URL(fileURLWithPath: dir).appendingPathComponent(file))
                    let start = LatencyLog.now()
                    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                    let ms = LatencyLog.ms(since: start)
                    let timings = results.first?.timings
                    let tokens = results.flatMap { $0.segments }.reduce(0) { $0 + $1.tokens.count }
                    print([file, String(format: "%.0f", ms), String(format: "%.0f", (timings?.encoding ?? 0) * 1000),
                           String(format: "%.0f", (timings?.decodingLoop ?? 0) * 1000), "\(tokens)",
                           results.map(\.text).joined(separator: " ")].joined(separator: "\t"))
                }
            } catch {
                log("error: \(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }

    private static func runDetectPrefixSelfTest(_ arguments: [String]) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[detect] \(line)\n".utf8)) }
            let option = { (name: String) -> String? in
                guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            var paths: [String] = []
            if let flag = arguments.firstIndex(of: "--detect-prefix-selftest") {
                var index = flag + 1
                while index < arguments.count, !arguments[index].hasPrefix("--") { paths.append(arguments[index]); index += 1 }
            }
            let thresholds = (option("--speech") ?? "1,1.5,2,3").split(separator: ",").compactMap { Double($0) }
            do {
                let whisper = ModelManager.shared
                guard whisper.isModelDownloaded else { throw TranscriptionError.modelNotReady }
                try await whisper.loadModel()
                var urls: [URL] = []
                for path in paths {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    if isDirectory.boolValue {
                        urls += try FileManager.default.contentsOfDirectory(atPath: path)
                            .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") }.sorted()
                            .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
                    } else {
                        urls.append(URL(fileURLWithPath: path))
                    }
                }
                var outcomes: [Double: [String: Int]] = [:]
                var times: [Double: [Double]] = [:]
                var warmed = false
                print(["file", "speech_s", "wall_s", "lang", "conf", "ms", "outcome"].joined(separator: "\t"))
                for url in urls {
                    let samples = try await AudioConverter.convertToWhisperSamples(url: url)
                    if !warmed {
                        _ = try? await whisper.detectLanguage(samples: Array(samples.prefix(32_000)))
                        warmed = true
                    }
                    // Where the segmenter has heard each threshold of speech, fed in 100 ms steps.
                    var segmenter = SpeechSegmenter()
                    var heard: [Float] = []
                    var cut: [Double: Int] = [:]
                    var fed = 0
                    while fed < samples.count, cut.count < thresholds.count {
                        let next = min(fed + 1_600, samples.count)
                        heard.append(contentsOf: samples[fed..<next])
                        fed = next
                        _ = segmenter.advance(heard)
                        for threshold in thresholds where cut[threshold] == nil && segmenter.totalSpeechSeconds >= threshold {
                            cut[threshold] = fed
                        }
                    }
                    for threshold in thresholds {
                        guard let end = cut[threshold] else {
                            print([url.lastPathComponent, "\(threshold)", "-", "-", "-", "-", "not_reached"].joined(separator: "\t"))
                            continue
                        }
                        let start = LatencyLog.now()
                        let result = try await whisper.detectLanguage(samples: Array(samples.prefix(min(end, 30 * 16_000))))
                        let ms = LatencyLog.ms(since: start)
                        // The in-recording rule of IncrementalTranscriber.recordDetection (first run).
                        let arabic = TranscriptionService.isArabicLike(result.language)
                        let outcome = !arabic && result.confidence >= IncrementalTranscriber.otherLanguageConfidence
                            ? "abandon"
                            : (arabic && result.confidence >= TranscriptionService.minimumDetectionConfidence ? "settle" : "hold")
                        outcomes[threshold, default: [:]][outcome, default: 0] += 1
                        times[threshold, default: []].append(ms)
                        print([url.lastPathComponent, "\(threshold)", String(format: "%.2f", Double(end) / 16_000),
                               result.language, String(format: "%.2f", result.confidence), String(format: "%.0f", ms),
                               outcome].joined(separator: "\t"))
                    }
                }
                for threshold in thresholds {
                    let sorted = (times[threshold] ?? []).sorted()
                    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                    log("speech \(threshold)s: \(outcomes[threshold] ?? [:]) median \(String(format: "%.0f", median)) ms")
                }
            } catch {
                log("error: \(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }

    private static func runStreamingSelfTest(_ arguments: [String]) -> Never {
        Task { @MainActor in
            let log = { (line: String) in FileHandle.standardError.write(Data("[streaming] \(line)\n".utf8)) }
            let settingsService = SettingsService.shared
            let originalSettings = settingsService.settings
            let option = { (name: String) -> String? in
                guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            var paths: [String] = []
            if let flag = arguments.firstIndex(of: "--streaming-selftest") {
                var index = flag + 1
                while index < arguments.count, !arguments[index].hasPrefix("--") { paths.append(arguments[index]); index += 1 }
            }
            let interval = option("--interval").flatMap(Double.init) ?? 0.5
            var streaming = StreamingConfig()
            streaming.partialInterval = interval
            if let value = option("--max-partial-ms").flatMap(Double.init) { streaming.maxPartialMs = value }
            if let value = option("--min-partial").flatMap(Double.init) { streaming.minPartialSeconds = value }
            var segmenterConfig = SpeechSegmenter.Config()
            if let value = option("--max-segment").flatMap(Double.init) { segmenterConfig.maxSegmentSeconds = value }
            if let value = option("--relax-after").flatMap(Double.init) { segmenterConfig.relaxAfterSeconds = value }
            var refs: [String: String] = [:]
            if let path = option("--refs"), let data = FileManager.default.contents(atPath: path),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in entries {
                    if let file = entry["file"] as? String, let ref = entry["ref"] as? String { refs[file] = ref }
                }
            }
            let policies: [(name: String, policy: StreamingCommitter.Policy?)] = interval > 0
                ? [("LA2", .localAgreement), ("HOLD1", .hold(1)), ("HOLD2", .hold(2)), ("FINAL", nil)]
                : [("FINAL", nil)]
            var totals: [String: PolicyTotals] = [:]
            var partialMs: [Double] = []
            var finalMs: [Double] = []

            do {
                // --language en|… streams that language through Whisper; Arabic by default.
                settingsService.settings.language = option("--language").flatMap(AppSettings.TranscriptionLanguage.init(rawValue:)) ?? .arabic
                settingsService.settings.formatTextEnabled = true
                settingsService.settings.audarEnabled = true
                if !settingsService.settings.audarLicenseAccepted {
                    settingsService.settings.audarLicenseAcceptedAt = Date()
                }
                let whisper = ModelManager.shared
                let audar = AudarModelManager.shared
                guard audar.isModelDownloaded else { throw TranscriptionError.modelNotReady }
                if whisper.isModelDownloaded { try await whisper.loadModel() }
                try await PunctuationModelManager.shared.loadModel()
                try await audar.loadModel()
                log("engines loaded, audar usable=\(audar.isUsable) interval=\(interval) min_partial=\(streaming.minPartialSeconds) max_partial_ms=\(streaming.maxPartialMs) max_segment=\(segmenterConfig.maxSegmentSeconds) relax_after=\(segmenterConfig.relaxAfterSeconds) refs=\(refs.count)")

                var urls: [URL] = []
                for path in paths {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    if isDirectory.boolValue {
                        urls += try FileManager.default.contentsOfDirectory(atPath: path)
                            .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") }.sorted()
                            .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
                    } else {
                        urls.append(URL(fileURLWithPath: path))
                    }
                }

                let filter = TranscriptionService()
                let cleanup = settingsService.settings.cleanupEnabled
                let words = { (text: String) in IncrementalTranscriber.hypothesisWords(text, filter: filter, cleanup: cleanup) }
                let f0 = { (value: Double) in value.isNaN ? "-" : String(format: "%.0f", value) }
                let f2 = { (value: Double) in value.isNaN ? "-" : String(format: "%.2f", value) }
                let pct = { (part: Int, whole: Int) in whole == 0 ? "-" : String(format: "%.1f", 100 * Double(part) / Double(whole)) }
                print(["policy", "file", "words", "lat_med_s", "lat_p90_s", "disagree_pct", "wer_vs_final_pct", "wer_vs_ref_pct",
                       "final_wer_vs_ref_pct", "partials", "partial_med_ms", "partial_p90_ms", "partial_max_ms",
                       "final_med_ms", "final_max_ms", "stop_to_last_ms"].joined(separator: "\t"))

                for url in urls {
                    let file = url.lastPathComponent
                    let samples = try await AudioConverter.convertToWhisperSamples(url: url)
                    let seconds = Double(samples.count) / AudioConverter.targetSampleRate
                    var continuation: AsyncStream<[Float]>.Continuation!
                    let stream = AsyncStream<[Float]> { continuation = $0 }
                    guard let session = IncrementalTranscriber.makeIfApplicable(
                        stream: stream, config: segmenterConfig, streaming: interval > 0 ? streaming : nil
                    ) else {
                        log("\(file): incremental path not applicable")
                        continue
                    }
                    let hypotheses = HypothesisLog()
                    await session.observeHypotheses { hypotheses.append($0) }
                    await session.start()
                    let feedStart = LatencyLog.now()
                    _ = try await feed(url, into: continuation, fast: false)
                    continuation.finish()
                    let stopAt = LatencyLog.now()
                    let outcome = await session.finish(recordedDuration: seconds)
                    let finishMs = LatencyLog.ms(since: stopAt)
                    if case .fallback(let reason) = outcome { log("\(file): fallback (\(reason))") }

                    let records = hypotheses.records
                    let at = { (time: UInt64) in Double(time &- feedStart) / 1_000_000_000 }
                    let segments = Set(records.map(\.segment)).sorted()
                    let clipPartialMs = records.filter { !$0.isFinal }.map(\.ms)
                    let clipFinalMs = records.filter(\.isFinal).map(\.ms)
                    let lastFinish = records.filter(\.isFinal).map(\.finishedAt).max() ?? stopAt
                    let stopToLast = lastFinish > stopAt ? Double(lastFinish - stopAt) / 1_000_000 : 0
                    log("\(file) \(String(format: "%.1f", seconds))s: finish \(f0(finishMs))ms, segments \(segments.count): " + segments.map { index -> String in
                        let runs = records.filter { $0.segment == index }
                        let final = runs.first(where: \.isFinal)
                        return "#\(index) \(runs.count - (final == nil ? 0 : 1))p final \(final.map { f0($0.ms) } ?? "-")ms partial max \(f0(runs.filter { !$0.isFinal }.map(\.ms).max() ?? .nan))"
                    }.joined(separator: " | "))
                    let warmup = file.hasPrefix("00_")
                    if !warmup { partialMs += clipPartialMs; finalMs += clipFinalMs }

                    for (name, policy) in policies {
                        var latencies: [Double] = []
                        var typedAll: [String] = []
                        var finalAll: [String] = []
                        var committedBeforeFinal = 0
                        var disagreeing = 0
                        for index in segments {
                            let runs = records.filter { $0.segment == index }.sorted { $0.finishedAt < $1.finishedAt }
                            guard let final = runs.first(where: \.isFinal) else { continue }
                            var committer = StreamingCommitter(policy: policy ?? .localAgreement)
                            var commitTimes: [Double] = []
                            var committingWindow: [Double] = []
                            if policy != nil {
                                for run in runs where !run.isFinal && run.segmentOpen {
                                    let hypothesis = words(run.text)
                                    let update = committer.update(hypothesis.words, acceptable: hypothesis.acceptable)
                                    commitTimes += Array(repeating: at(run.finishedAt), count: update.words.count)
                                    committingWindow += Array(repeating: run.windowEnd, count: update.words.count)
                                }
                            }
                            let early = committer.committed
                            let finalHypothesis = words(final.text)
                            let finalWords = finalHypothesis.acceptable ? finalHypothesis.words : []
                            let rest = finalHypothesis.acceptable ? committer.finish(finalWords) : []
                            commitTimes += Array(repeating: at(final.finishedAt), count: rest.count)
                            committingWindow += Array(repeating: final.windowEnd, count: rest.count)
                            let typed = committer.committed
                            committedBeforeFinal += early.count
                            disagreeing += StreamingText.editDistance(early, Array(finalWords[..<StreamingText.alignEnd(early, in: finalWords)]))

                            // End of a word = end of the first audio window it appeared in.
                            var appeared = [Double?](repeating: nil, count: typed.count)
                            for run in runs {
                                let matched = StreamingText.matches(typed, words(run.text).words)
                                for (i, match) in matched.enumerated() where appeared[i] == nil && match != nil {
                                    appeared[i] = run.windowEnd
                                }
                            }
                            for i in typed.indices {
                                latencies.append(commitTimes[i] - (appeared[i] ?? committingWindow[i]))
                            }
                            typedAll += typed
                            finalAll += finalWords
                        }
                        let refWords = refs[file].map(StreamingText.words) ?? []
                        let editsVsFinal = StreamingText.editDistance(typedAll, finalAll)
                        let editsVsRef = refWords.isEmpty ? 0 : StreamingText.editDistance(typedAll, refWords)
                        let finalEditsVsRef = refWords.isEmpty ? 0 : StreamingText.editDistance(finalAll, refWords)
                        print([name, file, String(typedAll.count), f2(percentile(latencies, 0.5)), f2(percentile(latencies, 0.9)),
                               pct(disagreeing, committedBeforeFinal), pct(editsVsFinal, finalAll.count),
                               refWords.isEmpty ? "-" : pct(editsVsRef, refWords.count),
                               refWords.isEmpty ? "-" : pct(finalEditsVsRef, refWords.count),
                               String(clipPartialMs.count), f0(percentile(clipPartialMs, 0.5)), f0(percentile(clipPartialMs, 0.9)),
                               f0(clipPartialMs.max() ?? .nan), f0(percentile(clipFinalMs, 0.5)), f0(clipFinalMs.max() ?? .nan),
                               f0(stopToLast)].joined(separator: "\t"))
                        fflush(stdout)
                        if name == policies.first?.name {
                            log("\(file) \(name) typed: \(typedAll.joined(separator: " "))")
                        }
                        guard !warmup else { continue }
                        var total = totals[name, default: PolicyTotals()]
                        total.latencies += latencies
                        total.committedBeforeFinal += committedBeforeFinal
                        total.disagreeing += disagreeing
                        total.editsVsFinal += editsVsFinal
                        total.finalWords += finalAll.count
                        if !refWords.isEmpty {
                            total.editsVsRef += editsVsRef
                            total.finalEditsVsRef += finalEditsVsRef
                            total.refWords += refWords.count
                        }
                        total.stopMs.append(stopToLast)
                        totals[name] = total
                    }
                }

                for (name, _) in policies {
                    guard let total = totals[name] else { continue }
                    print([name, "TOTAL", String(total.latencies.count), f2(percentile(total.latencies, 0.5)), f2(percentile(total.latencies, 0.9)),
                           pct(total.disagreeing, total.committedBeforeFinal), pct(total.editsVsFinal, total.finalWords),
                           pct(total.editsVsRef, total.refWords), pct(total.finalEditsVsRef, total.refWords),
                           String(partialMs.count), f0(percentile(partialMs, 0.5)), f0(percentile(partialMs, 0.9)),
                           f0(partialMs.max() ?? .nan), f0(percentile(finalMs, 0.5)), f0(finalMs.max() ?? .nan),
                           f0(percentile(total.stopMs, 0.5)) + "/" + f0(total.stopMs.max() ?? .nan)].joined(separator: "\t"))
                }
                log("committed before final: " + policies.map { "\($0.name) \(totals[$0.name]?.committedBeforeFinal ?? 0)/\(totals[$0.name]?.latencies.count ?? 0)" }.joined(separator: ", "))
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

    /// Feeds `url` into `continuation` the way the microphone tap does: the file at its own
    /// rate and channel count, in 4096-frame buffers (~90 ms) through the tap's
    /// StreamingResampler, at recording pace (`fast`: as fast as possible). Does not finish
    /// the stream. Returns the samples sent.
    private static func feed(_ url: URL, into continuation: AsyncStream<[Float]>.Continuation, fast: Bool) async throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let resampler = StreamingResampler()
        var streamed: [Float] = []
        var fedSeconds = 0.0
        let feedStart = LatencyLog.now()
        while audioFile.framePosition < audioFile.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
            try audioFile.read(into: buffer, frameCount: 4096)
            guard buffer.frameLength > 0 else { break }
            if let out = resampler.process(buffer), !out.isEmpty {
                continuation.yield(out)
                streamed += out
            }
            fedSeconds += Double(buffer.frameLength) / format.sampleRate
            if fast {
                await Task.yield()
            } else {
                let due = feedStart + UInt64(fedSeconds * 1_000_000_000)
                let now = LatencyLog.now()
                if due > now { try await Task.sleep(nanoseconds: due - now) }
            }
        }
        let tail = resampler.flush()
        if !tail.isEmpty { continuation.yield(tail); streamed += tail }
        return streamed
    }

    /// The text `LiveTypingRun` would type for `events` (same steps and punctuation model,
    /// no keyboard events).
    @MainActor
    private static func typeOffline(_ events: [LiveEvent]) async -> String {
        let formatting = SettingsService.shared.settings.formatTextEnabled
        var segment = StreamingSegmentTyping()
        var text = ""
        for event in events {
            let new: [String], lookahead: [String], isEnd: Bool
            switch event {
            case .words(let words, let rest):
                new = LiveTypingRun.prepare(words, formatting: formatting)
                lookahead = LiveTypingRun.prepare(rest, formatting: formatting)
                isEnd = false
                if new.isEmpty { continue }
            case .segmentEnd(let words):
                new = LiveTypingRun.prepare(words, formatting: formatting)
                lookahead = []
                isEnd = true
                if new.isEmpty && segment.typed.isEmpty { continue }
            }
            let formatted = formatting ? await LiveTypingRun.punctuate(segment.modelInput(new: new, lookahead: lookahead)) : nil
            text += LiveTyping.part(after: text, segment.step(new: new, lookahead: lookahead, formatted: formatted, isEnd: isEnd))
            if isEnd { segment = StreamingSegmentTyping() }
        }
        return text
    }

    /// Input → expected final text. Expected text is compared word by word, case-sensitive,
    /// ignoring only punctuation at word edges (the punctuation model's choice), so "C.R.M."
    /// still fails against "CRM". An empty expectation means the utterance is dropped.
    private static let cleanupCases: [(input: String, expected: String)] = [
        // Bracketed English words inside Arabic speech are speech; sound tags are not
        ("شيلوا إن ال [CRM] مسوي لأمه [block] لا لا لا تبينوا أبدا",
         "شيلوا إن ال CRM مسوي لأمه block لا تبينوا أبدا"),
        ("[CRM]", "CRM"),
        // A live-typed segment can start and end with a bracketed English word.
        ("[CRM] جاهز قبل ال [deadline]", "CRM جاهز قبل ال deadline"),
        ("[let] [me] [know]", "Let me know"),
        ("[Music] [Applause]", ""),
        ("[Light music]", ""),
        ("ابغى أرسل الإيميل لل [team] بكرة", "ابغى أرسل الإيميل لل team بكرة"),
        ("خلص ال iPhone الجديد وصل", "خلص ال iPhone الجديد وصل"),
        ("[Music]", ""),
        ("[BLANK_AUDIO]", ""),
        ("(door closes)", ""),
        ("(applause) شكرا", "شكرا"),
        ("[ضحك] تمام", "تمام"),
        ("the plan [Music] works", "The plan works"),
        // Repeated words
        ("يعني ما ما ما يطلع أبدا", "يعني ما يطلع أبدا"),
        ("um so I I think the the plan works", "So I think the plan works"),
        ("the the", "The"),
        // Repeated phrases
        ("انا بدي انا بدي اقلك شي", "انا بدي اقلك شي"),
        ("قلت له قلت له لا تتأخر", "قلت له لا تتأخر"),
        ("I think I think it works", "I think it works"),
        // Legitimate reduplication stays
        ("شوي شوي", "شوي شوي"),
        ("خطوة خطوة نوصل", "خطوة خطوة نوصل"),
        ("خذها واحد واحد", "خذها واحد واحد"),
        ("very very good", "Very very good"),
        ("no no no that's wrong", "No no no that's wrong"),
        ("10 10", "10 10"),
        ("رقمي خمسة خمسة صفر", "رقمي خمسة خمسة صفر"),
        // Hesitation sounds go, words meaning "yes" stay
        ("اممم خلينا نشوف", "خلينا نشوف"),
        ("إمم ما أدري", "ما أدري"),
        ("ممم طيب", "طيب"),
        ("uh I mean we can start", "I mean we can start"),
        ("hmm let me check", "Let me check"),
        ("erm well okay", "Well okay"),
        ("اه تمام", "اه تمام"),
        ("آه صح", "آه صح"),
        ("إيه والله", "إيه والله"),
        ("اممم", "اممم"),   // never drops the last word
        // A run of 4+ identical letters must not drop the whole dictation
        ("ههههه والله صح كلامك", "ههههه والله صح كلامك"),
        ("مممممم خلينا نبلش بالاجتماع", "خلينا نبلش بالاجتماع"),
        ("??????", ""),
        // English-only text keeps today's behaviour
        ("we moved the CRM data to the new server", "We moved the CRM data to the new server"),
    ]

    /// Runs `cleanupCases` through TranscriptionService.postProcess with formatting and cleanup
    /// forced on, prints PASS/FAIL per case and exits 1 if any case fails. Settings restored.
    private static func runCleanupSelfTest() -> Never {
        Task { @MainActor in
            let settingsService = SettingsService.shared
            let originalSettings = settingsService.settings
            settingsService.settings.formatTextEnabled = true
            settingsService.settings.cleanupEnabled = true
            try? await PunctuationModelManager.shared.loadModel()
            FileHandle.standardError.write(Data("[cleanup] punctuation model: \(PunctuationModelManager.shared.state)\n".utf8))

            let words = { (text: String) -> [String] in
                text.split(whereSeparator: \.isWhitespace)
                    .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
                    .filter { !$0.isEmpty }
            }
            let service = TranscriptionService()
            var failures = 0
            for (number, testCase) in cleanupCases.enumerated() {
                let output = await service.postProcess(testCase.input)
                let pass = words(output) == words(testCase.expected)
                if !pass { failures += 1 }
                print("\(pass ? "PASS" : "FAIL")\t\(number + 1)\t\(testCase.input)\t→\t\(output.replacingOccurrences(of: "\n", with: " ⏎ "))\(pass ? "" : "\t(expected: \(testCase.expected))")")
            }

            // Cost of the text cleanup itself (no punctuation model) on the longest case.
            let longest = cleanupCases.map(\.input).max(by: { $0.count < $1.count }) ?? ""
            let runs = 2000
            let start = LatencyLog.now()
            for _ in 0..<runs {
                _ = SpeechCleanup.clean(SpeechCleanup.unwrapBrackets(longest, nonSpeechPhrases: TranscriptionService.hallucinationPhrases))
            }
            let microseconds = LatencyLog.ms(since: start) * 1000 / Double(runs)
            print("cleanup cost: \(String(format: "%.1f", microseconds)) µs per utterance (\(longest.split(separator: " ").count) words)")
            print("\(cleanupCases.count - failures)/\(cleanupCases.count) passed")

            settingsService.settings = originalSettings
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Checks the pure parts of live typing (LiveTyping chunking/joining, LiveSegmentGate,
    /// streaming commit policies, reconciliation with the final text, deferred punctuation),
    /// prints PASS/FAIL per case and exits 1 if any case fails. Posts no keyboard events.
    private static func runLiveTypingSelfTest() -> Never {
        var failures = 0
        var total = 0
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL")\t\(name)\(pass ? "" : "\t\(detail())")")
        }
        let describe = { (pieces: [LiveTyping.Piece]) -> String in
            pieces.map { piece -> String in
                switch piece {
                case .text(let text): return "[\(text)](\(text.utf16.count))"
                case .newline: return "⏎"
                }
            }.joined(separator: " ")
        }

        // (a) Chunking: ≤ 20 UTF-16 units per chunk (a single longer grapheme stands alone),
        // no Character split, chunks + line breaks give the input back.
        let chunkCases: [(name: String, input: String)] = [
            ("arabic with tashkeel", "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ، هَذَا نَصٌّ طَوِيلٌ لِلتَّجْرِبَةِ وَالتَّقْطِيعِ"),
            ("emoji (ZWJ family, flag, skin tone)", "👨‍👩‍👧‍👦👨‍👩‍👧‍👦 العائلة 🇸🇦🇸🇦🇸🇦 علم 👍🏽👍🏽👍🏽👍🏽 تمام 😀"),
            ("mixed Arabic and Latin", "ابغى أرسل الإيميل لل team بكرة about the CRM migration plan قبل الاجتماع"),
            ("lists and line breaks", "١. الأول\n٢. الثاني\r\n\nالثالث في سطر طويل جدا جدا جدا\n"),
            ("grapheme longer than 20 units", "قبل a" + String(repeating: "\u{0301}", count: 25) + " بعد"),
            ("exactly 20 units", String(repeating: "ب", count: 20)),
            ("21 units", String(repeating: "ب", count: 21)),
            ("empty", ""),
        ]
        for testCase in chunkCases {
            let pieces = LiveTyping.pieces(for: testCase.input)
            var rebuilt = ""
            var characterTotal = 0
            var sizesOK = true
            var newlines = 0
            for piece in pieces {
                switch piece {
                case .text(let chunk):
                    rebuilt += chunk
                    characterTotal += chunk.count
                    if chunk.utf16.count > LiveTyping.maxChunkUTF16 && chunk.count != 1 { sizesOK = false }
                    if chunk.isEmpty || chunk.contains(where: \.isNewline) { sizesOK = false }
                case .newline:
                    rebuilt += "\n"
                    characterTotal += 1
                    newlines += 1
                }
            }
            let expected = testCase.input.replacingOccurrences(of: "\r\n", with: "\n")
            let expectedNewlines = testCase.input.filter(\.isNewline).count
            // A split grapheme would count as two Characters in the chunks but one in the input.
            let noSplit = characterTotal == testCase.input.count
            check("chunk: \(testCase.name)",
                  sizesOK && noSplit && rebuilt == expected && newlines == expectedNewlines,
                  describe(pieces))
        }
        check("chunk: exactly 20 units is one chunk", LiveTyping.pieces(for: String(repeating: "ب", count: 20)).count == 1)
        check("chunk: 21 units is two chunks", LiveTyping.pieces(for: String(repeating: "ب", count: 21)).count == 2)
        check("chunk: newline is a Return press",
              LiveTyping.pieces(for: "أ\nب") == [.text("أ"), .newline, .text("ب")],
              describe(LiveTyping.pieces(for: "أ\nب")))

        // (b) Spacing: no space before the first typed segment, one space between segments,
        // none when the seam already has whitespace or a line break.
        let separatorCases: [(previous: String, next: String, expected: String)] = [
            ("", "مرحبا", ""),
            ("مرحبا.", "كيف حالك؟", " "),
            ("Hello.", "World", " "),
            ("السطر الأول\n", "الثاني", ""),
            ("كلمة ", "أخرى", ""),
            ("قائمة:", "\n١. أول", ""),
        ]
        for testCase in separatorCases {
            let separator = LiveTyping.separator(after: testCase.previous, before: testCase.next)
            check("separator: \(testCase.previous.debugDescription) + \(testCase.next.debugDescription)",
                  separator == testCase.expected, "got \(separator.debugDescription)")
        }
        let joinCases: [(parts: [String], expected: String)] = [
            (["مرحبا.", "كيف حالك؟", "تمام الحمد لله."], "مرحبا. كيف حالك؟ تمام الحمد لله."),
            (["١. الأول\n", "٢. الثاني"], "١. الأول\n٢. الثاني"),
            (["We moved the CRM.", "خلص ال iPhone وصل."], "We moved the CRM. خلص ال iPhone وصل."),
            (["وحيد"], "وحيد"),
            ([], ""),
        ]
        for testCase in joinCases {
            let joined = LiveTyping.join(testCase.parts)
            check("join: \(testCase.parts.count) parts", joined == testCase.expected, joined.debugDescription)
        }
        // Typed parts then set-aside parts, accumulated as LiveTypingRun does, equal the join.
        let parts = ["أول جملة.", "ثاني جملة", "ثالث\n", "رابع."]
        var full = ""
        var pending = ""
        for (index, part) in parts.enumerated() {
            let piece = LiveTyping.separator(after: full, before: part) + part
            full += piece
            if index >= 2 { pending += piece }
        }
        check("join: typed + pending == full text", full == LiveTyping.join(parts) && full == "أول جملة. ثاني جملة ثالث\nرابع." && pending == " ثالث\nرابع.",
              "\(full.debugDescription) / \(pending.debugDescription)")

        // (c) Session gating: released in segment order, held until settled, nothing after close.
        do {
            var gate = LiveSegmentGate<String>(settled: true)
            let released = gate.complete(0, "أ") + gate.complete(1, nil) + gate.complete(2, "ب")
            check("gate: settled releases at once", released == ["أ", "ب"] && gate.nextIndex == 3, "\(released)")
        }
        do {
            var gate = LiveSegmentGate<String>(settled: true)
            let first = gate.complete(1, "ب")
            let second = gate.complete(0, "أ")
            check("gate: keeps segment order", first.isEmpty && second == ["أ", "ب"], "\(first) \(second)")
        }
        do {
            var gate = LiveSegmentGate<String>(settled: false)
            let held = gate.complete(0, "أ") + gate.complete(1, "ب")
            let flushed = gate.settle()
            let after = gate.complete(2, "ج")
            let again = gate.settle()
            check("gate: holds until settled, then flushes in order",
                  held.isEmpty && flushed == ["أ", "ب"] && after == ["ج"] && again.isEmpty,
                  "\(held) \(flushed) \(after) \(again)")
        }
        do {
            var gate = LiveSegmentGate<String>(settled: false)
            _ = gate.complete(0, "أ")
            _ = gate.complete(2, "ج")
            let flushed = gate.settle()
            let rest = gate.complete(1, "ب")
            check("gate: flush stops at a gap until it fills", flushed == ["أ"] && rest == ["ب", "ج"], "\(flushed) \(rest)")
        }
        do {
            var gate = LiveSegmentGate<String>(settled: false)
            _ = gate.complete(0, "أ")
            gate.close()
            let afterClose = gate.settle() + gate.complete(1, "ب") + gate.add(2, "ج")
            check("gate: abandoned before settling releases nothing", afterClose.isEmpty && gate.isClosed, "\(afterClose)")
        }
        do {
            var gate = LiveSegmentGate<String>(settled: true)
            let released = gate.complete(0, nil) + gate.complete(1, "ب")
            check("gate: a segment without text does not block the next", released == ["ب"] && gate.nextIndex == 2, "\(released)")
        }
        do {
            // Words of the open segment flow at once, after the earlier segment's end.
            var gate = LiveSegmentGate<String>(settled: true)
            let early = gate.add(1, "w1")
            let end0 = gate.complete(0, "end0")
            let more = gate.add(1, "w2")
            let end1 = gate.complete(1, "end1")
            let late = gate.add(1, "stale")
            check("gate: open-segment items in order, nothing after its end",
                  early.isEmpty && end0 == ["end0", "w1"] && more == ["w2"] && end1 == ["end1"] && late.isEmpty,
                  "\(early) \(end0) \(more) \(end1) \(late)")
        }
        do {
            // Auto mode: streamed words are held with everything else, then flushed in order.
            var gate = LiveSegmentGate<String>(settled: false)
            let held = gate.complete(0, "end0") + gate.add(1, "w1") + gate.add(1, "w2")
            let flushed = gate.settle()
            check("gate: streamed words held until settled", held.isEmpty && flushed == ["end0", "w1", "w2"], "\(held) \(flushed)")
        }

        // (d) Word keys and alignment.
        let w = { (text: String) in text.split(separator: " ").map(String.init) }
        check("key: hamza, ta marbuta, alef maqsura, tashkeel, brackets, case",
              StreamingText.key("أَحْمَدُ،") == "احمد" && StreamingText.key("مدرسة") == "مدرسه"
                && StreamingText.key("على") == "علي" && StreamingText.key("[CRM]") == "crm" && StreamingText.key("؟") == "",
              [StreamingText.key("أَحْمَدُ،"), StreamingText.key("مدرسة"), StreamingText.key("[CRM]")].joined(separator: "|"))
        check("words: punctuation-only tokens dropped", StreamingText.words("طيب ، تمام ؟") == ["طيب", "تمام"])
        check("align: exact prefix", StreamingText.alignEnd(w("انا رايح"), in: w("انا رايح على البيت")) == 2)
        check("align: nothing committed", StreamingText.alignEnd([], in: w("انا رايح")) == 0)
        check("align: spelling variants match", StreamingText.alignEnd(w("أنا رايحة"), in: w("انا رايحه على")) == 2)
        check("align: substituted word", StreamingText.alignEnd(w("انا رايح"), in: w("انا راجع على البيت")) == 2)
        check("align: hypothesis inserted a word", StreamingText.alignEnd(w("انا رايح"), in: w("انا هلا رايح على")) == 3)
        check("align: hypothesis dropped a committed word", StreamingText.alignEnd(w("انا رايح على"), in: w("انا على البيت")) == 2)
        check("align: hypothesis shorter than committed", StreamingText.alignEnd(w("انا رايح على"), in: w("انا رايح")) == 2)

        // (e) Commit policies: never retract, LA2 needs two agreeing hypotheses, HOLD-N keeps N back.
        do {
            var la2 = StreamingCommitter(policy: .localAgreement)
            let a = la2.update(w("انا رايح"), acceptable: true)
            let b = la2.update(w("انا رايح على"), acceptable: true)
            let c = la2.update(w("انا رايح على البيت"), acceptable: true)
            let d = la2.update(w("انا رايح على البيت بكرة"), acceptable: true)
            check("LA2: commits the agreed prefix only",
                  a.words.isEmpty && b.words == w("انا رايح") && b.lookahead == w("على")
                    && c.words == w("على") && d.words == w("البيت") && la2.committed == w("انا رايح على البيت"),
                  "\(a) \(b) \(c) \(d)")
        }
        do {
            var la2 = StreamingCommitter(policy: .localAgreement)
            _ = la2.update(w("انا رايح على"), acceptable: true)
            let changed = la2.update(w("انا راجع من"), acceptable: true)
            let agreed = la2.update(w("انا راجع من الشغل"), acceptable: true)
            check("LA2: a changed word waits for agreement",
                  changed.words == w("انا") && agreed.words == w("راجع من"), "\(changed) \(agreed)")
        }
        do {
            var hold = StreamingCommitter(policy: .hold(1))
            let a = hold.update(w("انا رايح على"), acceptable: true)
            let b = hold.update(w("انا رايح على البيت"), acceptable: true)
            let c = hold.update(w("انا راجع"), acceptable: true)   // shorter, diverged: nothing new
            check("HOLD-1: all but the last word, never retracts",
                  a.words == w("انا رايح") && a.lookahead == w("على") && b.words == w("على")
                    && c.words.isEmpty && hold.committed == w("انا رايح على"),
                  "\(a) \(b) \(c) \(hold.committed)")
        }
        do {
            var hold = StreamingCommitter(policy: .hold(2))
            let a = hold.update(w("انا رايح على البيت"), acceptable: true)
            check("HOLD-2: all but the last two words", a.words == w("انا رايح") && a.lookahead == w("على البيت"), "\(a)")
        }
        do {
            var hold = StreamingCommitter(policy: .hold(1))
            let one = hold.update(w("شكرا"), acceptable: true)
            let junk = hold.update([], acceptable: false)
            let two = hold.update(w("شكرا جزيلا لك"), acceptable: true)
            check("gate: nothing before a 2-word non-hallucination hypothesis",
                  one.words.isEmpty && junk.words.isEmpty && !two.words.isEmpty && two.words == w("شكرا جزيلا"),
                  "\(one) \(junk) \(two)")
        }
        do {
            var hold = StreamingCommitter(policy: .hold(1))
            _ = hold.update(w("انا رايح على البيت"), acceptable: true)
            let bad = hold.update(w("موسيقى موسيقى موسيقى"), acceptable: false)
            check("hallucinated hypothesis commits nothing", bad.words.isEmpty && hold.committed == w("انا رايح على"), "\(bad)")
        }

        // (f) Reconciliation with the final text: only what follows the committed words.
        do {
            var committer = StreamingCommitter(policy: .hold(1))
            _ = committer.update(w("انا رايح على البيت"), acceptable: true)
            let rest = committer.finish(w("انا رايح على البيت بكرة الصبح"))
            check("final: remainder after the committed words", rest == w("البيت بكرة الصبح"), "\(rest)")
        }
        do {
            var committer = StreamingCommitter(policy: .hold(1))
            _ = committer.update(w("انا رايح على البيت"), acceptable: true)
            let rest = committer.finish(w("انا راجع من البيت بكرة"))
            check("final: diverged words stay, the rest follows the best alignment",
                  rest == w("البيت بكرة") && committer.committed == w("انا رايح على البيت بكرة"), "\(rest)")
        }
        do {
            var committer = StreamingCommitter(policy: .hold(1))
            _ = committer.update(w("انا رايح على البيت"), acceptable: true)
            let rest = committer.finish(w("انا رايح"))
            check("final: shorter than committed adds nothing", rest.isEmpty, "\(rest)")
        }
        do {
            var committer = StreamingCommitter(policy: .localAgreement)
            let rest = committer.finish(w("كل الكلام"))
            check("final: nothing committed types the whole final", rest == w("كل الكلام"), "\(rest)")
        }

        // (g) Punctuation while streaming: after a word only once the next one is typed.
        do {
            var segment = StreamingSegmentTyping()
            let first = segment.step(new: w("مرحبا كيف"), lookahead: w("حالك"), formatted: "مرحبا، كيف حالك؟", isEnd: false)
            let second = segment.step(new: w("حالك"), lookahead: [], formatted: "مرحبا، كيف حالك؟", isEnd: false)
            let end = segment.step(new: [], lookahead: [], formatted: "مرحبا، كيف حالك؟", isEnd: true)
            var typed = ""
            for step in [first, second, end] { typed += LiveTyping.part(after: typed, step) }
            check("punctuation: deferred to the next word, final mark at the end",
                  first == .init(punctuation: "", text: "مرحبا، كيف") && second == .init(punctuation: "", text: "حالك")
                    && end == .init(punctuation: "؟", text: "") && typed == "مرحبا، كيف حالك؟",
                  "\(first) \(second) \(end) \(typed.debugDescription)")
        }
        do {
            var segment = StreamingSegmentTyping()
            let first = segment.step(new: w("i think"), lookahead: w("so"), formatted: "I think so.", isEnd: false)
            let end = segment.step(new: w("so"), lookahead: [], formatted: "I think. So.", isEnd: true)
            check("punctuation: model casing for new words, mark before the next word",
                  first.text == "I think" && end == .init(punctuation: ".", text: "So."), "\(first) \(end)")
        }
        do {
            var segment = StreamingSegmentTyping()
            let step = segment.step(new: w("واحد اثنين"), lookahead: [], formatted: "واحد اثنين ثلاثة", isEnd: false)
            check("punctuation: misaligned model output adds none", step == .init(punctuation: "", text: "واحد اثنين"), "\(step)")
        }
        do {
            var segment = StreamingSegmentTyping()
            let step = segment.step(new: w("بدون نموذج"), lookahead: [], formatted: nil, isEnd: true)
            check("punctuation: no model, words as they are", step == .init(punctuation: "", text: "بدون نموذج"), "\(step)")
        }
        check("part: space between segments, none before punctuation",
              LiveTyping.part(after: "أول.", .init(punctuation: "", text: "ثاني")) == " ثاني"
                && LiveTyping.part(after: "كلمة", .init(punctuation: "،", text: "تالية")) == "، تالية"
                && LiveTyping.part(after: "كلمة", .init(punctuation: "؟", text: "")) == "؟"
                && LiveTyping.part(after: "", .init(punctuation: "", text: "بداية")) == "بداية")

        print("\(total - failures)/\(total) passed")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
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
