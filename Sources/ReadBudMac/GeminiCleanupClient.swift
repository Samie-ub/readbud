import Foundation

enum GeminiCleanupError: LocalizedError {
    case missingAPIKey
    case textTooShort
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add a Gemini API key in Settings before enabling cleanup."
        case .textTooShort: "There is not enough extracted text to clean."
        case .requestFailed(let message): message
        case .emptyResponse: "Gemini returned an empty cleanup response."
        }
    }
}

struct GeminiCleanupResult {
    let text: String
    let inputCharacters: Int
    let outputCharacters: Int
    let wasTruncated: Bool
}

enum GeminiCleanupClient {
    private static let model = "gemini-3.5-flash"
    private static let inputCharacterLimit = 120_000
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

    static func clean(text: String, title: String, apiKey: String) async throws -> GeminiCleanupResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GeminiCleanupError.missingAPIKey }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > 120 else { throw GeminiCleanupError.textTooShort }

        let limitedText = String(trimmedText.prefix(inputCharacterLimit))
        let wasTruncated = limitedText.count < trimmedText.count
        let prompt = """
        Clean this extracted article text for text-to-speech playback.

        Rules:
        - Return only the cleaned article text.
        - Preserve the author's meaning and order.
        - Remove navigation, newsletter prompts, cookie notices, captions, ads, repeated headings, related links, and social sharing text.
        - Keep useful section headings.
        - Fix broken whitespace and obvious extraction artifacts.
        - Do not summarize, rewrite stylistically, add commentary, or add markdown fences.

        Title: \(title)

        Extracted text:
        \(limitedText)
        """

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: trimmedKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(GeminiGenerateContentRequest(
            contents: [
                GeminiContent(parts: [GeminiPart(text: prompt)])
            ],
            generationConfig: GeminiGenerationConfig(
                temperature: 0.1,
                maxOutputTokens: 16_384
            )
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiCleanupError.requestFailed("Gemini cleanup returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data)
            throw GeminiCleanupError.requestFailed(error?.error.message ?? "Gemini cleanup failed with HTTP \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        let cleaned = decoded.candidates
            .flatMap(\.content.parts)
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { throw GeminiCleanupError.emptyResponse }

        return GeminiCleanupResult(
            text: cleaned,
            inputCharacters: limitedText.count,
            outputCharacters: cleaned.count,
            wasTruncated: wasTruncated
        )
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    let text: String?
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent
}

private struct GeminiErrorResponse: Decodable {
    let error: GeminiAPIError
}

private struct GeminiAPIError: Decodable {
    let message: String
}
