import Foundation
import SwiftUI
import Testing

@testable import VMRunner

/// The length and count bounds of a stored configuration: one past each is refused where the file is read, one at each loads,
/// and the editor cannot produce what the reader refuses.
struct ConfigBoundsTests {
    /// A value of a configuration that has a bound, and how to put it at the bound or one past it.
    enum Bound: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case name, fullName, username, guestVersion, macAddress
        case sharedFolderCount, extraDiskCount
        case sharedFolderPath, extraDiskPath, installerPath, localSourcePath

        var testDescription: String { rawValue }

        func apply(to config: inout VMConfig, past: Bool) {
            let text = String(repeating: "t", count: EditorLimits.maxTextLength + (past ? 1 : 0))
            let path = "/" + String(repeating: "p", count: EditorLimits.maxPathLength - 1 + (past ? 1 : 0))
            let items = EditorLimits.maxHostItems + (past ? 1 : 0)
            switch self {
            case .name: config.name = text
            case .fullName: config.provisioning.fullName = text
            case .username: config.provisioning.username = text
            case .guestVersion: config.guestVersion = text
            case .macAddress: config.macAddress = text
            case .sharedFolderCount: config.sharedFolders = (0..<items).map { SharedFolder(path: "/tmp/f\($0)") }
            case .extraDiskCount: config.extraDisks = (0..<items).map { ExtraDisk(path: "/tmp/d\($0).img") }
            case .sharedFolderPath: config.sharedFolders = [SharedFolder(path: path)]
            case .extraDiskPath: config.extraDisks = [ExtraDisk(path: path)]
            case .installerPath: config.installerISO = path
            case .localSourcePath: config.source = .local(path)
            }
        }
    }

    private func decode(_ config: VMConfig) throws -> VMConfig { try VMConfig.decode(from: config.encoded()) }

    @Test(arguments: Bound.allCases)
    func aValueAtTheLimitLoadsAndOnePastItIsRefused(bound: Bound) throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        bound.apply(to: &config, past: false)
        _ = try decode(config)

        bound.apply(to: &config, past: true)
        #expect(throws: DecodingError.self) { try decode(config) }
    }

    @Test(arguments: ["relative.iso", "~/linux.iso", "./linux.iso", ""])
    func aLocalSourceMustBeAnAbsolutePath(path: String) throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.source = .local(path)
        #expect(throws: DecodingError.self) { try decode(config) }

        config.source = .local("/Users/me/linux.iso")
        #expect(try decode(config).source == .local("/Users/me/linux.iso"))
    }

    @Test func otherSourcesNeedNoPath() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        for source in [
            ImageSource.latestMac, .linuxCatalog(id: "alpine-virt"), .remote(URL(string: "https://example.com/a.iso")!, checksum: nil),
        ] {
            config.source = source
            #expect(try decode(config).source == source)
        }
    }

    // MARK: Rules

    /// A valid rule of the list's kind that differs for each `index`.
    private func rule(_ index: Int, for list: PolicyList) -> String {
        switch list.kind {
        case .domain: "d\(index).example.com"
        case .address: "198.51.\(index / 250).\(index % 250 + 1)"
        case .port: "\(index + 1)"
        case .connection: "d\(index).example.com:443"
        case .urlPrefix: "http://example.com/p\(index)"
        }
    }

    @Test(arguments: PolicyList.allCases)
    func aListHoldsAtMostTheCountTheEditorAllows(list: PolicyList) throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        for index in 0..<EditorLimits.maxRulesPerList { try config.networkPolicy.add(rule(index, for: list), to: list) }
        #expect(try decode(config).networkPolicy.rules(in: list).count == EditorLimits.maxRulesPerList)

        try config.networkPolicy.add(rule(EditorLimits.maxRulesPerList, for: list), to: list)
        #expect(config.networkPolicy.rules(in: list).count == EditorLimits.maxRulesPerList + 1)
        #expect(throws: DecodingError.self) { try decode(config) }
    }

    /// A URL prefix rule whose stored text is exactly `length` characters.
    private func urlRule(ofLength length: Int) -> String {
        var url = "http://example.com"
        var remaining = length - url.count
        while remaining > 0 {
            let segment = min(remaining - 1, 100)
            url += "/" + String(repeating: "a", count: segment)
            remaining -= segment + 1
        }
        return url
    }

    @Test func aRuleAtTheLengthLimitIsAcceptedAndOnePastItIsRefusedByTheEditorAndTheReader() throws {
        var policy = NetworkPolicy()
        try policy.add(urlRule(ofLength: EditorLimits.maxRuleLength), to: .blockedURLPrefixes)
        let stored = try #require(policy.rules(in: .blockedURLPrefixes).first)
        #expect(stored.utf8.count == EditorLimits.maxRuleLength)
        var config = VMConfig.new(name: "x", guest: .linux)
        config.networkPolicy = policy
        _ = try decode(config)

        let tooLong = urlRule(ofLength: EditorLimits.maxRuleLength + 1)
        var unchanged = policy
        #expect(throws: NetworkPolicyError.ruleTooLong) { try unchanged.add(tooLong, to: .blockedURLPrefixes) }
        #expect(unchanged == policy, "a refused rule leaves the policy as it was")
        #expect(NetworkPolicy.problem(with: tooLong, for: .blockedURLPrefixes) == .ruleTooLong)

        let json = #"{"guest":"linux","networkPolicy":{"blockedURLPrefixes":["\#(tooLong)"]}}"#
        #expect(throws: DecodingError.self) { try VMConfig.decode(from: Data(json.utf8)) }
    }

    // MARK: A normal configuration

    @Test func aGenerousButOrdinaryConfigurationStillLoads() throws {
        var config = VMConfig.new(name: String(repeating: "n", count: 80), guest: .linux)
        config.sharedFolders = (0..<10).map { SharedFolder(path: "/Users/me/Projects/project-\($0)") }
        config.extraDisks = [ExtraDisk(path: "/Volumes/Backup/data.img", readOnly: true)]
        config.installerISO = "/Users/me/Downloads/debian-13.0.0-arm64-netinst.iso"
        config.source = .local("/Users/me/Downloads/debian-13.0.0-arm64-netinst.iso")
        config.networkMode = .filtered
        for index in 0..<50 { try config.networkPolicy.add(rule(index, for: .blockedDomains), to: .blockedDomains) }
        try config.networkPolicy.add("http://example.com/downloads/releases", to: .blockedURLPrefixes)
        config.provisioning.fullName = "Ada Lovelace"

        let loaded = try decode(config)
        #expect(loaded == config)
    }

    @Test func aStoredConfigurationFromBeforeTheBoundsLoads() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"#
            + #""diskGiB":32,"sharedFolders":[{"id":"7B873409-1F62-435C-A557-0040D55FBE19","path":"/Users/me/work","readOnly":true}],"#
            + #""source":{"local":{"_0":"/Users/me/linux.iso"}}}"#
        let config = try VMConfig.decode(from: Data(old.utf8))
        #expect(config.name == "legacy" && config.sharedFolders.count == 1 && config.source == .local("/Users/me/linux.iso"))
    }
}

