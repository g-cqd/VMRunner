import Foundation
import Testing

@testable import GuestSeed

/// A spec of one step: `rest` continues the line `  - at: `.
private func oneStep(_ rest: String) throws -> ProvisioningSpec {
    try ProvisioningSpec(
        parsing: "apiVersion: vmrunner.dev/v1alpha1\nkind: Provisioning\nmetadata:\n  name: node\nspec:\n  provision:\n  - at: " + rest)
}

private let trueScript = "\n    script: |\n      #!/bin/sh\n      true\n"

struct SeedCompilerTests {
    private func noFiles(_ spec: ProvisioningSpec) throws -> VerifiedScripts {
        try ScriptFiles.verify(spec, in: FileManager.default.temporaryDirectory)
    }

    private func refusal(_ spec: ProvisioningSpec) throws -> ProvisioningError {
        let scripts = try noFiles(spec)
        return try #require(throws: ProvisioningError.self) { try SeedCompiler.cloudConfig(for: spec.steps, scripts: scripts) }
    }

    @Test
    func eachPhaseGoesToItsModuleInTheSpecsOrderAndTheOutputIsGolden() throws {
        let spec = try ProvisioningSpec(
            parsing: """
                apiVersion: vmrunner.dev/v1alpha1
                kind: Provisioning
                metadata:
                  name: golden
                spec:
                  provision:
                  - at: early-boot
                    script: |
                      #!/bin/sh
                      echo early
                  - at: first-boot
                    script: |
                      #!/bin/sh
                      echo "$GREETING"
                    env:
                      GREETING: it's here
                  - at: every-boot
                    script: |
                      #!/bin/sh
                      echo again
                """)
        let expected =
            [
                "#cloud-config",
                "bootcmd:",
                "- ['/bin/sh', '-c', 'mkdir -p /var/lib/cloud/vmrunner && printf %s IyEvYmluL3NoCmVjaG8gZWFybHkK "
                    + "| base64 -d > /var/lib/cloud/vmrunner/step-001 && chmod 700 /var/lib/cloud/vmrunner/step-001 && "
                    + "exec env /var/lib/cloud/vmrunner/step-001']",
                "runcmd:",
                "- ['/bin/sh', '-c', 'mkdir -p /var/lib/cloud/vmrunner && printf %s IyEvYmluL3NoCmVjaG8gIiRHUkVFV"
                    + "ElORyIK | base64 -d > /var/lib/cloud/vmrunner/step-002 && chmod 700 /var/lib/cloud/vmrunner/step"
                    + "-002 && exec env ''GREETING=it''\\''''s here'' /var/lib/cloud/vmrunner/step-002']",
                "write_files:",
                "- path: /var/lib/cloud/scripts/per-boot/vmrunner-step-003",
                "  permissions: '0700'",
                "  encoding: b64",
                "  content: 'IyEvYmluL3NoCm1rZGlyIC1wIC92YXIvbGliL2Nsb3VkL3ZtcnVubmVyICYmIHByaW50ZiAlcyBJeUV2WW1s"
                    + "dUwzTm9DbVZqYUc4Z1lXZGhhVzRLIHwgYmFzZTY0IC1kID4gL3Zhci9saWIvY2xvdWQvdm1ydW5uZXIvc3RlcC0wMDMgJiYg"
                    + "Y2htb2QgNzAwIC92YXIvbGliL2Nsb3VkL3ZtcnVubmVyL3N0ZXAtMDAzICYmIGV4ZWMgZW52IC92YXIvbGliL2Nsb3VkL3Zt"
                    + "cnVubmVyL3N0ZXAtMDAzCg=='",
            ].joined(separator: "\n") + "\n"
        let scripts = try noFiles(spec)
        #expect(try SeedCompiler.cloudConfig(for: spec.steps, scripts: scripts) == expected)
        #expect(try SeedCompiler.cloudConfig(for: spec.steps, scripts: scripts) == expected, "the same input gives the same text")
    }

