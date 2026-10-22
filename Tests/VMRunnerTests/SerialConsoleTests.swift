import Foundation
import GuestConsole
import Testing

@testable import VMRunner

/// The per-machine switch for the serial console: stored with a tolerant decode, set by the security profiles, listed in the
/// exposure summary, placed on a path a local socket can have, and explained in the help.
struct SerialConsoleTests {
    private func machine(_ guest: GuestOS = .linux, consoleOn: Bool = true) -> VMConfig {
        var config = VMConfig.new(name: "c", guest: guest)
        config.serialConsole = consoleOn
        return config
    }

    // MARK: Stored value

    @Test
    func theConsoleIsOffForANewMachineAndForAConfigWrittenBeforeTheSwitchExisted() throws {
        for guest in GuestOS.allCases { #expect(!VMConfig.new(name: "n", guest: guest).serialConsole) }
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try !VMConfig.decode(from: Data(old.utf8)).serialConsole)
    }

    @Test
    func theSwitchIsStoredAndReadBack() throws {
        let decoded = try VMConfig.decode(from: machine().encoded())
        #expect(decoded.serialConsole)
        #expect(try !VMConfig.decode(from: machine(consoleOn: false).encoded()).serialConsole)
    }

    // MARK: Profiles

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func eachProfileSetsTheConsoleAsItsDefinitionSays(profile: SecurityProfile, guest: GuestOS) {
        let applied = machine(guest).applying(profile)
        let forcedOff = profile == .isolated || profile == .hardened
        #expect(applied.serialConsole == !forcedOff, "\(profile) \(guest)")
        #expect(applied.detectedProfile == profile, "a console that is on must not hide the profile it was applied with")
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func turningTheConsoleBackOnAfterAClosedProfileMakesItCustom(profile: SecurityProfile) {
        var config = machine().applying(profile)
        #expect(!config.serialConsole)
        config.serialConsole = true
        #expect(config.detectedProfile == nil)
    }

    @Test(arguments: [SecurityProfile.standard, .contained])
    func openProfilesKeepTheUsersChoice(profile: SecurityProfile) {
        #expect(machine(consoleOn: true).applying(profile).serialConsole)
        #expect(!machine(consoleOn: false).applying(profile).serialConsole)
    }

    @Test
    func aMacOSGuestHasNoConsoleWhateverTheStoredValueSays() {
        let config = machine(.macOS)
        #expect(!config.posture.serialConsole)
        #expect(config.detectedProfile == .standard, "a stored value on a guest that cannot use it changes nothing")
        #expect(!config.exposures.contains { $0.text.contains("serial console") })
    }

    // MARK: Exposure

    @Test
    func theExposureNamesTheSocketAndRanksItMedium() throws {
        let config = machine()
        let path = VMBundle(id: config.id, in: AppPaths.machines).consoleSocket().path
        let line = try #require(config.exposures.first { $0.text.contains("serial console") })
        #expect(line.text == "A serial console is reachable from this Mac as a local socket at \(path)")
        #expect(line.level == .medium, "any process of this user can type into the guest")
    }

    @Test
    func theExposureIsAbsentWhileTheConsoleIsOffOrAProfileClosedIt() {
        #expect(!machine(consoleOn: false).exposures.contains { $0.text.contains("serial console") })
        for profile in [SecurityProfile.isolated, .hardened] {
            #expect(!machine().applying(profile).exposures.contains { $0.text.contains("serial console") }, "\(profile)")
        }
    }

    // MARK: Socket placement

    private func bundle(id: UUID = UUID(), in machines: String) -> VMBundle {
        VMBundle(id: id, in: URL(filePath: machines, directoryHint: .isDirectory))
    }

    @Test
    func aBundleWhosePathFitsHoldsTheSocketItself() {
        let bundle = bundle(in: "/m")
        let placement = bundle.consoleSocket()
        #expect(placement.path == bundle.url.appending(path: "Console.sock").path)
        #expect(placement.directory == bundle.url.path)
        #expect(placement.path.utf8.count <= ConsoleBridge.socketPathLimit)
    }

    @Test
    func aBundleWhosePathIsTooLongGetsAShortSocketInAPrivateFolderOfTheTemporaryItems() {
        let machines = "/Users/someone/Library/Application Support/VMRunner/Machines"
        let id = UUID(uuidString: "3B873409-1F62-435C-A557-0040D55FBE19") ?? UUID()
        let bundle = bundle(id: id, in: machines)
        #expect(bundle.url.appending(path: "Console.sock").path.utf8.count > ConsoleBridge.socketPathLimit)

        let temporary = URL(filePath: "/var/folders/zz/abcdefghijklmnopqrstuvwxyz012345/T", directoryHint: .isDirectory)
        let placement = bundle.consoleSocket(shortFolder: temporary)
        #expect(placement.directory == "/var/folders/zz/abcdefghijklmnopqrstuvwxyz012345/T/VMRunner-console")
        #expect(placement.path == placement.directory + "/3b873409-1f6.sock")
        #expect(placement.path.utf8.count <= ConsoleBridge.socketPathLimit)
    }

    @Test
    func differentMachinesGetDifferentSocketsAndTheSameMachineAlwaysTheSame() {
        let machines = "/Users/someone/Library/Application Support/VMRunner/Machines"
        let first = bundle(in: machines)
        let second = bundle(in: machines)
        #expect(first.consoleSocket().path != second.consoleSocket().path)
        #expect(first.consoleSocket() == first.consoleSocket())
    }

    // MARK: Help

    @Test
    func theHelpTellsHowToGetALoginOnTheConsoleAndThatMacOSIsNotSupported() {
        let entry = HelpTopic.serialConsole.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for needed in ["console=hvc0", "systemctl enable --now serial-getty@hvc0", "macOS guests", "Isolated and Hardened"] {
            #expect(text.contains(needed), "the topic should say \(needed)")
        }
        #expect(HelpTopic.devices.entry.related.contains(.serialConsole))
        #expect(HelpCatalog.search("serial console").contains(.serialConsole))
    }
}
