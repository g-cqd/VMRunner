import Foundation
import NetPolicy
import Testing
import Virtualization

@testable import VMRunner

/// The per-machine host-information switches: stored with a tolerant decode, cleared by the closed profiles, counted in
/// the posture, listed in the exposure summary and explained in the help.
struct HostInfoSharingTests {
    private func machine(_ guest: GuestOS = .linux, sharing: Bool = true) -> VMConfig {
        var config = VMConfig.new(name: "h", guest: guest)
        config.hostInfo.battery = sharing
        config.hostInfo.timeZone = sharing
        return config
    }

    private func isHostInfoLine(_ exposure: Exposure) -> Bool { exposure.text.contains("(read-only share)") }

    @Test func nothingIsSharedForANewMachineOrAConfigWrittenBeforeTheSwitches() throws {
        for guest in GuestOS.allCases { #expect(VMConfig.new(name: "n", guest: guest).hostInfo.isEmpty) }
        let head = #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"#
        #expect(try VMConfig.decode(from: Data((head + #""memoryMiB":2048,"diskGiB":32}"#).utf8)).hostInfo == HostInfoSharing())
        let partial = head + #""memoryMiB":2048,"diskGiB":32,"hostInfo":{"thermal":true}}"#
        let decoded = try VMConfig.decode(from: Data(partial.utf8)).hostInfo
        #expect(decoded.thermal && !decoded.battery, "a key missing from a stored object takes its default")
    }

    @Test func theSwitchesAreStoredAndReadBack() throws {
        let config = machine()
        #expect(try VMConfig.decode(from: config.encoded()).hostInfo == config.hostInfo)
    }

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func eachProfileSetsTheSwitchesAsItsDefinitionSays(profile: SecurityProfile, guest: GuestOS) {
        let applied = machine(guest).applying(profile)
        let cleared = profile == .isolated || profile == .hardened
        #expect(applied.hostInfo.isEmpty == cleared, "\(profile) \(guest)")
        #expect(applied.detectedProfile == profile, "what is shared must not hide the profile it was applied with")
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func sharingAgainAfterAClosedProfileMakesItCustom(profile: SecurityProfile) {
        var config = machine().applying(profile)
        config.hostInfo.thermal = true
        #expect(config.detectedProfile == nil)
    }

    @Test func theSummaryNamesWhatIsSharedAndRanksItLow() throws {
        let line = try #require(machine().exposures.first(where: isHostInfoLine))
        #expect(line.text == "The guest can read this Mac's battery level, time zone (read-only share).")
        #expect(line.level == .low)
        #expect(!machine(sharing: false).exposures.contains(where: isHostInfoLine))
    }

    @Test func theHelpSaysHowToReadItAndWhoTurnsItOff() {
        let entry = HelpTopic.hostInformation.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for phrase in ["read-only", "mount -t virtiofs", "mount_virtiofs", "Isolated and Hardened", "percent="] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(SecurityProfile.isolated.summary.contains("host information"))
    }
}

/// The share: none when nothing is shared; otherwise read-only, under its tag, over a folder made fresh and private, and
/// never over the target of a link planted where the folder goes.
struct HostInfoShareTests {
    @Test func aMachineThatSharesNothingGetsNoShareAndNoFolder() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        #expect(try ConfigurationBuilder.hostInfoShare(for: VMConfig.new(name: "x", guest: .linux), bundle: bundle) == nil)
        #expect(!FileManager.default.fileExists(atPath: bundle.hostInfoFolder.path))
    }

    @Test func theShareIsReadOnlyUnderItsTagOverAFreshPrivateFolder() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        var config = VMConfig.new(name: "x", guest: .linux)
        config.hostInfo.timeZone = true
        try FileManager.default.createDirectory(at: bundle.hostInfoFolder, withIntermediateDirectories: true)
        try Data("planted".utf8).write(to: bundle.hostInfoFolder.appending(path: "battery"))

        let device = try #require(try ConfigurationBuilder.hostInfoShare(for: config, bundle: bundle))
        #expect(device.tag == ConfigurationBuilder.hostInfoTag)
        try VZVirtioFileSystemDeviceConfiguration.validateTag(ConfigurationBuilder.hostInfoTag)
        let share = try #require(device.share as? VZSingleDirectoryShare)
        #expect(share.directory.isReadOnly)
        #expect(share.directory.url.resolvingSymlinksInPath().path == bundle.hostInfoFolder.resolvingSymlinksInPath().path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.hostInfoFolder.path).isEmpty, "what was there is gone")
        #expect(try AppPaths.verifyPrivateDirectory(bundle.hostInfoFolder))
    }

