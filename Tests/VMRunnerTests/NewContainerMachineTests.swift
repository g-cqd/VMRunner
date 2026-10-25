import Foundation
import Testing

@testable import VMRunner

/// The text a user types for a container becomes the arguments and settings a container machine is made of.
struct ContainerInputTests {
    @Test(
        arguments: [
            ("", []),
            ("   \t ", []),
            ("uname -a", ["uname", "-a"]),
            ("  /bin/sh   -c  echo  ", ["/bin/sh", "-c", "echo"]),
            (#"sh -c "echo hi  there""#, ["sh", "-c", "echo hi  there"]),
            (#"say """#, ["say", ""]),
            (#""""#, [""]),
            (#"a"b c"d e"#, ["ab cd", "e"]),
            (#""  ""#, ["  "]),
            ("tab\tseparated", ["tab", "separated"]),
            (#"keep\back"#, [#"keep\back"#]),
        ] as [(String, [String])])
    func aLineIsSplitIntoArguments(line: String, expected: [String]) throws {
        #expect(try ContainerInput.arguments(from: line) == expected)
    }

    @Test(arguments: [#"echo "unfinished"#, #"""#, #"a "b" "c d"#])
    func aQuoteThatIsNeverClosedIsRefused(line: String) {
        #expect(throws: ContainerInputError.self) { try ContainerInput.arguments(from: line) }
    }

    @Test func environmentLinesKeepTheirOrderAndSkipBlankOnes() throws {
        let entries = try ContainerInput.environment(from: "ZED=last\n\n  \nALPHA=first\r\nURL=https://x.test/?a=b\nEMPTY=")
        #expect(entries.map(\.name) == ["ZED", "ALPHA", "URL", "EMPTY"])
        #expect(entries.map(\.value) == ["last", "first", "https://x.test/?a=b", ""])
        #expect(try ContainerInput.environment(from: "").isEmpty)
    }

    @Test func aLineWithoutAnEqualsSignIsRefused() {
        #expect(throws: ContainerInputError.self) { try ContainerInput.environment(from: "A=1\nnot a setting") }
    }
}

/// The New Machine draft with the kind set to a container: the config it makes and what it refuses.
@MainActor
struct NewContainerMachineTests {
    private func makeModel(_ scratch: ScratchDefaults) -> NewMachineModel {
        let model = NewMachineModel(defaults: scratch.defaults)
        model.workload = .container
        model.workloadChanged(to: .container)
        return model
    }

    @Test func aVirtualMachineIsTheDefaultKindAndNothingChangesForIt() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)
        #expect(model.workload == .vm)
        let config = model.makeConfig()
        #expect(config.workload == .vm && config.container == nil && !config.isProvisioned)
        #expect(model.canCreate)
    }

    @Test func aContainerDraftMakesAValidContainerConfig() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        let id = model.config.id
        model.config.name = "  web  "
        model.container.image = " ghcr.io/example/tool:1 \n"
        model.commandLine = #"/bin/sh -c "echo hi""#
        model.environmentText = "MODE=test\nLEVEL=3"
        model.container.cpus = 4
        model.container.memoryMiB = 1024
        model.container.network = .loopback

        #expect(model.canCreate && model.containerProblem == nil)
        let config = try model.makeContainerConfig()
        #expect(config.workload == .container && config.guest == .linux && config.isProvisioned)
        #expect(config.id == id)
        #expect(config.name == "web")
        let expected = ContainerSpec(
            image: "ghcr.io/example/tool:1", command: ["/bin/sh", "-c", "echo hi"],
            environment: [
                ContainerEnvironmentEntry(name: "MODE", value: "test"), ContainerEnvironmentEntry(name: "LEVEL", value: "3"),
            ], cpus: 4, memoryMiB: 1024, network: .loopback)
        #expect(config.container == expected)
        try config.validate()
    }

    @Test func switchingToAContainerRenamesAPlaceholderAndKeepsACustomName() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let placeholder = makeModel(scratch)
        #expect(placeholder.config.name == "Container")
        #expect(placeholder.container == ContainerSpec())

        let custom = NewMachineModel(defaults: scratch.defaults)
        custom.config.name = "build agent"
        custom.workloadChanged(to: .container)
        #expect(custom.config.name == "build agent")
    }

    @Test func switchingBackToAVirtualMachineRestoresItsDefaults() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)
        let defaults = model.config
        model.config.cpuCount = defaults.cpuCount + 1
        model.config.memoryMiB = defaults.memoryMiB * 2
        model.localPath = "/tmp/restore.ipsw"
        model.workload = .container
        model.workloadChanged(to: .container)
        model.container.cpus = 8

        model.workload = .vm
        model.workloadChanged(to: .vm)

        #expect(model.config == defaults)
        #expect(model.localPath == nil)
        let config = model.makeConfig()
        #expect(config.workload == .vm && config.container == nil && config.source == .latestMac)
        #expect(model.canCreate)
    }

    @Test func aCustomGuestIsKeptWhenSwitchingBack() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)
        model.guestChanged(to: .linux)
        model.workloadChanged(to: .container)
        #expect(model.config.name == "Container")

        model.workloadChanged(to: .vm)

        #expect(model.config.guest == .linux)
        #expect(model.config.name == "Linux")
    }

