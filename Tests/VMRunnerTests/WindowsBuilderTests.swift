import Foundation
import PrivateInterfaces
import Synchronization
import Testing
import Virtualization

@testable import VMRunner

/// Counts how many times a start asked for the performance-monitoring emulation.
private final class Applications: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    var wasAsked: Bool { calls.withLock { $0 > 0 } }
    func record() { calls.withLock { $0 += 1 } }
}

/// A lookup that finds nothing, so a capability reads as unavailable without any Objective-C runtime being asked.
private struct EmptyResolver: MethodResolver {
    func lookup(className: String, selector: String) -> MethodLookup { .classMissing }
}

/// The devices a Windows machine is built with, and what its start decides about the private interface. Each test assembles a
/// configuration, which opens the image files and stops short of the framework's validation (that needs the virtualization
/// entitlement, which a test run does not hold); none starts a machine, and the emulation is stood in for by a closure, so the
/// private switch is never called.
struct WindowsBuilderTests {
    private func windows() -> VMConfig { VMConfig.new(name: "w", guest: .windows, hostCPUs: 16, hostMemoryGiB: 64) }

    /// What the creation of a Windows machine leaves in its folder: the disk, the firmware variables and the identifier.
    private func makeBundle(in directory: URL) throws -> VMBundle {
        let bundle = VMBundle(url: directory)
        try Data(count: 1 << 20).write(to: bundle.disk)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables, options: [.allowOverwrite])
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    private func image(named name: String, in directory: URL) throws -> String {
        let url = directory.appending(path: name)
        try Data(count: 1 << 20).write(to: url)
        return url.path
    }

    private func settings(
        _ decision: PrivateCapabilityPolicy.Decision = .allowed, emulation: PrivateCapabilityStatus = .available,
        startsWithout: Bool = false, applications: Applications = Applications()
    ) -> WindowsStartSettings {
        WindowsStartSettings(
            decision: decision,
            applyPerformanceMonitoring: { _ in
                applications.record()
                return emulation
            },
            startsWithoutPerformanceMonitoring: startsWithout)
    }

    private func assemble(_ config: VMConfig, in directory: URL, _ settings: WindowsStartSettings) throws -> ConfigurationBuilder.Built {
        try ConfigurationBuilder.assemble(config, bundle: makeBundle(in: directory), windows: settings)
    }

    private func readOnly(_ device: VZStorageDeviceConfiguration) -> Bool {
        (device.attachment as? VZDiskImageStorageDeviceAttachment)?.isReadOnly ?? false
    }

    // MARK: The devices

    @Test func aWindowsMachineIsBuiltFromTheGenericPlatformWithNVMeUSBInputAndVirtioNetwork() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = windows()
        config.installerISO = try image(named: "windows.iso", in: directory)
        config.driverDiscPath = try image(named: "drivers.iso", in: directory)
        let applications = Applications()

        let built = try assemble(config, in: directory, settings(applications: applications))
        let vz = built.configuration

