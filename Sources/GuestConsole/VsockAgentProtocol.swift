import CryptoKit
package import Foundation

/// Signed, replay-resistant framed vsock host↔guest agent protocol (V4 / V7):
/// - Every request and response frame is length-prefixed JSON authenticated with HMAC-SHA256 using an ephemeral per-run
///   256-bit key generated on the host (passed via cloud-init / provisioning seed, never persisted across runs).
/// - Strict sequence-number monotonicity prevents replay and out-of-order injection.
/// - Payload size is capped (`maximumFrameBytes`) before decoding so a compromised guest cannot exhaust host memory.
/// - Patch extraction sanitizes output paths and refuses path traversal (`..`), absolute paths, or oversized diffs.
package enum VsockAgentProtocol {
    package static let maximumFrameBytes = 16 << 20

    package enum Failure: Error, Equatable, Sendable {
        case frameTooLarge
        case malformedFrame
        case badSignature
        case replayedSequence
        case unsafePatchPath(String)
    }

    package enum Command: Codable, Equatable, Sendable {
        case ping
        case run(argv: [String], workingDirectory: String, timeoutSeconds: Int)
        case extractPatch(baseRef: String)
        case shutdown
    }

    package struct Reply: Codable, Equatable, Sendable {
        package let exitCode: Int32
        package let stdout: String
        package let stderr: String
        package let patch: String?

        package init(exitCode: Int32, stdout: String = "", stderr: String = "", patch: String? = nil) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.patch = patch
        }
    }

    package struct Envelope<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        package let sequence: UInt64
        package let payload: Payload
        package let macHex: String
    }

    /// Generates an ephemeral 256-bit per-run HMAC key.
    package static func generateSessionKey() -> Data {
        unsafe SymmetricKey(size: .bits256).withUnsafeBytes { bytes in unsafe Data(bytes) }
    }

    /// Encodes and authenticates `payload` at `sequence` under `sessionKey`.
    package static func seal<Payload: Codable & Equatable & Sendable>(
        _ payload: Payload,
        sequence: UInt64,
        key sessionKey: Data
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadBytes = try encoder.encode(payload)
        let mac = computeMAC(sequence: sequence, payloadBytes: payloadBytes, key: sessionKey)
        let envelope = Envelope(sequence: sequence, payload: payload, macHex: mac)
        let framed = try encoder.encode(envelope)
        guard framed.count <= maximumFrameBytes else { throw Failure.frameTooLarge }
        return framed
    }

    /// Verifies the HMAC-SHA256 tag and strict sequence monotonicity (`sequence > lastSequence`) before returning `payload`.
    package static func open<Payload: Codable & Equatable & Sendable>(
        _ frame: Data,
        as type: Payload.Type,
        lastSequence: inout UInt64,
        key sessionKey: Data
    ) throws -> Payload {
        guard frame.count <= maximumFrameBytes else { throw Failure.frameTooLarge }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope<Payload>.self, from: frame) else {
            throw Failure.malformedFrame
        }
        guard envelope.sequence > lastSequence else { throw Failure.replayedSequence }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payloadBytes = try? encoder.encode(envelope.payload) else { throw Failure.malformedFrame }
        let expected = computeMAC(sequence: envelope.sequence, payloadBytes: payloadBytes, key: sessionKey)
        guard constantTimeEqual(envelope.macHex, expected) else { throw Failure.badSignature }
        lastSequence = envelope.sequence
        return envelope.payload
    }

    /// Validates every `+++ b/<path>` and `--- a/<path>` header in a guest-returned unified diff so a compromised guest
    /// cannot trick host-side `git apply` into touching paths outside the repo (`..`, absolute paths, `.git/`).
    package static func validateUnifiedDiff(_ patch: String) throws {
        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let candidate: String
            if line.hasPrefix("+++ b/") {
                candidate = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/") {
                candidate = String(line.dropFirst(6))
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                let rest = String(line.dropFirst(4))
                if rest == "/dev/null" { continue }
                candidate = rest
            } else {
                continue
            }
            if candidate.hasPrefix("/")
                || candidate.split(separator: "/").contains("..")
                || candidate == ".git"
                || candidate.hasPrefix(".git/")
            {
                throw Failure.unsafePatchPath(candidate)
            }
        }
    }

    private static func computeMAC(sequence: UInt64, payloadBytes: Data, key: Data) -> String {
        var macInput = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            macInput.append(UInt8(truncatingIfNeeded: sequence >> shift))
        }
        macInput.append(payloadBytes)
        let code = HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: key))
        return hex(code)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    package static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for (xByte, yByte) in zip(left, right) { diff |= xByte ^ yByte }
        return diff == 0
    }
}

/// Structured, SIEM-ready evidence bundle emitted after an isolated agent run (V7 / R-OPS-1).
package struct SandboxEvidenceBundle: Codable, Equatable, Sendable {
    package let runID: UUID
    package let profile: String
    package let startedAt: String
    package let finishedAt: String
    package let exitCode: Int32
    package let allowedFlows: Int
    package let deniedFlows: Int
    package let deniedDestinations: [String]
    package let controlDenials: Int
    package let patchSHA256: String?

    package init(
        runID: UUID,
        profile: String,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        allowedFlows: Int,
        deniedFlows: Int,
        deniedDestinations: [String],
        controlDenials: Int,
        patchData: Data?
    ) {
        let formatter = ISO8601DateFormatter()
        self.runID = runID
        self.profile = profile
        self.startedAt = formatter.string(from: startedAt)
        self.finishedAt = formatter.string(from: finishedAt)
        self.exitCode = exitCode
        self.allowedFlows = allowedFlows
        self.deniedFlows = deniedFlows
        self.deniedDestinations = Array(Set(deniedDestinations)).sorted()
        self.controlDenials = controlDenials
        if let patchData {
            self.patchSHA256 = VsockAgentProtocol.hex(SHA256.hash(data: patchData))
        } else {
            self.patchSHA256 = nil
        }
    }

    package func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
