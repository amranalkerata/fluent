import AVFoundation
import Accelerate

enum AudioConversionError: LocalizedError {
    case fileNotFound
    case cannotReadFile
    case conversionFailed(String)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found."
        case .cannotReadFile:
            return "Cannot read audio file."
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .invalidFormat:
            return "Invalid audio format."
        }
    }
}

class AudioConverter {
    // WhisperKit requires 16kHz mono PCM
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1

    /// Convert audio file to 16kHz mono Float32 samples for WhisperKit
    static func convertToWhisperSamples(url: URL) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioConversionError.fileNotFound
        }

        return try await Task.detached(priority: .userInitiated) {
            try convertAudioFile(url: url)
        }.value
    }

    private static func convertAudioFile(url: URL) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AudioConversionError.cannotReadFile
        }

        let sourceFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)

        // Create target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioConversionError.invalidFormat
        }

        // If source is already in target format, read directly
        if sourceFormat.sampleRate == targetSampleRate &&
           sourceFormat.channelCount == targetChannels &&
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return try readDirectly(from: audioFile, frameCount: sourceFrameCount)
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioConversionError.conversionFailed("Could not create audio converter")
        }

        // Calculate output buffer size
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOutputFrames) else {
            throw AudioConversionError.conversionFailed("Could not create output buffer")
        }

        // Read source audio
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw AudioConversionError.conversionFailed("Could not create source buffer")
        }

        do {
            try audioFile.read(into: sourceBuffer)
        } catch {
            throw AudioConversionError.conversionFailed("Could not read audio file: \(error.localizedDescription)")
        }

        // Convert
        var conversionError: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &conversionError) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            throw AudioConversionError.conversionFailed(conversionError?.localizedDescription ?? "Unknown error")
        }

        // Extract float samples
        guard let channelData = outputBuffer.floatChannelData?[0] else {
            throw AudioConversionError.conversionFailed("Could not access converted audio data")
        }

        let frameLength = Int(outputBuffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength)
        memcpy(&samples, channelData, frameLength * MemoryLayout<Float>.size)

        return samples
    }

    private static func readDirectly(from audioFile: AVAudioFile, frameCount: AVAudioFrameCount) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw AudioConversionError.conversionFailed("Could not create buffer")
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioConversionError.conversionFailed("Could not access audio data")
        }

        let frameLength = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength)
        memcpy(&samples, channelData, frameLength * MemoryLayout<Float>.size)

        return samples
    }

    /// Get audio duration in seconds
    static func getAudioDuration(url: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return nil
        }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }
}

/// Turns microphone tap buffers (any rate, any channel count) into 16 kHz mono Float32,
/// keeping the resampler's filter state across buffers so the stream has no seams.
/// The first two channels are averaged (as before); the rate change goes through `AVAudioConverter` (band-limited),
/// the same converter the file path uses. Not thread-safe: use it from one thread at a time
/// (the audio tap's), then `flush()` once after the tap is removed.
final class StreamingResampler {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConverter.targetSampleRate,
        channels: 1,
        interleaved: false
    )!
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// 16 kHz mono samples for `buffer`, or nil if it cannot be read (non-float data).
    func process(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let mono = downmix(buffer) else { return nil }
        let sourceRate = buffer.format.sampleRate
        if abs(sourceRate - AudioConverter.targetSampleRate) < 1 {
            converter = nil
            return Self.samples(of: mono)
        }
        if converter == nil || monoFormat?.sampleRate != sourceRate {
            guard let newConverter = AVAudioConverter(from: mono.format, to: targetFormat) else { return nil }
            monoFormat = mono.format
            converter = newConverter
        }
        return convert(mono, endOfStream: false)
    }

    /// Samples still held inside the resampler's filter (a few ms); call once at the end.
    func flush() -> [Float] {
        guard converter != nil else { return [] }
        let tail = convert(nil, endOfStream: true) ?? []
        converter = nil
        return tail
    }

    private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool) -> [Float]? {
        guard let converter else { return nil }
        let inputFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(inputFrames * targetFormat.sampleRate / converter.inputFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if let input, !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            // .noDataNow keeps the filter history for the next buffer; .endOfStream drains it.
            outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        guard status != .error else { return nil }
        return Self.samples(of: output)
    }

    /// Mono Float32 copy of `buffer` at its own rate (first two channels averaged).
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let totalChannels = Int(buffer.format.channelCount)
        let channels = min(totalChannels, 2)
        guard frames > 0, channels > 0, let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        // Interleaved float data sits in channel 0 with a stride of `channels`.
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? totalChannels : 1
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? source[0][frame * stride + channel] : source[channel][frame]
            }
            destination[frame] = sum * scale
        }
        return mono
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
