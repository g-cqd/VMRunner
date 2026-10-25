import Foundation
import PrivateInterfaces
import Testing
import Virtualization

@testable import VMRunner

/// Windows as a guest of its own: how a stored value reads, what a new machine starts with, which settings it refuses, and the
/// answer each place that tells guests apart gives for it. Nothing here builds a running machine.
struct WindowsGuestTests {
    private func decode(_ json: String) throws -> VMConfig { try VMConfig.decode(from: Data(json.utf8)) }

    private func windows(hostCPUs: Int = 16, hostMemoryGiB: Int = 64) -> VMConfig {
        VMConfig.new(name: "w", guest: .windows, hostCPUs: hostCPUs, hostMemoryGiB: hostMemoryGiB)
    }

    // MARK: Reading a stored guest

    @Test(arguments: [("macOS", GuestOS.macOS), ("linux", .linux), ("windows", .windows)])
    func eachStoredGuestReadsAsItself(stored: String, guest: GuestOS) throws {
        #expect(try decode(#"{"guest":"\#(stored)"}"#).guest == guest)
        #expect(GuestOS(rawValue: stored) == guest)
    }

    @Test func aWindowsMachineSurvivesBeingWrittenAndRead() throws {
        let config = windows()
        #expect(try VMConfig.decode(from: config.encoded()) == config)
    }

    @Test func aGuestThisVersionDoesNotKnowIsRefusedAndAConfigWithoutTheKeyIsLinux() throws {
        #expect(throws: DecodingError.self) { try decode(#"{"guest":"beos"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"guest":7}"#) }
        let without = try decode(#"{"name":"old","cpuCount":2}"#)
        #expect(without.guest == .linux)
        #expect(without.diskInterface == VMConfig.new(name: "", guest: .linux).diskInterface)
    }

    @MainActor
    @Test func theLibrarySkipsAMachineOfAnUnknownGuestAndKeepsTheOthers() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        try library.add(VMConfig.new(name: "linux one", guest: .linux))
        try library.add(VMConfig.new(name: "windows one", guest: .windows))
        let unknown = UUID()
        let folder = directory.appending(path: "\(unknown.uuidString).vm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(unknown.uuidString)","name":"future","guest":"beos"}"#.utf8).write(to: folder.appending(path: "config.json"))

        let fresh = VMLibrary(machinesDirectory: directory)
        fresh.load()

        #expect(fresh.machines.map(\.name) == ["linux one", "windows one"])
        #expect(fresh.machines.map(\.guest) == [.linux, .windows])
    }

    // MARK: Defaults

    @Test func aNewWindowsMachineStartsWithTheWindowsPreset() throws {
        let config = windows()
        #expect(config.cpuCount == 4 && config.memoryMiB == 8192 && config.diskGiB == 64)
        #expect(config.diskInterface == .nvme && config.networkMode == .nat)
        #expect(config.displayWidth == 1920 && config.displayHeight == 1200)
        #expect(config.gpu == .apple && config.pointingDevice == .mouse)
        #expect(!config.audioOutput && !config.audioInput && !config.serialConsole && !config.rosetta)
        #expect(!config.secureBoot && !config.sharesClipboard && !config.nestedVirtualization)
        #expect(config.provisioningSpecPath.isEmpty && !config.provisioning.enabled)
        #expect(config.installerISO == nil && config.workload == .vm && config.container == nil)
        try config.validate()
    }

    @Test func aSmallHostGivesWindowsLessAndNeverLessThanTheFloor() {
        let small = windows(hostCPUs: 4, hostMemoryGiB: 8)
        #expect(small.cpuCount == 2 && small.memoryMiB == 4096)
        let tiny = windows(hostCPUs: 1, hostMemoryGiB: 2)
        #expect(tiny.cpuCount == 2 && tiny.memoryMiB == 2048)
    }

    @Test func theOtherGuestsKeepTheDefaultsTheyHad() {
        let mac = VMConfig.new(name: "m", guest: .macOS, hostCPUs: 16, hostMemoryGiB: 64)
        #expect(mac.cpuCount == 4 && mac.memoryMiB == 8192 && mac.diskGiB == 100 && mac.pointingDevice == .trackpad)
        #expect(mac.displayWidth == 1920 && mac.diskInterface == .virtio && mac.audioOutput && mac.sharesClipboard)
        let linux = VMConfig.new(name: "l", guest: .linux, hostCPUs: 16, hostMemoryGiB: 64)
        #expect(linux.cpuCount == 4 && linux.memoryMiB == 4096 && linux.diskGiB == 64 && linux.pointingDevice == .mouse)
        #expect(linux.displayWidth == 1280 && linux.displayHeight == 800 && linux.diskInterface == .virtio && linux.audioOutput)
    }

