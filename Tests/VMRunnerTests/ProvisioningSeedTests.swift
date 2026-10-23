import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// The seed a Linux machine boots with: compiled at each start from the spec and its scripts, written read-only into the
/// machine's bundle, refused with the spec's line, and removed with the run's other leftovers.
struct ProvisioningSeedTests {
    static let script = "#!/bin/sh\necho from-a-file\n"
    /// `printf '#!/bin/sh\necho from-a-file\n' | shasum -a 256`
    static let scriptDigest = "9fac65956eed58d4f824fb41da075198b48ab5193c3ab144970ee56f0e58a630"
    static let spec = """
        apiVersion: vmrunner.dev/v1alpha1
        kind: Provisioning
        metadata:
          name: seed-test
        spec:
          provision:
            - at: first-boot
              script: |
                #!/bin/sh
                echo first > /var/lib/vmrunner-marker
            - at: every-boot
              file: scripts/hello.sh
              sha256: \(Self.scriptDigest)

        """

    /// A scratch folder holding a spec folder (the spec and its script) and a machine bundle.
    private struct Scratch {
        let root: URL
        let specPath: String
        let bundle: VMBundle
    }

    private func makeScratch(spec: String = Self.spec, script: String = Self.script) throws -> Scratch {
        let root = try scratchDirectory()
        let folder = root.appending(path: "spec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "scripts"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: folder.appending(path: "scripts/hello.sh"))
        let specFile = folder.appending(path: "machine.yaml")
        try Data(spec.utf8).write(to: specFile)
        let bundle = VMBundle(url: root.appending(path: "m.vm", directoryHint: .isDirectory))
        try bundle.create()
        return Scratch(root: root, specPath: specFile.path, bundle: bundle)
    }

    private func machine(_ guest: GuestOS = .linux, spec path: String) -> VMConfig {
        var config = VMConfig.new(name: "m", guest: guest)
        config.provisioningSpecPath = path
        return config
    }

    @Test
    func aStartWritesTheSeedIntoTheBundleReadableByItsOwnerOnly() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)

