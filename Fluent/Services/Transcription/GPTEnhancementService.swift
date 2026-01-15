import Foundation

enum EnhancementError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidResponse:
            return "Invalid response from API."
        }
    }
}

class GPTEnhancementService {
    private let chatEndpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    private let keychainService = KeychainService.shared

    func enhance(text: String) async throws -> String {
        guard let apiKey = keychainService.getAPIKey() else {
            throw EnhancementError.noAPIKey
        }

        let systemPrompt = """
        You are a text formatting assistant. Your task is to clean up voice transcription text by:
        1. Adding proper punctuation (periods, commas, question marks, etc.)
        2. Fixing capitalization (sentence starts, proper nouns, acronyms)
        3. Correcting obvious speech-to-text errors
        4. Formatting numbers and dates appropriately

        Rules:
        - Do NOT change the meaning or add new content
        - Do NOT remove any words unless they're clearly duplicated errors
        - Keep the original tone and style
        - Return ONLY the corrected text, no explanations

        If the text is already well-formatted, return it as-is.
        """

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.1,
            "max_tokens": 2000
        ]

        var request = URLRequest(url: URL(string: chatEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EnhancementError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnhancementError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw EnhancementError.apiError(message)
            }
            throw EnhancementError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw EnhancementError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