    @Test func eachGuestsNewDiskIsInsideItsOwnRange() {
        #expect(EditorLimits.newDiskGiB(for: .macOS).lowerBound == 40)
        #expect(EditorLimits.newDiskGiB(for: .linux).lowerBound == 16)
        #expect(EditorLimits.newDiskGiB(for: .windows) == 64...2048)
        for guest in GuestOS.allCases {
            #expect(EditorLimits.newDiskGiB(for: guest).contains(VMConfig.new(name: "n", guest: guest).diskGiB), "\(guest)")
        }
    }

    // MARK: What a Windows machine refuses

    @Test func aWindowsMachineWithEachLinuxOnlyFeatureOnIsRefusedWhileALinuxMachineKeepsIt() throws {
        let features: [(key: String, turnOn: (inout VMConfig) -> Void)] = [
            ("gpu", { $0.gpu = .custom }),
            ("rosetta", { $0.rosetta = true }),
            ("nestedVirtualization", { $0.nestedVirtualization = true }),
            ("serialConsole", { $0.serialConsole = true }),
            ("secureBoot", { $0.secureBoot = true }),
            ("provisioningSpecPath", { $0.provisioningSpecPath = "/tmp/spec.json" }),
        ]
        for (key, turnOn) in features {
            var refused = windows()
            turnOn(&refused)
            do {
                _ = try VMConfig.decode(from: refused.encoded())
                Issue.record("\(key) was accepted for a Windows machine")
            } catch DecodingError.dataCorrupted(let context) {
                #expect(context.debugDescription == "\(key) is not available for a Windows machine")
            }
            var kept = VMConfig.new(name: "l", guest: .linux)
            turnOn(&kept)
            #expect(try VMConfig.decode(from: kept.encoded()).guest == .linux, "\(key)")
        }
    }

    @Test func aWindowsMachineMayShareFoldersAndTheStandardProfileMayTurnTheClipboardSettingOn() throws {
        var config = windows()
        config.sharedFolders = [SharedFolder(path: "/tmp/f")]
        #expect(try VMConfig.decode(from: config.encoded()).sharedFolders.count == 1)
        for profile in SecurityProfile.allCases {
            _ = try VMConfig.decode(from: windows().applying(profile).encoded())
        }
    }

    // MARK: Each place that tells guests apart

    @Test func eachGuestHasItsNameAndSymbol() {
        #expect(GuestOS.allCases.map(\.label) == ["macOS", "Linux", "Windows"])
        #expect(GuestOS.allCases.map(\.symbol) == ["apple.logo", "terminal", "pc"])
    }

    @Test func theNewMachineSheetDoesNotOfferWindows() {
        #expect(GuestOS.newMachineChoices == [.macOS, .linux])
        #expect(GuestOS.allCases.contains(.windows))
    }

    @Test func linuxAndWindowsShareTheGenericPlatformAndMacOSHasItsOwn() {
        #expect(GuestOS.allCases.filter(\.usesGenericPlatform) == [.linux, .windows])
    }

    @Test func aWindowsInstallerAttachesAsAReadOnlyUSBDriveJustAsALinuxOneDoes() {
        for guest in GuestOS.allCases {
            var config = VMConfig.new(name: "i", guest: guest)
            config.installerISO = "/tmp/install.iso"
            #expect((config.attachedInstallerPath != nil) == (guest != .macOS), "\(guest)")
            config.installerAttached = false
            #expect(config.attachedInstallerPath == nil, "\(guest)")
        }
    }

    @Test func aWindowsMachineNamesItsPrivateInterfaceAndNeverClaimsASuspendedMemorySnapshot() {
        let config = windows()
        #expect(config.allowsSuspend)
        #expect(config.privateCapabilities == [.performanceMonitoringEmulation])
        let lines = config.exposures.map(\.text)
        #expect(lines.contains { $0.hasPrefix("Private interface: performance-monitoring emulation.") })
        #expect(!lines.contains { $0.hasPrefix("Suspending writes") })
        #expect(lines.contains("No memory snapshot is written to disk."))
        #expect(VMConfig.new(name: "l", guest: .linux).exposures.map(\.text).contains { $0.hasPrefix("Suspending writes") })
    }

    @Test func aWindowsMachineHasNoSeedWhateverTheSpecPathSays() {
        var config = windows()
        config.provisioningSpecPath = "/tmp/spec.json"
        #expect(config.activeProvisioningSpecPath == nil)
    }