    @Test(arguments: ["1A=x", "A-B=x", "=x", " A=x"])
    func anInvalidEnvironmentNameIsRefused(line: String) throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.environmentText = line
        #expect(model.containerProblem?.contains("container.environment") == true)
        #expect(!model.canCreate)
    }

    @Test func aNameGivenTwiceIsRefused() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.environmentText = "A=1\nB=2\nA=3"
        #expect(model.containerProblem?.contains("twice") == true)
        #expect(!model.canCreate)
    }

    @Test func aBrokenCommandOrAnEmptyImageCannotBeCreated() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.commandLine = #"echo "open"#
        #expect(model.containerProblem?.contains("double quote") == true)
        #expect(!model.canCreate)

        model.commandLine = ""
        model.container.image = "   "
        #expect(model.containerProblem?.contains("container.image") == true)
        #expect(!model.canCreate)

        model.container.image = ContainerSpec.defaultImage
        model.config.name = " "
        #expect(!model.canCreate)
    }

    @Test func creatingAContainerAddsItWithOnlyItsConfigAndNoSetup() throws {
        let scratch = try ScratchDefaults()
        let directory = try scratchDirectory()
        defer {
            scratch.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        let model = makeModel(scratch)
        model.environmentText = "A=1"

        #expect(model.create(in: library))

        let machine = try #require(library.machines.first)
        #expect(library.machines.count == 1 && machine.workload == .container && machine.id == model.config.id)
        #expect(machine.container?.environment == [ContainerEnvironmentEntry(name: "A", value: "1")])
        #expect(library.jobs[machine.id] == nil)
        #expect(model.creationError == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: library.bundle(machine.id).url.path)
        #expect(names == ["config.json"])
    }

    @Test func creatingARefusedContainerShowsTheReasonAndAddsNothing() throws {
        let scratch = try ScratchDefaults()
        let directory = try scratchDirectory()
        defer {
            scratch.cleanUp()
            try? FileManager.default.removeItem(at: directory)
        }
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600))
        let model = makeModel(scratch)
        model.environmentText = "A=1\nA=2"

        #expect(!model.create(in: library))

        #expect(model.creationError?.contains("twice") == true)
        #expect(library.machines.isEmpty)
    }
}

/// The sidebar tells a container from a virtual machine by its symbol and its caption.
struct SidebarRowTests {
    @Test func aContainerHasItsOwnSymbolKindAndCaption() {
        let config = VMConfig.newContainer(name: "box", container: ContainerSpec(cpus: 3, memoryMiB: 768))
        #expect(config.sidebarSymbol == "shippingbox")
        #expect(config.sidebarKind == "Container")
        #expect(config.sidebarCaption == "Container · 3 CPU · 768 MiB")
    }

    @Test func aVirtualMachineKeepsItsGuestSymbolAndCaption() {
        var config = VMConfig.new(name: "vm", guest: .linux)
        config.cpuCount = 4
        config.memoryMiB = 4096
        #expect(config.sidebarSymbol == GuestOS.linux.symbol)
        #expect(config.sidebarKind == "Linux")
        #expect(config.sidebarCaption == "Linux · 4 CPU · 4 GiB")
    }
}
