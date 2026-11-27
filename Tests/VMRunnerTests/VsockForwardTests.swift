import Foundation
import GuestConsole
import Testing

@testable import VMRunner

/// The per-machine list of forwarded guest vsock ports: stored with a tolerant decode, validated as untrusted data, cleared
/// by the profiles that remove the socket device, listed in the exposure summary, and placed on a path a local socket can
/// have.
struct VsockForwardTests {
    private func machine(forwards: [UInt32] = [22]) -> VMConfig {
        var config = VMConfig.new(name: "v", guest: .linux)
        config.vsockForwards = forwards
        return config
    }

    // MARK: Stored value

    @Test
    func noPortIsForwardedForANewMachineOrAConfigWrittenBeforeTheListExisted() throws {
        for guest in GuestOS.allCases { #expect(VMConfig.new(name: "n", guest: guest).vsockForwards.isEmpty) }
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try VMConfig.decode(from: Data(old.utf8)).vsockForwards.isEmpty)
    }

    @Test
    func theListIsStoredAndReadBack() throws {
        #expect(try VMConfig.decode(from: machine(forwards: [22, 2_222]).encoded()).vsockForwards == [22, 2_222])
    }

    @Test(arguments: [
        [UInt32](repeating: 0, count: 1), [UInt32.max], [22, 22], Array(UInt32(1)...UInt32(EditorLimits.maxVsockForwards + 1)),
    ])
    func aStoredListOutOfRangeIsRefused(forwards: [UInt32]) throws {
        let data = try machine(forwards: forwards).encoded()
        #expect(throws: DecodingError.self) { try VMConfig.decode(from: data) }
    }

    // MARK: Profiles

    @Test(arguments: SecurityProfile.allCases)
    func aProfileThatRemovesTheSocketDeviceRemovesTheForwardsAndTheOthersKeepThem(profile: SecurityProfile) {
        let applied = machine().applying(profile)
        #expect(applied.vsockForwards == (applied.socketDevice ? [22] : []), "\(profile)")
    }

    // MARK: Exposure

    @Test
    func eachForwardedPortIsAnExposureNamingItsSocket() throws {
        let config = machine(forwards: [22, 80])
        let bundle = VMBundle(id: config.id, in: AppPaths.machines)
        for port: UInt32 in [22, 80] {
            let line = try #require(config.exposures.first { $0.text.hasPrefix("Guest vsock port \(port) ") })
            #expect(line.text.hasSuffix(bundle.vsockForward(port: port).path))
            #expect(line.level == .medium, "any process of this user can connect to the guest's port")
        }
        var off = config
        off.socketDevice = false
        #expect(!off.exposures.contains { $0.text.hasPrefix("Guest vsock port") }, "no socket device, nothing is served")
    }

    // MARK: Socket placement

    @Test
    func aBundleWhosePathFitsHoldsTheSocketAndALongOneUsesTheConsolesPrivateShortFolder() {
        let short = VMBundle(id: UUID(), in: URL(filePath: "/m", directoryHint: .isDirectory))
        #expect(short.vsockForward(port: 22).path == short.url.appending(path: "Vsock-22.sock").path)
        #expect(short.vsockForward(port: 22).directory == short.url.path)

        let id = UUID(uuidString: "3B873409-1F62-435C-A557-0040D55FBE19") ?? UUID()
        let machines = URL(filePath: "/Volumes/Scratch/Library/Application Support/VMRunner/Machines", directoryHint: .isDirectory)
        let long = VMBundle(id: id, in: machines)
        let temporary = URL(filePath: "/var/folders/zz/abcdefghijklmnopqrstuvwxyz012345/T", directoryHint: .isDirectory)
        let placement = long.vsockForward(port: 22, shortFolder: temporary)
        #expect(placement.directory == long.consoleSocket(shortFolder: temporary).directory)
        #expect(placement.path == placement.directory + "/3b873409-1f6-vsock-22.sock")
        #expect(placement.path.utf8.count <= ConsoleBridge.socketPathLimit)
        #expect(placement.path != long.consoleSocket(shortFolder: temporary).path)
        #expect(long.vsockForward(port: 80, shortFolder: temporary).path != placement.path)
    }

    // MARK: Help

    @Test
    func theHelpExplainsTheForwardAndHowSSHUsesIt() {
        let entry = HelpTopic.vsock.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for needed in ["vsockForwards", "Vsock-22.sock", "ProxyCommand", "sshd-vsock.socket"] {
            #expect(text.contains(needed), "the topic should say \(needed)")
        }
    }
}