    @Test func aLinkPlantedWhereTheFolderGoesIsReplacedAndItsTargetKept() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = directory.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: elsewhere.appending(path: "secret"))
        let bundle = VMBundle(url: directory.appending(path: "m.vm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.hostInfoFolder, withDestinationURL: elsewhere)
        var config = VMConfig.new(name: "x", guest: .linux)
        config.hostInfo.battery = true

        _ = try ConfigurationBuilder.hostInfoShare(for: config, bundle: bundle)
        #expect(try AppPaths.verifyPrivateDirectory(bundle.hostInfoFolder), "a real private folder, not the link")
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "secret").path), "the link's target is untouched")
    }

    @Test(.disabled(if: geteuid() == 0, "mode 0555 does not stop root from emptying a folder"))
    func aFolderThatCannotBeEmptiedIsRefused() throws {
        let directory = try scratchDirectory()
        let bundle = VMBundle(url: directory)
        let stuck = bundle.hostInfoFolder.appending(path: "stale", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data("forged".utf8).write(to: stuck.appending(path: "battery"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck.path)
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(throws: AppPaths.UnsafeDirectory.self) { try bundle.freshHostInfoFolder() }
    }

    @Test func theFolderGoesWithTheOtherFilesOfARunWhenTheMachineStops() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        let folder = try bundle.freshHostInfoFolder()
        try Data("percent=80\n".utf8).write(to: folder.appending(path: "battery"))
        bundle.discardEphemeral()  // what `VMController.release()` runs at every stop
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the last facts do not travel with a copied bundle")
    }

    @Test func theHelpNamesTheTag() {
        #expect(HelpTopic.hostInformation.entry.paragraphs.joined(separator: " ").contains(ConfigurationBuilder.hostInfoTag))
    }
}

/// The files the share holds: one per category that is on, `key=value` lines, and `none` or `unknown` for what is not known.
struct HostFactsTests {
    private let facts = HostFacts(
        batteryPercent: 82, powerSource: .battery, lowPowerMode: true, thermal: .serious,
        network: HostNetworkPath(vpn: .inactive, isExpensive: true, isConstrained: false, isSatisfied: true, interface: .wifi),
        timeZone: "Europe/Paris")
    private let everything = HostInfoSharing(battery: true, power: true, thermal: true, networkPath: true, timeZone: true)

    @Test func eachCategoryThatIsOnHasItsFileAndNoOtherHasOne() {
        var sharing = HostInfoSharing()
        #expect(facts.files(for: sharing).isEmpty)
        sharing.battery = true
        sharing.timeZone = true
        #expect(facts.files(for: sharing) == ["battery": "percent=82\n", "timezone": "identifier=Europe/Paris\n"])
    }

    @Test func everyFileReadsAsKeyValueLines() {
        let files = facts.files(for: everything)
        #expect(Set(files.keys) == Set(HostFacts.fileNames))
        #expect(files["power"] == "source=battery\nlowPowerMode=1\n")
        #expect(files["thermal"] == "state=serious\n")
        #expect(files["network"] == "status=satisfied\ninterface=wifi\nexpensive=1\nconstrained=0\n")
    }

    @Test func whatIsNotKnownSaysNoneOrUnknown() {
        let files = HostFacts().files(for: everything)
        #expect(files["battery"] == "percent=none\n")
        #expect(files["power"] == "source=unknown\nlowPowerMode=0\n")
        #expect(files["network"] == "status=unknown\n")
    }

    @Test func theMacsOwnFactsNameItsTimeZone() {
        let current = HostFacts.current(network: nil)
        #expect(current.timeZone == TimeZone.current.identifier)
        #expect(current.network == nil)
    }
}

/// The battery as this Mac reports it. A Mac without a battery (a desktop, a hosted runner) has no percentage; one with a
/// battery reports one from 0 to 100.
struct HostPowerTests {
    @Test func aBatteryReadsAsAPercentage() {
        let facts = HostFacts.current(network: nil)
        if let percent = facts.batteryPercent { #expect((0...100).contains(percent)) }
        #expect(HostFacts.PowerSource(rawValue: facts.powerSource.rawValue) != nil)
    }
}
