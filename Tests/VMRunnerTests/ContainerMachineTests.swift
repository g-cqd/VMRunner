import Foundation
import Testing

@testable import VMRunner

/// A machine that runs a container is a configuration and nothing else: how it is stored, read back and checked.
struct ContainerConfigTests {
    private func decode(_ json: String) throws -> VMConfig { try VMConfig.decode(from: Data(json.utf8)) }

    /// The description of the `DecodingError.dataCorrupted` that reading `spec` in a container machine raises.
    private func refusal(of spec: ContainerSpec) throws -> String {
        let data = try VMConfig.newContainer(name: "box", container: spec).encoded()
        do {
            _ = try VMConfig.decode(from: data)
        } catch DecodingError.dataCorrupted(let context) {
            return context.debugDescription
        }
        Issue.record("the spec was accepted")
        return ""
    }

    @Test func aConfigWrittenBeforeContainersExistedIsAVirtualMachine() throws {
        let config = try decode(#"{"guest":"linux","name":"old","diskGiB":16}"#)
        #expect(config.workload == .vm)
        #expect(config.container == nil)
        #expect(try decode(#"{"name":"older"}"#).workload == .vm)
    }

    @Test func aVirtualMachineIgnoresAContainerSpecItHolds() throws {
        let config = try decode(#"{"guest":"linux","workload":"vm","container":{"cpus":99,"image":""}}"#)
        #expect(config.workload == .vm)
    }

    @Test func aContainerConfigSurvivesAWriteAndARead() throws {
        let spec = ContainerSpec(
            image: "ghcr.io/example/tool:1.2", command: ["/bin/sh", "-c", "echo hi"],
            environment: [
                ContainerEnvironmentEntry(name: "ZED", value: "last"), ContainerEnvironmentEntry(name: "ALPHA", value: "first"),
            ], cpus: 4, memoryMiB: 2048, network: .loopback)
        let config = VMConfig.newContainer(name: "box", container: spec)
        let decoded = try VMConfig.decode(from: config.encoded())
        #expect(decoded == config)
        #expect(decoded.workload == .container && decoded.guest == .linux && decoded.isProvisioned)
        #expect(decoded.container?.environment.map(\.name) == ["ZED", "ALPHA"], "the order the user chose is kept")
    }

    @Test func aContainerSpecWithSomeKeysGetsTheDefaultOfTheOthers() throws {
        let config = try decode(#"{"workload":"container","container":{"image":"ghcr.io/example/tool:1","cpus":4}}"#)
        #expect(config.container == ContainerSpec(image: "ghcr.io/example/tool:1", cpus: 4))
        let spec = try #require(config.container)
        #expect(spec.command.isEmpty && spec.environment.isEmpty && spec.memoryMiB == 512 && spec.network == .none)
    }

    @Test func aContainerConfigWithoutASpecRunsTheDefaultContainer() throws {
        let config = try decode(#"{"workload":"container"}"#)
        #expect(config.container == ContainerSpec())
        #expect(config.container?.image == "docker.io/library/alpine:3.24.2")
        #expect(config.container?.cpus == 2 && config.container?.memoryMiB == 512)
    }

    @Test func anEnvironmentValueAtTheByteLimitIsAcceptedAndOneMoreIsRefused() throws {
        let limit = ContainerLimits.maxEnvironmentValueBytes
        try VMConfig.newContainer(name: "box", container: env("A", String(repeating: "v", count: limit))).validate()
        let problem = try refusal(of: env("A", String(repeating: "v", count: limit + 1)))
        #expect(problem.contains("container.environment"), "\(problem)")
    }

    @Test func anUnknownWorkloadIsRefused() {
        #expect(throws: (any Error).self) { try decode(#"{"workload":"jail"}"#) }
    }

    @Test func aContainerConfigMissingItsSpecIsRefusedByValidation() {
        var config = VMConfig.newContainer(name: "box")
        config.container = nil
        #expect(throws: DecodingError.self) { try config.validate() }
    }

    @Test func theLimitsThemselvesAreAccepted() throws {
        let environment = (0..<ContainerLimits.maxEnvironmentEntries).map { ContainerEnvironmentEntry(name: "V\($0)", value: "x") }
        let widest = ContainerSpec(
            image: String(repeating: "a", count: ContainerLimits.maxImageBytes),
            command: Array(repeating: String(repeating: "c", count: ContainerLimits.maxCommandElementBytes), count: 64),
            environment: environment, cpus: 16, memoryMiB: 16384, network: .loopback)
        try VMConfig.newContainer(name: "box", container: widest).validate()
        try VMConfig.newContainer(name: "box", container: ContainerSpec(cpus: 1, memoryMiB: 128)).validate()
    }

    @Test(
        arguments: [
            ContainerRefusal("an empty image", ContainerSpec(image: ""), "container.image"),
            ContainerRefusal("an image with a space", ContainerSpec(image: "alpine :3"), "container.image"),
            ContainerRefusal("an image with a newline", ContainerSpec(image: "alpine\n"), "container.image"),
            ContainerRefusal("an image with a tab", ContainerSpec(image: "alpine\t3"), "container.image"),
            ContainerRefusal("an image with a control character", ContainerSpec(image: "alpine\u{7}"), "container.image"),
            ContainerRefusal("an image of 256 bytes", ContainerSpec(image: String(repeating: "a", count: 256)), "container.image"),
            ContainerRefusal("65 command elements", ContainerSpec(command: Array(repeating: "x", count: 65)), "container.command"),
            ContainerRefusal(
                "a command element of 4097 bytes", ContainerSpec(command: [String(repeating: "x", count: 4097)]), "container.command"),
            ContainerRefusal("a command element with NUL", ContainerSpec(command: ["ok", "a\u{0}b"]), "container.command"),
            ContainerRefusal("an environment name that starts with a digit", env("1A", "v"), "container.environment"),
            ContainerRefusal("an empty environment name", env("", "v"), "container.environment"),
            ContainerRefusal("an environment name with a dash", env("A-B", "v"), "container.environment"),
            ContainerRefusal("an environment name with a non-ASCII letter", env("É", "v"), "container.environment"),
            ContainerRefusal("an environment value with NUL", env("A", "a\u{0}b"), "container.environment"),
            ContainerRefusal("an environment value with a newline", env("A", "a\nb"), "container.environment"),
            ContainerRefusal(
                "a name that appears twice",
                ContainerSpec(environment: [
                    ContainerEnvironmentEntry(name: "A", value: "1"), ContainerEnvironmentEntry(name: "B", value: "2"),
                    ContainerEnvironmentEntry(name: "A", value: "3"),
                ]), "twice"
            ),
            ContainerRefusal(
                "65 environment entries",
                ContainerSpec(environment: (0..<65).map { ContainerEnvironmentEntry(name: "V\($0)", value: "") }), "container.environment"
            ),
            ContainerRefusal("no CPU", ContainerSpec(cpus: 0), "container.cpus"),
            ContainerRefusal("17 CPUs", ContainerSpec(cpus: 17), "container.cpus"),
            ContainerRefusal("127 MiB of memory", ContainerSpec(memoryMiB: 127), "container.memoryMiB"),
            ContainerRefusal("16385 MiB of memory", ContainerSpec(memoryMiB: 16385), "container.memoryMiB"),
        ])
    func aSpecOutsideTheRunnersLimitsIsRefused(_ refused: ContainerRefusal) throws {
        let problem = try refusal(of: refused.spec)
        #expect(problem.contains(refused.mention), "\(refused.label): \(problem)")
    }
}

/// A spec the runner would refuse, and the word the refusal must carry.
struct ContainerRefusal: Sendable, CustomTestStringConvertible {
    let label: String
    let spec: ContainerSpec
    let mention: String

    init(_ label: String, _ spec: ContainerSpec, _ mention: String) {
        self.label = label
        self.spec = spec
        self.mention = mention
    }

    var testDescription: String { label }
}

private func env(_ name: String, _ value: String) -> ContainerSpec {
    ContainerSpec(environment: [ContainerEnvironmentEntry(name: name, value: value)])
}

/// The library keeps a container machine without a disk, a firmware state or a display.
@MainActor
struct ContainerLibraryTests {
    private func makeLibrary(in directory: URL) -> VMLibrary {
        VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
    }

    private func names(in bundle: VMBundle) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).sorted()
    }

    private var spec: ContainerSpec {
        ContainerSpec(
            image: "ghcr.io/example/tool:1.2", command: ["/bin/true"],
            environment: [ContainerEnvironmentEntry(name: "MODE", value: "test")], cpus: 3, memoryMiB: 1024, network: .loopback)
    }

    @Test func aContainerBundleWithOnlyItsConfigLoadsAndLists() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = VMConfig.newContainer(name: "box", container: spec)
        let first = makeLibrary(in: directory)
        try first.add(config)
        #expect(try names(in: first.bundle(config.id)) == ["config.json"])

        let second = makeLibrary(in: directory)
        second.load()
        #expect(second.alertMessage == nil)
        #expect(second.machines == [config])
        #expect(second.selection == config.id)
        #expect(second.bundle(config.id).allocatedBytes >= 0, "measuring a bundle without a disk reports what is there")
        #expect(!FileManager.default.fileExists(atPath: second.bundle(config.id).disk.path))
    }

    @Test func aContainerMachineIsRenamedAndTheNameIsStored() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        var config = VMConfig.newContainer(name: "box", container: spec)
        try library.add(config)

        config.name = "renamed"
        library.update(config)
        library.flushPendingWrites()

        let reloaded = makeLibrary(in: directory)
        reloaded.load()
        #expect(reloaded.machines.map(\.name) == ["renamed"])
        #expect(reloaded.machines.first?.container == spec)
        #expect(library.alertMessage == nil)
    }

