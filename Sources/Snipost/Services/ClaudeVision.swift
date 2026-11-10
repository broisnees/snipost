import AppKit
import Foundation

/// Raw-HTTP client for the Claude Messages API (there's no official Swift
/// SDK). One call: an image + instructions in, structured JSON out.
enum ClaudeVision {
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Observation: Decodable {
        let conditionMet: Bool
        let summary: String

        enum CodingKeys: String, CodingKey {
            case conditionMet = "condition_met"
            case summary
        }
    }

    enum Failure: LocalizedError {
        case missingKey
        case refused
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your Anthropic API key in Settings → AI."
            case .refused: return "Claude declined to look at this region."
            case .badResponse(let detail): return "Unexpected response from Claude: \(detail)"
            }
        }
    }

    private static let systemPrompt = """
    You watch a region of the user's Mac screen and report on it. Each turn you \
    get the current screenshot of that region, your previous note (if any), and \
    the user's watch condition (if any).

    - summary: one short sentence (max ~20 words) on what the region shows now, \
    leading with what changed since the previous note. Plain words, no preamble.
    - condition_met: true only when the screenshot clearly shows the user's \
    condition is satisfied right now. With no condition, set it to true when \
    something meaningful changed (new message, finished progress, error, new \
    content), and false for trivial changes like a blinking cursor or clock tick.
    """

    static func observe(image: CGImage, condition: String, previousNote: String?, apiKey: String) async throws -> Observation {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        guard let jpeg = ImageEncoding.jpegData(image, maxBytes: 3_500_000) else {
            throw Failure.badResponse("could not encode screenshot")
        }

        var instructions = condition.isEmpty
            ? "No specific condition — tell me when something meaningful changes."
            : "Watch condition: \(condition)"
        if let previousNote {
            instructions += "\nPrevious note: \(previousNote)"
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": systemPrompt,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "condition_met": ["type": "boolean"],
                            "summary": ["type": "string"],
                        ],
                        "required": ["condition_met", "summary"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": jpeg.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": instructions],
                ] as [[String: Any]],
            ]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Net.check(response, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("not JSON")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw Failure.refused
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let textData = text.data(using: .utf8)
        else {
            throw Failure.badResponse("no text block (stop_reason: \(json["stop_reason"] ?? "nil"))")
        }
        return try JSONDecoder().decode(Observation.self, from: textData)
    }
}
