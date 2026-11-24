import SwiftUI
import SwiftData
import AVFoundation

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
            //   Fluent --incremental-selftest /path/to/audio.m4a ar|auto [--fast] [--min-segment 2.5]
            runIncrementalSelfTest(arguments[index + 1], language: arguments[index + 2], arguments: arguments)
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
                log("engines loaded, audar usable=\(audar.isUsable) fast=\(fast) min_segment=\(config.minSegmentSeconds) pause=\(config.pauseSeconds) relax_after=\(config.relaxAfterSeconds)")

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
                    guard let session = IncrementalTranscriber.makeIfApplicable(stream: stream, config: config) else {
                        log("\(file): incremental path not applicable (Audar unusable or language not ar/auto)")
                        continue
                    }
                    await session.start()
                    // What live typing would receive: each released segment, and whether it
                    // came before the "stop" (posts no keyboard events).
                    let liveSegments = session.liveSegments
                    let liveCollector = Task { () -> [(text: String, at: UInt64)] in
                        var released: [(text: String, at: UInt64)] = []
                        for await text in liveSegments { released.append((text, LatencyLog.now())) }
                        return released
                    }
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
                    var liveTyped: [String] = []
                    for segment in released {
                        let processed = await service.postProcess(segment.text, timed: false)
                        if !processed.isEmpty { liveTyped.append(processed) }
                    }
                    log("\(file): live stream released \(released.count) segments, \(released.filter { $0.at < stopAt }.count) before stop")
                    print(["live", file, "-", String(released.count), "-", "", clean(LiveTyping.join(liveTyped))]
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

    /// Checks the pure parts of live typing (LiveTyping chunking/joining, LiveSegmentGate),
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

        // (c) Session gating: released in segment order, held until settled, blanks skipped,
        // nothing after close.
        do {
            var gate = LiveSegmentGate(settled: true)
            let released = gate.complete(0, text: "أ") + gate.complete(1, text: "  ") + gate.complete(2, text: " ب ")
            check("gate: settled releases at once, skips blanks", released == ["أ", "ب"], "\(released)")
        }
        do {
            var gate = LiveSegmentGate(settled: true)
            let first = gate.complete(1, text: "ب")
            let second = gate.complete(0, text: "أ")
            check("gate: keeps segment order", first.isEmpty && second == ["أ", "ب"], "\(first) \(second)")
        }
        do {
            var gate = LiveSegmentGate(settled: false)
            let held = gate.complete(0, text: "أ") + gate.complete(1, text: "ب")
            let flushed = gate.settle()
            let after = gate.complete(2, text: "ج")
            let again = gate.settle()
            check("gate: holds until settled, then flushes in order",
                  held.isEmpty && flushed == ["أ", "ب"] && after == ["ج"] && again.isEmpty,
                  "\(held) \(flushed) \(after) \(again)")
        }
        do {
            var gate = LiveSegmentGate(settled: false)
            _ = gate.complete(0, text: "أ")
            _ = gate.complete(2, text: "ج")
            let flushed = gate.settle()
            let rest = gate.complete(1, text: "ب")
            check("gate: flush stops at a gap until it fills", flushed == ["أ"] && rest == ["ب", "ج"], "\(flushed) \(rest)")
        }
        do {
            var gate = LiveSegmentGate(settled: false)
            _ = gate.complete(0, text: "أ")
            gate.close()
            let afterClose = gate.settle() + gate.complete(1, text: "ب")
            check("gate: abandoned before settling releases nothing", afterClose.isEmpty && gate.isClosed, "\(afterClose)")
        }
        do {
            var gate = LiveSegmentGate(settled: true)
            let released = gate.complete(0, text: nil) + gate.complete(1, text: "ب")
            check("gate: a segment without text does not block the next", released == ["ب"] && gate.nextIndex == 2, "\(released)")
        }

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
