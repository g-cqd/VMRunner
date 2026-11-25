import Foundation
import Testing

@testable import GuestConsole

/// Signed vsock guest-agent protocol & evidence bundle (V4 / V7): verifies HMAC authentication, replay rejection,
/// path-traversal refusal in guest-returned unified diffs, and deterministic evidence JSON encoding.
struct VsockAgentProtocolTests {
    @Test
    func sealsOpensAndRejectsTamperedOrReplayedFrames() throws {
        let key = VsockAgentProtocol.generateSessionKey()
        let otherKey = VsockAgentProtocol.generateSessionKey()
        let cmd = VsockAgentProtocol.Command.run(argv: ["swift", "test"], workingDirectory: "/workspace", timeoutSeconds: 300)

        let frame1 = try VsockAgentProtocol.seal(cmd, sequence: 1, key: key)
        var lastSeq: UInt64 = 0
        let opened = try VsockAgentProtocol.open(frame1, as: VsockAgentProtocol.Command.self, lastSequence: &lastSeq, key: key)
        #expect(opened == cmd)
        #expect(lastSeq == 1)

        // Replay of sequence 1 must be refused.
        #expect(throws: VsockAgentProtocol.Failure.replayedSequence) {
            try VsockAgentProtocol.open(frame1, as: VsockAgentProtocol.Command.self, lastSequence: &lastSeq, key: key)
        }

        // Wrong key must fail MAC check.
        var freshSeq: UInt64 = 0
        #expect(throws: VsockAgentProtocol.Failure.badSignature) {
            try VsockAgentProtocol.open(frame1, as: VsockAgentProtocol.Command.self, lastSequence: &freshSeq, key: otherKey)
        }
    }

    @Test
    func refusesUnsafePathsInGuestReturnedUnifiedDiff() throws {
        let safeDiff = """
            --- a/Sources/App/File.swift
            +++ b/Sources/App/File.swift
            @@ -1 +1 @@
            -old
            +new
            """
        try VsockAgentProtocol.validateUnifiedDiff(safeDiff)

        let traversalDiff = """
            --- a/../../etc/hosts
            +++ b/../../etc/hosts
            """
        #expect(throws: VsockAgentProtocol.Failure.unsafePatchPath("../../etc/hosts")) {
            try VsockAgentProtocol.validateUnifiedDiff(traversalDiff)
        }

        let gitHookDiff = """
            --- /dev/null
            +++ b/.git/hooks/pre-commit
            """
        #expect(throws: VsockAgentProtocol.Failure.unsafePatchPath(".git/hooks/pre-commit")) {
            try VsockAgentProtocol.validateUnifiedDiff(gitHookDiff)
        }
    }

    @Test
    func evidenceBundleEncodesDeterministicJSONWithPatchDigest() throws {
        let bundle = SandboxEvidenceBundle(
            runID: UUID(),
            profile: "agent",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_045),
            exitCode: 0,
            allowedFlows: 12,
            deniedFlows: 2,
            deniedDestinations: ["169.254.169.254", "evil.example", "169.254.169.254"],
            controlDenials: 0,
            patchData: Data("diff".utf8)
        )
        let data = try bundle.encodedJSON()
        let decoded = try JSONDecoder().decode(SandboxEvidenceBundle.self, from: data)
        #expect(decoded.deniedDestinations == ["169.254.169.254", "evil.example"])
        #expect(decoded.patchSHA256?.count == 64)
    }
}
