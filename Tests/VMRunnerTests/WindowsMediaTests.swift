import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// Stores what a setup saves and approves, in a folder of its own.
@MainActor
private final class SetupStore: MachineStore {
    let directory: URL
    private(set) var updates: [VMConfig] = []
    private(set) var grants: [HostPathGrant] = []

    init(directory: URL) { self.directory = directory }

    func bundle(_ id: UUID) -> VMBundle { VMBundle(url: directory.appending(path: "\(id.uuidString).vm", directoryHint: .isDirectory)) }
    func update(_ config: VMConfig) { updates.append(config) }
    func approveHostPaths(_ grants: [HostPathGrant], for id: UUID) { self.grants += grants }
}

/// The media a Windows machine boots and installs from: the driver disc beside the installer, and the setup that leaves a
/// machine ready to boot an installer image.
struct WindowsMediaTests {
    private func windows() -> VMConfig { VMConfig.new(name: "w", guest: .windows, hostCPUs: 16, hostMemoryGiB: 64) }

    private func decodeFailure(_ config: VMConfig) throws -> String? {
        do {
            _ = try VMConfig.decode(from: config.encoded())
            return nil
        } catch DecodingError.dataCorrupted(let context) {
            return context.debugDescription
        }
    }

    // MARK: The driver disc as a setting

    @Test func aStoredDriverDiscReadsBackAndAConfigWithoutOneHasNone() throws {
        var config = windows()
        config.driverDiscPath = "/Users/me/drivers.iso"
        #expect(try VMConfig.decode(from: config.encoded()).driverDiscPath == "/Users/me/drivers.iso")
        #expect(try VMConfig.decode(from: Data(#"{"guest":"windows"}"#.utf8)).driverDiscPath == nil)
        #expect(windows().driverDiscPath == nil)
    }

    @Test func aDriverDiscMustBeAnAbsolutePathOutsideTheMachinesFolder() throws {
        var config = windows()
        config.driverDiscPath = "drivers.iso"
        #expect(try decodeFailure(config) == "driverDiscPath must name absolute paths")
        config.driverDiscPath = AppPaths.machines.appending(path: "drivers.iso").path
        #expect(try decodeFailure(config) == "driverDiscPath must not name a file inside the Machines folder")
        config.driverDiscPath = "/Users/me/drivers.iso"
        #expect(try decodeFailure(config) == nil)
    }

    @Test func nestedVirtualizationIsAcceptedForAWindowsMachineAndOffByDefault() throws {
        #expect(!windows().nestedVirtualization)
        var config = windows()
        config.nestedVirtualization = true
        #expect(try decodeFailure(config) == nil)
    }

    // MARK: Approval and exposure

    @Test func aDriverDiscIsAReadOnlyGrantOfItsOwnKindAndOnlyForWindows() {
        var config = windows()
        config.driverDiscPath = "/Users/me/drivers.iso"
        let grant = HostPathGrant(.driverDisc, "/Users/me/drivers.iso", writable: false)
        #expect(config.hostGrants == [grant])
        #expect(grant.summary == "/Users/me/drivers.iso (driver disc, read-only)")
        #expect(!HostPathGrant(.installer, "/Users/me/drivers.iso", writable: false).covers(grant), "an installer grant is not it")

        config.guest = .linux
        #expect(config.hostGrants.isEmpty)
    }

    @Test func theExposureSummaryNamesTheDriverDisc() {
        var config = windows()
        #expect(!config.exposures.contains { $0.text.contains("driver disc") })
        config.driverDiscPath = "/Users/me/drivers.iso"
        #expect(config.exposures.contains { $0.text == "The guest can read the driver disc /Users/me/drivers.iso (attached read-only)." })
    }

    @Test func nestedVirtualizationIsListedForAWindowsMachineThatUsesIt() {
        var config = windows()
        config.nestedVirtualization = true
        #expect(config.exposures.contains { $0.text.hasPrefix("Nested virtualization:") })
        #expect(config.posture.nested)
    }

    @Test func aProfileThatClosesTheInstallerClosesTheDriverDiscToo() {
        var config = windows()
        config.driverDiscPath = "/Users/me/drivers.iso"

        let isolated = config.applying(.isolated)

        #expect(isolated.driverDiscPath == nil)
        #expect(isolated.detectedProfile == .isolated)
        var reattached = isolated
        reattached.driverDiscPath = "/Users/me/drivers.iso"
        #expect(reattached.detectedProfile == nil, "a re-attached driver disc must not read as Isolated")
        #expect(config.applying(.contained).driverDiscPath == "/Users/me/drivers.iso")
    }

    // MARK: Setup

    @MainActor
    @Test func aWindowsMachineIsSetUpLikeAnISOInstallWithItsOwnFirmwareVariablesAndIdentifier() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let iso = directory.appending(path: "windows.iso")
        try Data(count: 1 << 20).write(to: iso)
        var config = windows()
        config.source = .local(iso.path)
        config.diskGiB = 1
        let store = SetupStore(directory: directory)

        try await Provisioner.run(config: config, library: store, job: SetupJob())

        let bundle = store.bundle(config.id)
        #expect(FileManager.default.fileExists(atPath: bundle.disk.path))
        #expect(FileManager.default.fileExists(atPath: bundle.efiVariables.path))
        let identifier = try Data(contentsOf: bundle.machineIdentifier)
        #expect(VZGenericMachineIdentifier(dataRepresentation: identifier) != nil)
        let saved = try #require(store.updates.last)
        #expect(saved.isProvisioned && saved.installerISO == iso.path && saved.installerAttached)
    }
}
