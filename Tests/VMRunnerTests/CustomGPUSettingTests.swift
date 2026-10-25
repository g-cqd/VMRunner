import Foundation
import Testing

@testable import VMRunner

/// The graphics device setting: stored with a tolerant decode, part of what a saved memory image depends on, and the reason
/// suspend gives while the custom GPU is in use.
struct CustomGPUSettingTests {
    private func machine(_ guest: GuestOS = .linux, gpu: GPUChoice = .custom) -> VMConfig {
        var config = VMConfig.new(name: "g", guest: guest)
        config.gpu = gpu
        return config
    }

    @Test
    func aNewMachineGetsTheFrameworksOwnDevice() {
        for guest in GuestOS.allCases { #expect(VMConfig.new(name: "n", guest: guest).gpu == .apple) }
    }

    @Test
    func theChoiceIsStoredAndReadBack() throws {
        for choice in GPUChoice.allCases {
            #expect(try VMConfig.decode(from: machine(gpu: choice).encoded()).gpu == choice)
        }
    }

    @Test
    func aConfigWrittenBeforeTheSettingExistedGetsTheFrameworksOwnDevice() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try VMConfig.decode(from: Data(old.utf8)).gpu == .apple)
    }

    @Test(arguments: [#""metal3d""#, #""""#, "7", "null", "true", #"["custom"]"#])
    func aDeviceThisVersionDoesNotKnowReadsAsTheFrameworksOwnAndKeepsTheRest(stored: String) throws {
        var original = machine(gpu: .custom)
        original.name = "from a newer version"
        original.cpuCount = 3
        original.memoryMiB = 3072
        let json = try #require(String(data: original.encoded(), encoding: .utf8))
        let rewritten = json.replacingOccurrences(of: #""gpu" : "custom""#, with: #""gpu" : \#(stored)"#)
        #expect(rewritten != json, "the stored value was replaced")

        let decoded = try VMConfig.decode(from: Data(rewritten.utf8))
        #expect(decoded.gpu == .apple)
        var expected = original
        expected.gpu = .apple
        #expect(decoded == expected, "every other key is read as written")
    }

    @Test
    func onlyALinuxGuestThatChoseTheCustomDeviceUsesIt() {
        #expect(machine(.linux, gpu: .custom).usesCustomGPU)
        #expect(!machine(.linux, gpu: .apple).usesCustomGPU)
        #expect(!machine(.macOS, gpu: .custom).usesCustomGPU, "a macOS guest always gets the framework's device")
    }

    @Test
    func aChangeOfDeviceDiscardsTheSavedState() {
        let apple = machine(gpu: .apple)
        let custom = machine(gpu: .custom)
        var renamed = custom
        renamed.name = "other"
        #expect(!custom.restoresSavedState(of: apple))
        #expect(!apple.restoresSavedState(of: custom))
        #expect(apple.restoresSavedState(of: apple))
        #expect(renamed.restoresSavedState(of: custom), "an edit that leaves the device alone does not affect the comparison")
    }

    @Test
    func aChangeOfDeviceOnAMacKeepsTheSavedState() {
        let previous = machine(.macOS, gpu: .apple)
        #expect(machine(.macOS, gpu: .custom).restoresSavedState(of: previous), "a macOS guest never builds the custom device")
    }

    @Test
    func suspendGivesAReasonWhileTheCustomDeviceIsBuilt() throws {
        let reason = try #require(machine(gpu: .custom).customGPUSuspendReason(hostSupports: true))
        #expect(reason == "Suspend is not available with the custom GPU: its state cannot be saved.")
        #expect(machine(gpu: .apple).customGPUSuspendReason(hostSupports: true) == nil)
        #expect(machine(.macOS, gpu: .custom).customGPUSuspendReason(hostSupports: true) == nil)
        #expect(machine(gpu: .custom).customGPUSuspendReason(hostSupports: false) == nil, "a host that cannot build it builds the other")
    }
}

/// What the library does to a machine's memory image when its graphics device changes.
@MainActor
struct CustomGPUSavedStateTests {
    private func addMachine(to library: VMLibrary) throws -> VMConfig {
        let config = VMConfig.new(name: "base", guest: .linux)
        try library.add(config)
        try Data("memory".utf8).write(to: library.bundle(config.id).savedState)
        return config
    }

    @Test
    func choosingTheCustomDeviceDropsTheSavedStateAndAMachineUsingItKeepsNone() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        var config = try addMachine(to: library)
        let bundle = library.bundle(config.id)

        library.update(config)
        #expect(bundle.hasSavedState, "an update that changes nothing keeps the image")

        config.gpu = .custom
        library.update(config)
        #expect(!bundle.hasSavedState)

        try Data("memory".utf8).write(to: bundle.savedState)
        config.name = "renamed"
        library.update(config)
        #expect(!bundle.hasSavedState, "an image found next to a machine that uses the custom device is dropped")

        try Data("memory".utf8).write(to: bundle.savedState)
        config.gpu = .apple
        library.update(config)
        #expect(!bundle.hasSavedState, "an image saved with the other device cannot be restored")
    }
}
