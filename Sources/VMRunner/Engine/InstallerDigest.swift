import Foundation

/// The SHA-256 a person typed for an installer image they chose, and the check of the file against it. The check is optional:
/// an empty field means none was asked for. The hashing is `Checksums`', which streams the file off the main actor.
enum InstallerDigest {
    enum Failure: Error, Equatable, LocalizedError {
        /// The text is not 64 hexadecimal digits.
        case malformed
        case mismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .malformed:
                "The expected SHA-256 must be 64 hexadecimal digits (0 to 9 and a to f). Check what you pasted, or clear the field."
            case .mismatch(let expected, let actual):
                "The installer image does not match the expected SHA-256. Expected \(expected), but the file is \(actual). "
                    + "Choose the right file, or correct the checksum."
            }
        }
    }

    /// The lowercase digest `text` spells, or nil when `text` is empty after trimming spaces and line breaks.
    /// - Throws: `Failure.malformed` for anything else that is not 64 hexadecimal digits.
    static func expected(from text: String) throws(Failure) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count == 64, trimmed.utf8.allSatisfy(\.isASCIIHexDigit) else { throw .malformed }
        return trimmed.lowercased()
    }

    /// What is wrong with `text` as an expected digest, or nil when it is empty or well formed.
    static func problem(in text: String) -> Failure? {
        do throws(Failure) {
            _ = try expected(from: text)
            return nil
        } catch {
            return error
        }
    }

    /// Hashes `file` and compares it with `text`. Does nothing, and does not open the file, when `text` is empty.
    /// - Returns: whether a comparison was made.
    /// - Throws: `Failure` for a malformed text or a different digest; the error of the read for a file that cannot be read.
    @discardableResult
    static func verify(_ file: URL, against text: String) async throws -> Bool {
        guard let expected = try expected(from: text) else { return false }
        let actual = try await Checksums.hexDigest(of: file, algorithm: .sha256)
        guard actual == expected else { throw Failure.mismatch(expected: expected, actual: actual) }
        return true
    }
}

extension UInt8 {
    fileprivate var isASCIIHexDigit: Bool {
        (0x30...0x39).contains(self) || (0x41...0x46).contains(self) || (0x61...0x66).contains(self)
    }
}