        #expect(applications.count == 1)
        let platform = try #require(vz.platform as? VZGenericPlatformConfiguration)
        #expect(!platform.isNestedVirtualizationEnabled)
        #expect(vz.bootLoader is VZEFIBootLoader)
        #expect(vz.storageDevices.count == 3)
        #expect(vz.storageDevices.first is VZNVMExpressControllerDeviceConfiguration)
        #expect(vz.storageDevices.dropFirst().allSatisfy { $0 is VZUSBMassStorageDeviceConfiguration })
        #expect(vz.storageDevices.dropFirst().allSatisfy { readOnly($0) })
        #expect(vz.keyboards.count == 1 && vz.keyboards.first is VZUSBKeyboardConfiguration)
        #expect(vz.pointingDevices.count == 1 && vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        #expect(vz.networkDevices.count == 1 && vz.networkDevices.first is VZVirtioNetworkDeviceConfiguration)
        #expect(vz.networkDevices.first?.attachment is VZNATNetworkDeviceAttachment)
        let graphics = try #require(vz.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        #expect(graphics.scanouts.map(\.widthInPixels) == [1920] && graphics.scanouts.map(\.heightInPixels) == [1200])
        #expect(vz.audioDevices.isEmpty, "sound is off by default for Windows")
        #expect(built.networkStack == nil)
    }

    @Test func soundFollowsTheSetting() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = windows()
        config.audioOutput = true

        #expect(try assemble(config, in: directory, settings()).configuration.audioDevices.count == 1)
    }

    @Test func aWindowsMachineGetsNoConsoleSeedRosettaOrClipboardPortEvenForAConfigurationThatAsksForThem() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = windows()
        config.serialConsole = true
        config.rosetta = true
        config.sharesClipboard = true
        config.provisioningSpecPath = "/Users/me/machine.yaml"

        let built = try assemble(config, in: directory, settings())

        #expect(built.consoleBridge == nil)
        #expect(built.configuration.serialPorts.isEmpty && built.configuration.consoleDevices.isEmpty)
        #expect(built.configuration.directorySharingDevices.isEmpty)
        #expect(built.configuration.storageDevices.count == 1, "the disk alone: no seed")
    }

    @Test func nestedVirtualizationIsOnForAWindowsMachineThatAsksForItWhereTheHostCanDoIt() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = windows()
        config.nestedVirtualization = true

        if VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
            let platform = try assemble(config, in: directory, settings()).configuration.platform
            #expect((platform as? VZGenericPlatformConfiguration)?.isNestedVirtualizationEnabled == true)
        } else {
            #expect(throws: SetupError.self) { try assemble(config, in: directory, settings()) }
        }
    }

    // MARK: The driver disc

    @Test func aDriverDiscThatIsMissingOrInsideTheMachinesFolderStopsTheStart() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = windows()
        config.driverDiscPath = directory.appending(path: "gone.iso").path
        #expect(throws: SetupError.self) { try assemble(config, in: directory, settings()) }

        config.driverDiscPath = AppPaths.machines.appending(path: "drivers.iso").path
        #expect(throws: HostPathError.self) { try assemble(config, in: directory, settings()) }
    }

    @Test func onlyAWindowsMachineAttachesADriverDisc() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try image(named: "drivers.iso", in: directory)
        for guest in GuestOS.allCases {
            var config = VMConfig.new(name: "d", guest: guest)
            config.driverDiscPath = path
            #expect((config.attachedDriverDiscPath != nil) == (guest == .windows), "\(guest)")
            let device = try ConfigurationBuilder.driverDisc(for: config)
            #expect((device != nil) == (guest == .windows), "\(guest)")
        }
    }

    // MARK: The performance-monitoring emulation

    @Test func theEmulationIsTurnedOnOnceWhenThePolicyAllowsItAndItIsAvailable() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = Applications()

        _ = try assemble(windows(), in: directory, settings(.allowed, emulation: .available, applications: applications))

        #expect(applications.count == 1)
    }

    @Test(arguments: [
        PrivateCapabilityPolicy.Reason.managedKey, .profile(.hardened), .profile(.isolated), .killSwitch,
    ])
    func aMachineTheOrganisationOrItsProfileClosesDoesNotStartAndTheEmulationIsNotAsked(reason: PrivateCapabilityPolicy.Reason) throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = Applications()

        do {
            _ = try assemble(windows(), in: directory, settings(.denied(reason), applications: applications))
            Issue.record("a closed Windows machine was built")
        } catch SetupError.requiredCapabilityUnavailable(let guest, let capability, let text) {
            #expect(guest == .windows && capability == "performance-monitoring emulation" && text == reason.description)
            let message = SetupError.requiredCapabilityUnavailable(guest: guest, capability: capability, reason: text).errorDescription
            #expect(message == "Windows needs the performance-monitoring emulation, which is unavailable: \(reason.description).")
        }
        #expect(!applications.wasAsked)
    }

    @Test func anUnavailableEmulationStopsTheStartWithThePlainReason() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reason = PrivateCapabilityReason.osBuildOutsideRange(build: "27A1", verified: "26A0 to 26Z99999")

        do {
            _ = try assemble(windows(), in: directory, settings(emulation: .unavailable(reason)))
            Issue.record("a Windows machine without the emulation was built")
        } catch let error as SetupError {
            #expect(
                error.errorDescription
                    == "Windows needs the performance-monitoring emulation, which is unavailable: \(reason.description).")
        }
    }

    @Test func aRuntimeThatLacksTheSwitchStopsTheStartThroughTheCapabilityModule() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let context = PrivateCapabilityContext(osBuild: "26A434", killed: [], resolver: EmptyResolver())
        let real = WindowsStartSettings.current(
            for: windows(), managed: ManagedPreferences(forcedValue: { _ in nil }), defaults: scratch.defaults, context: context)

        #expect(real.decision == .allowed)
        do {
            _ = try assemble(windows(), in: directory, real)
            Issue.record("a Windows machine without the emulation was built")
        } catch let error as SetupError {
            let missing = PrivateCapabilityReason.classMissing("VZGenericPlatformConfiguration")
            #expect(error.errorDescription == "Windows needs the performance-monitoring emulation, which is unavailable: \(missing).")
        }
    }

    @Test func theDeveloperDefaultStartsTheMachineWithoutTheEmulationWhateverKeepsItOff() throws {
        let denied: [PrivateCapabilityPolicy.Decision] = [.denied(.managedKey), .denied(.profile(.hardened)), .denied(.killSwitch)]
        for decision in denied {
            let directory = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let applications = Applications()
            _ = try assemble(windows(), in: directory, settings(decision, startsWithout: true, applications: applications))
            #expect(!applications.wasAsked, "\(decision)")
        }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailable = PrivateCapabilityStatus.unavailable(.killSwitch)
        _ = try assemble(windows(), in: directory, settings(emulation: unavailable, startsWithout: true))
    }

    @Test func theDeveloperDefaultDoesNotTurnOffAnEmulationThatCanBeUsed() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = Applications()

        _ = try assemble(windows(), in: directory, settings(startsWithout: true, applications: applications))

        #expect(applications.count == 1)
    }

    // MARK: What a start reads

    @Test func theStartReadsThePolicyTheKillSwitchAndTheDeveloperDefaultFromTheDomainItIsGiven() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let open = ManagedPreferences(forcedValue: { _ in nil })
        let locked = ManagedPreferences(forcedValue: { $0 == "AllowPrivateInterfaces" ? false : nil })
        let context = PrivateCapabilityContext(osBuild: "26A434", killed: [], resolver: EmptyResolver())
        func read(_ config: VMConfig, _ managed: ManagedPreferences) -> WindowsStartSettings {
            WindowsStartSettings.current(for: config, managed: managed, defaults: scratch.defaults, context: context)
        }

        #expect(read(windows(), open).decision == .allowed)
        #expect(!read(windows(), open).startsWithoutPerformanceMonitoring)
        #expect(read(windows(), locked).decision == .denied(.managedKey))
        #expect(read(windows().applying(.hardened), open).decision == .denied(.profile(.hardened)))
        scratch.defaults.set(true, forKey: PrivateInterfacesKillSwitch.defaultsKey)
        #expect(read(windows(), open).decision == .denied(.killSwitch))
        scratch.defaults.set(true, forKey: WindowsStartsWithoutPMU.defaultsKey)
        #expect(read(windows(), open).startsWithoutPerformanceMonitoring)
    }

    @Test func onlyAnExplicitTrueTurnsTheDeveloperDefaultOn() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        #expect(WindowsStartsWithoutPMU.defaultsKey == "WindowsStartsWithoutPMU")
        #expect(!WindowsStartsWithoutPMU.isOn(in: scratch.defaults), "nothing stored")
        for (value, expected) in [(true, true), (false, false)] {
            scratch.defaults.set(value, forKey: WindowsStartsWithoutPMU.defaultsKey)
            #expect(WindowsStartsWithoutPMU.isOn(in: scratch.defaults) == expected, "\(value)")
        }
        for value in ["yes", "true", "2"] as [Any] {
            scratch.defaults.set(value, forKey: WindowsStartsWithoutPMU.defaultsKey)
            #expect(!WindowsStartsWithoutPMU.isOn(in: scratch.defaults), "\(value)")
        }
    }
}
