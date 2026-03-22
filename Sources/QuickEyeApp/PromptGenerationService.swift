import AppKit
import Foundation

struct PromptGenerationService {
    enum Error: LocalizedError {
        case invalidBaseURL
        case missingAPIKey
        case missingModel
        case imageEncodingFailed
        case serverError(statusCode: Int, message: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "The configured base URL is not valid."
            case .missingAPIKey:
                return "Add an API key in Prompt Settings before converting screenshots to text."
            case .missingModel:
                return "Add a model name in Prompt Settings before converting screenshots to text."
            case .imageEncodingFailed:
                return "Quick Eye could not prepare the screenshot for the model request."
            case let .serverError(statusCode, message):
                return "The provider returned \(statusCode): \(message)"
            case .malformedResponse:
                return "The provider response did not include any prompt text."
            }
        }
    }

    func generatePrompt(from image: NSImage, settings: PromptGenerationSettings) async throws -> String {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingAPIKey
        }

        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingModel
        }

        guard let pngData = image.quickEyePNGData else {
            throw Error.imageEncodingFailed
        }

        switch settings.provider {
        case .gemini:
            return try await generateWithGemini(imageData: pngData, settings: settings)
        case .openAI, .openRouter:
            return try await generateWithOpenAICompatible(imageData: pngData, settings: settings)
        }
    }

    private func generateWithGemini(imageData: Data, settings: PromptGenerationSettings) async throws -> String {
        let requestURL = try endpointURL(
            baseURL: settings.baseURL,
            path: "models/\(settings.model):generateContent"
        )

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "text": settings.promptTemplate,
                        ],
                        [
                            "inlineData": [
                                "mimeType": "image/png",
                                "data": imageData.base64EncodedString(),
                            ],
                        ],
                    ],
                ],
            ],
        ]

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performJSONRequest(request)
        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw Error.malformedResponse
        }

        let combinedText = parts
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !combinedText.isEmpty else {
            throw Error.malformedResponse
        }

        return combinedText
    }

    private func generateWithOpenAICompatible(imageData: Data, settings: PromptGenerationSettings) async throws -> String {
        let requestURL = try endpointURL(baseURL: settings.baseURL, path: "chat/completions")
        let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": settings.model,
            "temperature": 0.2,
            "messages": [
                [
                    "role": "system",
                    "content": settings.promptTemplate,
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "Convert this annotated screenshot into the final text-only prompt. Return only the prompt text.",
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": dataURL,
                                "detail": "low",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performJSONRequest(request)
        guard
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any]
        else {
            throw Error.malformedResponse
        }

        if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Error.malformedResponse }
            return trimmed
        }

        if let contentParts = message["content"] as? [[String: Any]] {
            let combined = contentParts
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else { throw Error.malformedResponse }
            return combined
        }

        throw Error.malformedResponse
    }

    private func endpointURL(baseURL: String, path: String) throws -> URL {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBaseURL) else {
            throw Error.invalidBaseURL
        }

        let normalizedPath = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if components.path.isEmpty || components.path == "/" {
            components.path = normalizedPath
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + normalizedPath
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }

        guard let url = components.url else {
            throw Error.invalidBaseURL
        }

        return url
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.malformedResponse
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        let json = jsonObject as? [String: Any] ?? [:]

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: json) ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw Error.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return json
    }

    private func extractErrorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }

            if let message = error["status"] as? String {
                return message
            }
        }

        if let error = json["error"] as? String {
            return error
        }

        return nil
    }
}

private extension NSImage {
    var quickEyePNGData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
