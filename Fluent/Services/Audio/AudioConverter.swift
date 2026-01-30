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
