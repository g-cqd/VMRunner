import Foundation
import Testing

@testable import DevTools

/// `vmr container-sign` end to end against a fixture executable: a real ad-hoc signature, read back by `codesign` itself. The
/// runner is never built or run here, so no virtual machine starts.
struct ContainerSignTests {
    private static let virtualization = ["com.apple.security.virtualization": "<true/>"]

    /// A temporary package root holding the entitlements file and a copy of a system executable to sign.
    private func withFixture<Value>(
        entitlements: [String: String] = virtualization, _ body: (URL, URL) async throws -> Value
    ) async throws -> Value {
        try await withTemporaryDirectory { directory in
            try write(["Resources/ContainerRunner.entitlements": AppFixture.entitlements(entitlements)], to: directory)
            let binary = directory.appending(path: "fixture")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            return try await body(directory, binary)
        }
    }

    @Test
    func aFixtureExecutableIsSignedWithTheVirtualizationEntitlementAndVerified() async throws {
        try await withFixture { directory, binary in
            let run = try await VMR.vmr(["container-sign", "--root", directory.path, "--binary", binary.path], in: directory)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("entitlements OK (com.apple.security.virtualization)"), "\(run.output)")
            #expect(run.outputLines.contains("Signed \(binary.path)"), "\(run.output)")

            // Read back with codesign itself, not through vmr.
            let verify = try await VMR.run("/usr/bin/codesign", ["--verify", "--strict", binary.path], in: directory)
            #expect(verify.status == 0, "\(verify.combined)")
            let entitlements = try await VMR.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path], in: directory)
            #expect(entitlements.output.contains("com.apple.security.virtualization"), "\(entitlements.combined)")
            let flags = try await VMR.run("/usr/bin/codesign", ["-dv", "--verbose=4", binary.path], in: directory)
            #expect((flags.error + flags.output).contains("(adhoc,runtime)"), "\(flags.combined)")
        }
    }

    @Test
    func entitlementsThatDoNotGrantVirtualizationAreRefusedBeforeAnythingIsSigned() async throws {
        try await withFixture(entitlements: ["com.apple.security.device.audio-input": "<true/>"]) { directory, binary in
            let run = try await VMR.vmr(["container-sign", "--root", directory.path, "--binary", binary.path], in: directory)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("ContainerRunner.entitlements must grant com.apple.security.virtualization"), "\(run.error)")
            let verify = try await VMR.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path], in: directory)
            #expect(!verify.output.contains("audio-input"), "the executable must be left as it was")
        }
    }

    @Test
    func anEntitlementOutsideThePolicyIsRefusedBeforeAnythingIsSigned() async throws {
        let attachable = Self.virtualization.merging(["com.apple.security.get-task-allow": "<true/>"]) { _, new in new }
        try await withFixture(entitlements: attachable) { directory, binary in
            let run = try await VMR.vmr(["container-sign", "--root", directory.path, "--binary", binary.path], in: directory)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("  - ContainerRunner.entitlements: get-task-allow is present in a release build"), "\(run.error)")
            let signed = try await VMR.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path], in: directory)
            #expect(!signed.output.contains("get-task-allow"), "the executable must be left as it was")
        }
    }

    @Test
    func aMissingExecutableIsNamed() async throws {
        try await withFixture { directory, _ in
            let missing = directory.appending(path: "absent")
            let run = try await VMR.vmr(["container-sign", "--root", directory.path, "--binary", missing.path], in: directory)
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("\(missing.path) is not an executable"), "\(run.error)")
        }
    }

    @Test
    func thisRepositorysRunnerEntitlementsGrantVirtualizationAndNothingElse() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = try Entitlements.load(fileAt: root.appending(path: "Resources/ContainerRunner.entitlements"))
        #expect(entitlements == [Entitlements.virtualization: .bool(true)])
    }
}