/// The editor holds the same bounds, so what it writes loads again.
@MainActor
struct EditorBoundsTests {
    @Test func aBoundTextFieldCutsWhatIsTypedAtTheLimit() {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 }).limited(to: 5)

        binding.wrappedValue = "abc"
        #expect(text == "abc")
        binding.wrappedValue = "abcdefgh"
        #expect(text == "abcde")
        #expect(binding.wrappedValue == "abcde")
    }

    @Test func theDefaultLimitIsTheStoredOne() {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 }).limited()
        binding.wrappedValue = String(repeating: "é", count: EditorLimits.maxTextLength + 10)
        #expect(text.count == EditorLimits.maxTextLength)
    }

    private func makeModel() throws -> NewMachineModel {
        let suite = "vmrunner-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return NewMachineModel(defaults: defaults)
    }

    @Test func aMachineNameTooLongForAStoredConfigurationCannotBeCreated() throws {
        let model = try makeModel()
        model.config.name = String(repeating: "n", count: EditorLimits.maxTextLength)
        #expect(model.canCreate)
        model.config.name += "n"
        #expect(!model.canCreate)
    }

    @Test(arguments: ["relative.iso", "~/linux.iso", "", "/" + String(repeating: "p", count: EditorLimits.maxPathLength)])
    func aLocalFileWithoutAnAbsoluteOrStorablePathCannotBeUsed(path: String) {
        #expect(!NewMachineModel.canStore(localPath: path))
    }

    @Test func thePickerOnlyTakesAFileOnThisMac() throws {
        let model = try makeModel()
        model.chooseLocalFile(try #require(URL(string: "https://example.com/linux.iso")))
        #expect(model.localPath == nil)
        #expect(model.creationError != nil)

        model.chooseLocalFile(URL(filePath: "/Users/me/linux.iso"))
        #expect(model.localPath == "/Users/me/linux.iso")
        #expect(model.creationError == nil)
    }

    @Test func aRelativePathSetDirectlyStillCannotBeCreated() throws {
        let model = try makeModel()
        model.macSource = .file
        model.localPath = "restore.ipsw"
        #expect(!model.canCreate)
    }

    @Test func aSnapshotNameTooLongForAStoredSnapshotCannotBeTaken() throws {
        let model = SnapshotsModel(bundle: VMBundle(url: try scratchDirectory()))
        model.name = String(repeating: "s", count: EditorLimits.maxTextLength)
        #expect(model.canTake)
        model.name += "s"
        #expect(!model.canTake)
    }

    @Test func theEditorRefusesMoreSharedFoldersAndExtraDisksThanAConfigurationHolds() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        var config = VMConfig.new(name: "x", guest: .linux)
        config.sharedFolders = (0..<EditorLimits.maxHostItems).map { SharedFolder(path: "/tmp/f\($0)") }
        config.extraDisks = (0..<EditorLimits.maxHostItems).map { ExtraDisk(path: "/tmp/d\($0).img") }
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)

        editor.addSharedFolder(URL(filePath: "/tmp/one-more"))
        #expect(library.machine(config.id)?.sharedFolders.count == EditorLimits.maxHostItems)
        #expect(editor.alertMessage?.contains("shared folders") == true)

        editor.alertMessage = nil
        editor.importFile(URL(filePath: "/tmp/one-more.img"), for: .extraDisk)
        #expect(library.machine(config.id)?.extraDisks.count == EditorLimits.maxHostItems)
        #expect(editor.alertMessage?.contains("extra disks") == true)
    }

    @Test func aDuplicateOfAMachineWithTheLongestNameStillLoads() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let config = VMConfig.new(name: String(repeating: "n", count: EditorLimits.maxTextLength), guest: .linux)
        try library.add(config)
        try Data("disk".utf8).write(to: library.bundle(config.id).disk)
        try Data("nvram".utf8).write(to: library.bundle(config.id).efiVariables)

        try library.duplicate(config.id)

        let copy = try #require(library.machines.first { $0.id != config.id })
        #expect(copy.name.count == EditorLimits.maxTextLength && copy.name.hasSuffix(" Copy"))
        let fresh = VMLibrary(machinesDirectory: directory)
        fresh.load()
        #expect(fresh.machines.count == 2, "the copy loads again")
    }
}

