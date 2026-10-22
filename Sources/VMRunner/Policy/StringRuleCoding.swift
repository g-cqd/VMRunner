/// Shared Codable plumbing for rules that are stored as one readable string (`10.0.0.0/8`, `*.example.com`, ...).
///
/// Decoding re-validates the text, so a bad persisted rule fails to load instead of being silently dropped.
enum StringRuleCoding {
    static func decode<Rule>(_ decoder: any Decoder, kind: String, parse: (String) throws -> Rule) throws -> Rule {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            return try parse(text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid \(kind): \(error)")
        }
    }

    static func encode(_ text: String, to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
