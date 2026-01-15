import Foundation

enum TranscriptionError: LocalizedError {
    case noAPIKey
    case invalidAPIKey
    case fileTooLarge
    case networkError(Error)
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Please add your OpenAI API key in Settings."
        case .invalidAPIKey:
            return "Invalid API key. Please check your OpenAI API key in Settings."
        case .fileTooLarge:
            return "Audio file is too large. Maximum size is 25MB."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidResponse:
            return "Invalid response from API."
        }
    }
}

class TranscriptionService {
    private let whisperEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    private let maxFileSize: Int64 = 25 * 1024 * 1024 // 25MB

    private let keychainService = KeychainService.shared
    private let settingsService = SettingsService.shared

    func transcribe(audioURL: URL) async throws -> String {
        // Get API key
        guard let apiKey = keychainService.getAPIKey() else {
            throw TranscriptionError.noAPIKey
        }

        // Check file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        if let fileSize = fileAttributes[.size] as? Int64, fileSize > maxFileSize {
            throw TranscriptionError.fileTooLarge
        }

        // Read audio data
        let audioData = try Data(contentsOf: audioURL)

        // Create multipart form request
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: whisperEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build form body
        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(settingsService.settings.whisperModel.rawValue)\r\n".data(using: .utf8)!)

        // Add language if specified
        let language = settingsService.settings.language.rawValue
        if !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        // Add response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Make request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionError.networkError(error)
        }

        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw TranscriptionError.invalidAPIKey
        }

        if httpResponse.statusCode != 200 {
            // Try to parse error message
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw TranscriptionError.apiError(message)
            }
            throw TranscriptionError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse response (plain text for "text" format)
        guard let transcription = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.invalidResponse
        }

        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Test API key validity
    func testAPIKey(_ apiKey: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}