/// `snapshot.json`: size capped before parsing, values bounded.
struct SnapshotBoundsTests {
    private func write(_ json: String, in bundle: VMBundle, id: UUID) throws {
        let folder = bundle.snapshots.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "snapshot.json"))
    }

    private func json(_ snapshot: Snapshot, padding: Int = 0) throws -> String {
        let encoded = try #require(String(bytes: JSONEncoder().encode(snapshot), encoding: .utf8))
        return encoded + String(repeating: " ", count: padding)
    }

    @Test func aFileOverTheCapIsRefusedAndOneAtItIsRead() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        let atCap = Snapshot(name: "at cap", diskGiB: 16)
        let overCap = Snapshot(name: "over cap", diskGiB: 16)
        let atCapSize = try json(atCap).utf8.count
        let overCapSize = try json(overCap).utf8.count
        try write(json(atCap, padding: Snapshot.maxFileBytes - atCapSize), in: bundle, id: atCap.id)
        try write(json(overCap, padding: Snapshot.maxFileBytes - overCapSize + 1), in: bundle, id: overCap.id)

        #expect(bundle.listSnapshots().map(\.id) == [atCap.id])
    }

    @Test func aHugeFileIsRefusedWithoutBeingParsed() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "snapshot.json")
        try Data(String(repeating: "[", count: 4 << 20).utf8).write(to: file)

        #expect(throws: DecodingError.self) { try Snapshot.load(from: file) }
    }

    @Test(arguments: [0, EditorLimits.maxTextLength + 1])
    func aNameOverTheLimitIsRefusedAndOneAtItIsListed(extra: Int) throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        let snapshot = Snapshot(name: String(repeating: "s", count: extra == 0 ? EditorLimits.maxTextLength : extra), diskGiB: 16)
        try write(json(snapshot), in: bundle, id: snapshot.id)

        #expect(bundle.listSnapshots().map(\.id) == (extra == 0 ? [snapshot.id] : []))
    }
}
