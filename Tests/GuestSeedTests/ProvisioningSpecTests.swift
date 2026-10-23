import Testing

@testable import GuestSeed

/// A small valid spec; each refusal case below edits one part of it.
private let base = """
    apiVersion: vmrunner.dev/v1alpha1
    kind: Provisioning
    metadata:
      name: node
    spec:
      provision:
      - at: first-boot
        script: |
          #!/bin/sh
          true

    """

private let digest = String(repeating: "a", count: 64)
private let scriptBlock = "    script: |\n      #!/bin/sh\n      true"

/// One refusal of the model: the text of `base` to replace (it occurs once), its replacement, the line the error names and
/// a fragment of its message.
struct SpecRefusal: Sendable {
    let replace: String
    let replacement: String
    let line: Int?
    let fragment: String

    init(_ replace: String, _ replacement: String, _ line: Int?, _ fragment: String) {
        self.replace = replace
        self.replacement = replacement
        self.line = line
        self.fragment = fragment
    }
}

let specRefusals: [SpecRefusal] = [
    SpecRefusal("apiVersion: vmrunner.dev/v1alpha1", "apiVersion: v1", 1, "apiVersion must be vmrunner.dev/v1alpha1"),
    SpecRefusal("kind: Provisioning", "kind: Pod", 2, "kind must be Provisioning"),
    SpecRefusal("kind: Provisioning", "kind: Provisioning\nstatus: x", 3, "the spec has no field status"),
    SpecRefusal("metadata:\n  name: node\n", "", 1, "the spec needs metadata"),
    SpecRefusal("metadata:\n  name: node", "metadata: node", 3, "metadata must be a map"),
    SpecRefusal("  name: node", "  name: node\n  labels: x", 5, "metadata has no field labels"),
    SpecRefusal("  name: node", "  name: Node", 4, "DNS label"),
    SpecRefusal("  name: node", "  name: -node", 4, "DNS label"),
    SpecRefusal("  name: node", "  name: " + String(repeating: "a", count: 64), 4, "DNS label"),
    SpecRefusal("spec:\n", "spec:\n  cloudInit:\n    secretRef: s\n", 7, "a secret never goes into the seed"),
    SpecRefusal("spec:\n", "spec:\n  cloudInit:\n    userData: x\n    userDataBase64: eA==\n", 8, "not both"),
    SpecRefusal("spec:\n", "spec:\n  cloudInit:\n    userDataBase64: '%%%'\n", 7, "not base64"),
    SpecRefusal("  provision:\n  - at: first-boot\n" + scriptBlock, "  provision: none", 6, "must be a list"),
    SpecRefusal("  provision:\n  - at: first-boot\n" + scriptBlock, "  cloudInit:\n    networkData: x", 6, "at least one provision step"),
    SpecRefusal("  - at: first-boot", "  - at: boot", 7, "at must be one of"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    user: root", 8, "user must be system or user"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    file: a.sh", 7, "either script or file"),
    SpecRefusal(scriptBlock, "    user: system", 7, "either script or file"),
    SpecRefusal(scriptBlock, "    file: a.sh", 8, "a file needs its sha256"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    sha256: \(digest)", 8, "sha256 goes with file"),
    SpecRefusal(scriptBlock, "    file: a.sh\n    sha256: \(digest.uppercased())", 9, "64 lowercase"),
    SpecRefusal(scriptBlock, "    file: a.sh\n    sha256: abc", 9, "64 lowercase"),
    SpecRefusal(scriptBlock, "    file: /etc/x.sh\n    sha256: \(digest)", 8, "relative path"),
    SpecRefusal(scriptBlock, "    file: ../x.sh\n    sha256: \(digest)", 8, "relative path"),
    SpecRefusal("      #!/bin/sh\n", "", 8, "starts with #!"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    env:\n      1X: y", 9, "not a variable name"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    env:\n      X:\n      - y", 9, "text or a map with secretRef"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    env:\n      X: a\u{85}b", 9, "one line"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    env:\n      X: a\u{2028}b", 9, "one line"),
    SpecRefusal("  - at: first-boot", "  - at: first-boot\n    env:\n      X: |\n        a\n        b", 9, "one line"),
    SpecRefusal(
        "  - at: first-boot", "  - at: first-boot\n    env:\n      X:\n        secretRef: s\n        key: k", 11, "has no field key"),
]

struct ProvisioningSpecTests {
    @Test
    func theStudysExampleReadsIntoTheModel() throws {
        let spec = try ProvisioningSpec(
            parsing: """
                apiVersion: vmrunner.dev/v1alpha1
                kind: Provisioning
                metadata:
                  name: k3s-node
                spec:
                  cloudInit:
                    userData: |
                      #cloud-config
                      package_update: true
                  provision:
                    - at: first-boot
                      user: system
                      file: scripts/install-k3s.sh
                      sha256: bfdeaeb08cffb6a36438bcd12dda25417e3cdd36f1e7e482a2849d539225288b
                      env:
                        K3S_TOKEN:
                          secretRef: k3s-token
                        INSTALL_K3S_CHANNEL: stable
                    - at: ready
                      script: |
                        #!/bin/sh
                        kubectl wait --for=condition=Ready node --all
                """)
        #expect(spec.name == "k3s-node")
        #expect(spec.cloudInit.userData?.text == "#cloud-config\npackage_update: true\n")
        #expect(spec.cloudInit.userData?.line == 7)
        #expect(spec.cloudInit.networkData == nil)
        #expect(spec.steps.count == 2)
        let install = try #require(spec.steps.first)
        #expect(install.line == 11)
        #expect(install.phase == .firstBoot)
        #expect(install.user == .system)
        let installDigest = "bfdeaeb08cffb6a36438bcd12dda25417e3cdd36f1e7e482a2849d539225288b"
        #expect(install.script == .file(path: "scripts/install-k3s.sh", sha256: installDigest))
        #expect(install.variables.map(\.name) == ["INSTALL_K3S_CHANNEL"])
        #expect(install.variables.map(\.value) == ["stable"])
        #expect(install.secrets.map(\.name) == ["K3S_TOKEN"])
        #expect(install.secrets.map(\.secretName) == ["k3s-token"])
        let ready = try #require(spec.steps.last)
        #expect(ready.line == 19)
        #expect(ready.phase == .ready)
        #expect(ready.user == .system)
        #expect(ready.script == .inline("#!/bin/sh\nkubectl wait --for=condition=Ready node --all\n"))
        #expect(ready.variables.isEmpty && ready.secrets.isEmpty)
    }

    @Test
    func base64UserAndNetworkDataAreDecoded() throws {
        let spec = try ProvisioningSpec(
            parsing: """
                apiVersion: vmrunner.dev/v1alpha1
                kind: Provisioning
                metadata:
                  name: node
                spec:
                  cloudInit:
                    userDataBase64: I2Nsb3VkLWNvbmZpZwpwYWNrYWdlX3VwZGF0ZTogdHJ1ZQo=
                    networkDataBase64: dmVyc2lvbjogMgo=
                """)
        #expect(spec.cloudInit.userData == SpecText(text: "#cloud-config\npackage_update: true\n", line: 7))
        #expect(spec.cloudInit.networkData == SpecText(text: "version: 2\n", line: 8))
        #expect(spec.steps.isEmpty)
    }

    @Test
    func aStepRunsAsSystemUnlessItSaysUser() throws {
        let spec = try ProvisioningSpec(parsing: base.replacing("  - at: first-boot", with: "  - at: every-boot\n    user: user"))
        #expect(spec.steps.map(\.user) == [.user])
        #expect(spec.steps.map(\.phase) == [.everyBoot])
        #expect(try ProvisioningSpec(parsing: base).steps.map(\.user) == [.system])
    }

    /// A secret is a name the guest agent resolves later: the spec keeps it apart from the values the seed may carry, and
    /// the type that holds it has no field for a value.
    @Test
    func aSecretReferenceNeverBecomesAValue() throws {
        let spec = try ProvisioningSpec(
            parsing: base.replacing(
                "  - at: first-boot", with: "  - at: first-boot\n    env:\n      TOKEN:\n        secretRef: token\n      MODE: fast"))
        let step = try #require(spec.steps.first)
        #expect(step.variables == [StepVariable(name: "MODE", value: "fast")])
        #expect(step.secrets == [SecretVariable(name: "TOKEN", secretName: "token")])
        let fields = Mirror(reflecting: SecretVariable(name: "TOKEN", secretName: "token")).children.compactMap(\.label)
        #expect(fields == ["name", "secretName"], "a secret entry holds names only")
    }

    @Test(arguments: specRefusals)
    func refusesWithTheLine(_ given: SpecRefusal) throws {
        #expect(base.ranges(of: given.replace).count == 1, "the case edits exactly one place of the base spec")
        let error = try #require(throws: ProvisioningError.self) {
            try ProvisioningSpec(parsing: base.replacing(given.replace, with: given.replacement))
        }
        #expect(error.line == given.line, "\(error)")
        #expect(error.message.contains(given.fragment), "\(error)")
    }

    // MARK: Limits

    @Test
    func aSpecAtTheStepLimitIsReadAndOneStepMoreIsRefused() throws {
        let step = "  - at: first-boot\n" + scriptBlock + "\n"
        let header = "apiVersion: vmrunner.dev/v1alpha1\nkind: Provisioning\nmetadata:\n  name: node\nspec:\n  provision:\n"
        var limits = ProvisioningLimits.standard
        limits.maxSteps = 2
        #expect(try ProvisioningSpec(parsing: header + step + step, limits: limits).steps.count == 2)
        let error = try #require(throws: ProvisioningError.self) {
            try ProvisioningSpec(parsing: header + step + step + step, limits: limits)
        }
        #expect(error.line == 15, "the first step past the limit")
        #expect(error.message == "more than 2 steps")
    }
}