    @Test func aContainerMachineIsDeletedWithItsBundle() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        let config = VMConfig.newContainer(name: "box", container: spec)
        try library.add(config)

        library.delete(config.id)

        #expect(library.machines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.bundle(config.id).url.path))
        #expect(library.alertMessage == nil)
    }

    @Test func duplicatingAContainerMachineKeepsItsWorkloadAndSpec() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        let original = VMConfig.newContainer(name: "box", container: spec)
        try library.add(original)

        try library.duplicate(original.id)

        let copy = try #require(library.machines.first { $0.id != original.id })
        #expect(copy.name == "box Copy")
        #expect(copy.workload == .container && copy.container == spec)
        #expect(try names(in: library.bundle(copy.id)) == ["config.json"], "no disk, firmware state or identifier is made")
        let stored = try VMConfig.load(from: library.bundle(copy.id).config)
        #expect(stored.workload == .container && stored.container == spec)
    }

    /// A machine whose runs filled the output file past its limit, so both files exist.
    private func leaveOutput(in bundle: VMBundle) async {
        let file = ContainerOutputFile(current: bundle.containerOutput, previous: bundle.previousContainerOutput, limit: 8)
        for text in ["aaaaaaa\n", "bbbbbbb\n"] {
            file.append(Array(text.utf8))
            await file.drained()
        }
    }

    @Test func aContainerMachinesOutputFilesGoWithItsBundle() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        let config = VMConfig.newContainer(name: "box", container: spec)
        try library.add(config)
        await leaveOutput(in: library.bundle(config.id))
        #expect(try names(in: library.bundle(config.id)) == ["config.json", "container-output.1.log", "container-output.log"])

        library.delete(config.id)

        #expect(!FileManager.default.fileExists(atPath: library.bundle(config.id).url.path))
    }

    @Test func duplicatingAContainerMachineDoesNotCopyItsOutput() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        let original = VMConfig.newContainer(name: "box", container: spec)
        try library.add(original)
        await leaveOutput(in: library.bundle(original.id))

        try library.duplicate(original.id)

        let copy = try #require(library.machines.first { $0.id != original.id })
        #expect(try names(in: library.bundle(copy.id)) == ["config.json"])
        #expect(try names(in: library.bundle(original.id)) == ["config.json", "container-output.1.log", "container-output.log"])
    }

    @Test func aContainerMachineIsNotSetUpAsAVirtualMachine() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        let config = VMConfig.newContainer(name: "box", container: spec)
        try library.add(config)

        library.beginSetup(config.id)
        #expect(library.jobs[config.id] == nil)
        #expect(try names(in: library.bundle(config.id)) == ["config.json"])
    }
}