    @Test func onlyAWindowsMachineSaysItCannotBeSuspendedBecauseOfItsGuest() {
        #expect(windows().guestSuspendReason == "Suspend is not available for Windows machines.")
        #expect(VMConfig.new(name: "m", guest: .macOS).guestSuspendReason == nil)
        #expect(VMConfig.new(name: "l", guest: .linux).guestSuspendReason == nil)
    }

    @Test func aWindowsMachineAsksForTheNVMeDiskAndAMacNeverGetsOne() {
        #expect(windows().usesNVMeMainDisk)
        var other = windows()
        other.diskInterface = .virtio
        #expect(!other.usesNVMeMainDisk)
        var mac = VMConfig.new(name: "m", guest: .macOS)
        mac.diskInterface = .nvme
        #expect(!mac.usesNVMeMainDisk)
    }

    @Test func theBuilderRefusesAWindowsMachineWithAnErrorThatNamesTheGuest() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try ConfigurationBuilder.build(windows(), bundle: VMBundle(url: directory))
            Issue.record("a Windows machine was built")
        } catch SetupError.unsupportedGuest(let guest) {
            #expect(guest == .windows)
            #expect(SetupError.unsupportedGuest(guest).errorDescription == "This version of VMRunner can't start Windows machines.")
        }
    }

    @Test func aWindowsMachinesStorageIsAnNVMeDiskThenItsInstallerOnUSB() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data(count: 1 << 20).write(to: bundle.disk)
        let iso = directory.appending(path: "windows.iso")
        try Data(count: 1 << 20).write(to: iso)
        var config = windows()
        config.installerISO = iso.path

        let devices = try ConfigurationBuilder.storage(for: config, bundle: bundle)

        #expect(devices.count == 2)
        #expect(devices.first is VZNVMExpressControllerDeviceConfiguration)
        #expect(devices.last is VZUSBMassStorageDeviceConfiguration)
    }

    @Test func aWindowsMachineKeepsItsFirmwareStateInTheEFIVariablesAndClonesThemForADisposableRun() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("disk".utf8).write(to: bundle.disk)
        try Data("efi".utf8).write(to: bundle.efiVariables)

        #expect(bundle.stateFile(for: .windows) == bundle.efiVariables)
        try bundle.prepareEphemeral(guest: .windows)

        #expect(try String(contentsOf: bundle.ephemeralEFIVariables, encoding: .utf8) == "efi")
        #expect(!FileManager.default.fileExists(atPath: bundle.ephemeralAuxiliaryStorage.path))
    }

    @Test func aWindowsDisplayIsNotCappedAtTheLinuxWidthAndFallsBackToItsOwnDefaultSize() {
        let retinaWindow = CGSize(width: 1800, height: 1100)
        let size = StartDisplay.size(for: windows(), window: retinaWindow, restoring: false)
        #expect(size.width == 1800 && size.height == 1100, "\(size)")

        for (guest, expected) in [(GuestOS.macOS, (1920, 1200)), (.linux, (1280, 800)), (.windows, (1920, 1200))] {
            var config = VMConfig.new(name: "d", guest: guest)
            config.displayWidth = 0
            let size = StartDisplay.size(for: config, window: nil, restoring: false)
            #expect(size.width == expected.0 && size.height == expected.1, "\(guest)")
        }
    }
}

/// The parts that live on the main actor: the display settings of a running machine and the New Machine model.
@MainActor
struct WindowsGuestModelTests {
    private func settings(_ guest: GuestOS, started: ContinuousClock.Instant? = nil) -> MachineModel.DisplaySettings {
        MachineModel.DisplaySettings(capturesSystemKeys: true, followsWindow: true, guest: guest, scale: 1, firmwareStartedAt: started)
    }

    @Test func aWindowsGuestIsResizedByTheAppAndHeldForTheFirmwareLikeLinux() {
        let start = ContinuousClock.now
        #expect(settings(.windows).resizer == .app)
        #expect(settings(.windows, started: start).firmwareHoldRemaining(at: start) == DisplayFollower.firmwareHold)
        #expect(settings(.windows, started: nil).firmwareHoldRemaining(at: start) == .zero)
    }

    @Test func theNewMachineModelCannotCreateAWindowsMachineAndNamesItLikeTheOthers() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)

        model.guestChanged(to: .windows)

        #expect(model.config.guest == .windows && model.config.name == "Windows")
        #expect(!model.canCreate)
        #expect(model.makeConfig().source == nil)
        model.guestChanged(to: .linux)
        #expect(model.config.name == "Linux")
        #expect(model.config.guest == .linux)
    }
}
