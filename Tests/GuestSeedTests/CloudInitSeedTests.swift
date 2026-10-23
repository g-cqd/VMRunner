import Foundation
import Testing

@testable import GuestSeed

private let header = "apiVersion: vmrunner.dev/v1alpha1\nkind: Provisioning\nmetadata:\n  name: node\nspec:\n"
private let firstStep = "  provision:\n  - at: first-boot\n    script: |\n      #!/bin/sh\n      echo first\n"

/// The steps' cloud-config for `firstStep`, line by line (golden).
private let firstStepConfig = [
    "#cloud-config",
    "runcmd:",
    "- ['/bin/sh', '-c', 'mkdir -p /var/lib/cloud/vmrunner && printf %s IyEvYmluL3NoCmVjaG8gZmlyc3QK "
        + "| base64 -d > /var/lib/cloud/vmrunner/step-001 && chmod 700 /var/lib/cloud/vmrunner/step-001 && "
        + "exec env /var/lib/cloud/vmrunner/step-001']",
]

struct CloudInitSeedTests {
    private func seed(_ specBody: String, instanceID: String = "i-1") throws -> CloudInitSeed {
        let spec = try ProvisioningSpec(parsing: header + specBody)
        return try SeedCompiler.compile(
            spec, scripts: try ScriptFiles.verify(spec, in: FileManager.default.temporaryDirectory), instanceID: instanceID)
    }

    private func refusal(_ specBody: String) throws -> ProvisioningError {
        try #require(throws: ProvisioningError.self) { try seed(specBody) }
    }

    @Test
    func theUsersDataAndTheStepsMergeIntoAGoldenMultipartDocument() throws {
        let compiled = try seed(
            "  cloudInit:\n    userData: |\n      #cloud-config\n      package_update: true\n    networkData: |\n      version: 2\n"
                + firstStep)
        let head = [
            "Content-Type: multipart/mixed; boundary=\"==vmrunner-seed-boundary==\"",
            "MIME-Version: 1.0",
            "",
            "--==vmrunner-seed-boundary==",
            "Content-Type: text/cloud-config; charset=\"utf-8\"",
            "",
            "#cloud-config",
            "package_update: true",
            "--==vmrunner-seed-boundary==",
            "Content-Type: text/cloud-config; charset=\"utf-8\"",
            "Merge-Type: list(append)+dict(no_replace,recurse_list)+str()",
            "",
        ]
        let expected = (head + firstStepConfig + ["--==vmrunner-seed-boundary==--"]).joined(separator: "\n") + "\n"
        #expect(compiled.userData == expected)
        #expect(compiled.metaData == "instance-id: i-1\nlocal-hostname: node\n")
        #expect(compiled.networkConfig == "version: 2\n")
    }

    @Test
    func stepsAloneAreTheWholeUserData() throws {
        let compiled = try seed(firstStep)
        #expect(compiled.userData == firstStepConfig.joined(separator: "\n") + "\n")
        #expect(compiled.networkConfig == nil)
    }

    @Test
    func theUsersDataAloneIsPassedThroughAsGiven() throws {
        let script = try seed("  cloudInit:\n    userData: |\n      #!/bin/sh\n      echo hi\n")
        #expect(script.userData == "#!/bin/sh\necho hi\n")
        let config = try seed("  cloudInit:\n    userDataBase64: I2Nsb3VkLWNvbmZpZwpwYWNrYWdlX3VwZGF0ZTogdHJ1ZQo=\n")
        #expect(config.userData == "#cloud-config\npackage_update: true\n")
    }

    @Test
    func userDataOfAnotherKindIsRefusedWithItsLine() throws {
        let alone = try refusal("  cloudInit:\n    userData: |\n      #include https://example.invalid/x\n")
        #expect(alone.line == 7)
        #expect(alone.message == "cloudInit.userData must start with #cloud-config or #!")
        let archive = try refusal("  cloudInit:\n    userData: |\n      #cloud-config-archive\n      - x\n")
        #expect(archive.line == 7)
        let merged = try refusal("  cloudInit:\n    userData: plain words\n" + firstStep)
        #expect(merged.line == 7)
    }

    @Test
    func userDataHoldingTheBoundaryIsRefused() throws {
        let error = try refusal("  cloudInit:\n    userData: |\n      #cloud-config\n      # --==vmrunner-seed-boundary==\n" + firstStep)
        #expect(error.line == 7)
        #expect(error.message.contains("MIME boundary"), "\(error)")
    }

    @Test
    func theSameSpecGivesTheSameSeed() throws {
        let body = "  cloudInit:\n    userData: |\n      #cloud-config\n" + firstStep
        let first = try seed(body)
        let second = try seed(body)
        #expect(first == second)
    }

    /// The seed's type is the boundary of what the guest can read: all of its fields are text the compiler made, so a type
    /// that names a secret cannot be stored in it. Adding a field of another type fails here first.
    @Test
    func everyFieldOfTheSeedIsText() throws {
        let compiled = try seed(firstStep)
        let fields = Mirror(reflecting: compiled).children
        #expect(fields.compactMap(\.label) == ["userData", "metaData", "networkConfig"])
        #expect(fields.allSatisfy { ["String", "Optional<String>"].contains("\(type(of: $0.value))") })
    }
}