        let seed = scratch.bundle.provisioningSeed
        #expect(seed.deletingLastPathComponent().lastPathComponent == "m.vm")
        let mode = try FileManager.default.attributesOfItem(atPath: seed.path)[.posixPermissions] as? Int
        #expect(mode == 0o400)
        let bytes = try Data(contentsOf: seed)
        #expect(bytes.count > 32_774 && bytes.count.isMultiple(of: 2048))
        #expect(Array(bytes[32_769..<32_774]) == Array("CD001".utf8), "an ISO 9660 volume")
    }

    @Test
    func theSameSpecGivesTheSameSeedAtEveryStart() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let config = machine(spec: scratch.specPath)

        try ProvisioningSeed.prepare(for: config, bundle: scratch.bundle)
        let first = try Data(contentsOf: scratch.bundle.provisioningSeed)
        try ProvisioningSeed.prepare(for: config, bundle: scratch.bundle)
        #expect(try Data(contentsOf: scratch.bundle.provisioningSeed) == first)
    }

    @Test
    func aRefusedSpecFailsTheStartWithItsLine() throws {
        let scratch = try makeScratch(spec: Self.spec.replacing("at: first-boot", with: "at: second-boot"))
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        let error = try #require(throws: ProvisioningSeedError.self) {
            try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)
        }
        #expect(error.reason.hasPrefix("line 7: at must be one of "))
        #expect(error.localizedDescription.hasPrefix("The provisioning spec machine.yaml can't be used: line 7: at must be one of "))
        #expect(!FileManager.default.fileExists(atPath: scratch.bundle.provisioningSeed.path))
    }

    @Test
    func aScriptThatNoLongerMatchesItsDigestIsRefusedWithItsStepsLine() throws {
        let scratch = try makeScratch(script: "#!/bin/sh\necho changed\n")
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        let error = try #require(throws: ProvisioningSeedError.self) {
            try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)
        }
        #expect(error.reason.hasPrefix("line 11: scripts/hello.sh does not match its sha256"))
    }

    @Test
    func aMissingOrOversizedSpecIsRefusedBeforeItIsRead() throws {
        let scratch = try makeScratch(spec: String(repeating: "a", count: 65_537))
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        let large = try #require(throws: ProvisioningSeedError.self) {
            try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)
        }
        #expect(large.reason == "it is larger than 65536 bytes")
        let missing = try #require(throws: ProvisioningSeedError.self) {
            try ProvisioningSeed.prepare(for: machine(spec: scratch.root.appending(path: "none.yaml").path), bundle: scratch.bundle)
        }
        #expect(missing == ProvisioningSeedError(spec: "none.yaml", reason: "it is missing or not a regular file"))
    }

    @Test
    func aMachineWithoutASpecInUseGetsNoSeedAndLosesALeftoverOne() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        var installing = machine(spec: scratch.specPath)
        installing.installerISO = "/Users/me/installer.iso"

        for config in [machine(spec: ""), machine(.macOS, spec: scratch.specPath), installing] {
            try Data([1]).write(to: scratch.bundle.provisioningSeed)
            try ProvisioningSeed.prepare(for: config, bundle: scratch.bundle)
            #expect(!FileManager.default.fileExists(atPath: scratch.bundle.provisioningSeed.path))
        }
    }

    @Test
    func theSeedGoesWithTheRunsOtherLeftovers() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)

        scratch.bundle.discardEphemeral()

        #expect(!FileManager.default.fileExists(atPath: scratch.bundle.provisioningSeed.path))
    }

    @Test
    func theSeedAStartWritesIsTheReadOnlyDriveTheMachineGets() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let config = machine(spec: scratch.specPath)
        try Data(count: 1 << 20).write(to: scratch.bundle.disk)

        try ProvisioningSeed.prepare(for: config, bundle: scratch.bundle)
        let devices = try ConfigurationBuilder.storage(for: config, bundle: scratch.bundle)

        let drive = try #require(devices.last as? VZUSBMassStorageDeviceConfiguration)
        let attachment = try #require(drive.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(attachment.isReadOnly)
        #expect(attachment.url.lastPathComponent == "ProvisioningSeed.iso")
    }

    @Test
    func aSavedStateIsKeptOnlyWhileTheSeedIsTheOneItWasSavedWith() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let bundle = scratch.bundle
        let config = machine(spec: scratch.specPath)

        try Data([1]).write(to: bundle.savedState)
        try ProvisioningSeed.prepare(for: config, bundle: bundle)
        #expect(!bundle.hasSavedState, "a seed added since the suspend")

        try Data([1]).write(to: bundle.savedState)
        try ProvisioningSeed.prepare(for: config, bundle: bundle)
        #expect(bundle.hasSavedState, "the same seed")

        let edited = Self.spec.replacing("echo first", with: "echo again")
        try Data(edited.utf8).write(to: URL(filePath: scratch.specPath))
        try ProvisioningSeed.prepare(for: config, bundle: bundle)
        #expect(!bundle.hasSavedState, "a spec edited since the suspend")

        try Data([1]).write(to: bundle.savedState)
        try ProvisioningSeed.prepare(for: machine(spec: ""), bundle: bundle)
        #expect(!bundle.hasSavedState, "a seed removed since the suspend")
        #expect(!FileManager.default.fileExists(atPath: bundle.provisioningSeedDigest.path))

        try Data([1]).write(to: bundle.savedState)
        try ProvisioningSeed.prepare(for: machine(spec: ""), bundle: bundle)
        #expect(bundle.hasSavedState, "no seed then and none now")
    }

    @Test
    func theDigestOfTheLastSeedIsPrivateAndOutlivesTheRun() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try ProvisioningSeed.prepare(for: machine(spec: scratch.specPath), bundle: scratch.bundle)

        let digest = scratch.bundle.provisioningSeedDigest
        #expect(try String(contentsOf: digest, encoding: .utf8).count == 64)
        #expect(try FileManager.default.attributesOfItem(atPath: digest.path)[.posixPermissions] as? Int == 0o600)
        scratch.bundle.discardEphemeral()
        #expect(FileManager.default.fileExists(atPath: digest.path), "it lives as long as the saved state it guards")
    }

    @Test
    func theEditorsCheckListsEachStepWithItsLineAndWritesNothing() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        #expect(
            ProvisioningCheck(specAt: scratch.specPath)
                == .ready(["line 7: first-boot, inline script", "line 11: every-boot, scripts/hello.sh, sha256 9fac65956eed…"]))
        #expect(!FileManager.default.fileExists(atPath: scratch.bundle.provisioningSeed.path))
    }

    @Test
    func theEditorsCheckShowsWhyTheStartWouldRefuse() throws {
        let scratch = try makeScratch(script: "#!/bin/sh\necho changed\n")
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        guard case .refused(let reason) = ProvisioningCheck(specAt: scratch.specPath) else {
            Issue.record("the check accepted a script that does not match its digest")
            return
        }
        #expect(reason.hasPrefix("line 11: scripts/hello.sh does not match its sha256"))
    }
}