    @Test
    func theMetaDataNamesTheInstanceAndTheHost() throws {
        #expect(try SeedCompiler.metaData(name: "golden", instanceID: "i-0123") == "instance-id: i-0123\nlocal-hostname: golden\n")
        _ = try SeedCompiler.metaData(name: "golden", instanceID: String(repeating: "a", count: 64))
        for bad in ["", "has space", "a/b", String(repeating: "a", count: 65)] {
            let error = try #require(throws: ProvisioningError.self) { try SeedCompiler.metaData(name: "golden", instanceID: bad) }
            #expect(error.line == nil)
            #expect(error.message.contains("instance identifier"), "\(error)")
        }
    }

    @Test
    func aFileStepCarriesTheCheckedBytes() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: folder.appending(path: "hello.sh"))
        let spec = try oneStep(
            "first-boot\n    file: hello.sh\n    sha256: bfdeaeb08cffb6a36438bcd12dda25417e3cdd36f1e7e482a2849d539225288b\n")
        let config = try SeedCompiler.cloudConfig(for: spec.steps, scripts: try ScriptFiles.verify(spec, in: folder))
        #expect(config.contains("printf %s \(Data("#!/bin/sh\necho hello\n".utf8).base64EncodedString()) | base64 -d"))
    }

    @Test
    func aFileTheCheckDidNotCoverOrWithoutAnInterpreterIsRefused() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let unchecked = try oneStep(
            "first-boot\n    file: hello.sh\n    sha256: bfdeaeb08cffb6a36438bcd12dda25417e3cdd36f1e7e482a2849d539225288b\n")
        let otherSpecsScripts = try noFiles(try oneStep("first-boot" + trueScript))
        let error = try #require(throws: ProvisioningError.self) {
            try SeedCompiler.cloudConfig(for: unchecked.steps, scripts: otherSpecsScripts)
        }
        #expect(error.line == 7)
        #expect(error.message == "hello.sh was not checked against its sha256")

        try Data("echo no shebang\n".utf8).write(to: folder.appending(path: "plain.sh"))
        let plain = try oneStep(
            "first-boot\n    file: plain.sh\n    sha256: 3c0cb907fb7a9918b0b318076e7d6eef110f7c8e4e3c2fbc15ec0d9507314f86\n")
        let scripts = try ScriptFiles.verify(plain, in: folder)
        let noInterpreter = try #require(throws: ProvisioningError.self) {
            try SeedCompiler.cloudConfig(for: plain.steps, scripts: scripts)
        }
        #expect(noInterpreter.message == "plain.sh does not start with #! and its interpreter")
    }

    /// The seed is readable by everything in the guest: a step that needs a secret is refused, never compiled without it.
    @Test
    func aStepWithASecretIsRefusedRatherThanCompiledWithoutIt() throws {
        let error = try refusal(try oneStep("first-boot" + trueScript + "    env:\n      TOKEN:\n        secretRef: k3s-token\n"))
        #expect(error.line == 7)
        #expect(error.message.contains("never written into the seed"), "\(error)")
    }

    @Test(arguments: ["pre-install", "post-install", "install-error", "ready", "pre-shutdown"])
    func aPhaseThisVersionCannotRunIsRefusedWithTheStepsLine(phase: String) throws {
        let error = try refusal(try oneStep(phase + trueScript))
        #expect(error.line == 7)
        #expect(error.message.hasPrefix(phase), "\(error)")
    }

    @Test
    func aStepThatRunsAsTheUserIsRefused() throws {
        let error = try refusal(try oneStep("first-boot\n    user: user" + trueScript))
        #expect(error.line == 7)
        #expect(error.message.contains("runs as the user"), "\(error)")
    }

    @Test
    func noStepsGiveAnEmptyCloudConfig() throws {
        #expect(try SeedCompiler.cloudConfig(for: [], scripts: try noFiles(try oneStep("first-boot" + trueScript))) == "#cloud-config\n")
    }
}
