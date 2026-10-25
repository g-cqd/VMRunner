import Foundation
import Testing

@testable import VMRunner

/// `config.json` is untrusted: bad values are refused where the file is read, and the places that use them are safe on
/// their own.
struct ConfigValidationTests {
    private func decode(_ json: String) throws -> VMConfig { try VMConfig.decode(from: Data(json.utf8)) }

    /// Fails the test unless decoding `data` throws `DecodingError.dataCorrupted`; returns its description.
    private func corruption(of data: Data) throws -> String {
        do {
            _ = try VMConfig.decode(from: data)
        } catch DecodingError.dataCorrupted(let context) {
            return context.debugDescription
        }
        Issue.record("the data was accepted")
        return ""
    }

    @Test(
        arguments: [
            #"{"guest":"linux","diskGiB":-1}"#,
            #"{"guest":"linux","diskGiB":0}"#,
            #"{"guest":"linux","diskGiB":4097}"#,
            #"{"guest":"linux","diskGiB":9223372036854775807}"#,
            #"{"guest":"linux","maxRuntimeMinutes":9223372036854775807}"#,
            #"{"guest":"linux","maxRuntimeMinutes":-5}"#,
            #"{"guest":"macOS","pixelsPerInch":9223372036854775807}"#,
            #"{"guest":"macOS","pixelsPerInch":10}"#,
            #"{"guest":"linux","pixelsPerPoint":9223372036854775807}"#,
            #"{"guest":"linux","pixelsPerPoint":0}"#,
            #"{"guest":"linux","displayWidth":9223372036854775807}"#,
            #"{"guest":"linux","displayHeight":1}"#,
            #"{"guest":"linux","lastDisplayWidth":-1}"#,
        ])
    func aNumberOutsideTheEditorsRangeIsRefused(json: String) throws {
        _ = try corruption(of: Data(json.utf8))
    }

    @Test func theEditorsLimitsThemselvesAreAccepted() throws {
        let config = try decode(
            #"{"guest":"macOS","diskGiB":4096,"maxRuntimeMinutes":1440,"pixelsPerInch":326,"displayWidth":7680,"displayHeight":4320}"#)
        #expect(config.diskGiB == 4096 && config.maxRuntimeMinutes == 1440 && config.pixelsPerInch == 326)
        #expect(try decode(#"{"guest":"linux","diskGiB":1,"maxRuntimeMinutes":0,"pixelsPerPoint":2}"#).pixelsPerPoint == 2)
    }

    @Test func aFreshConfigIsWithinEveryBound() throws {
        for guest in GuestOS.allCases {
            let data = try VMConfig.new(name: "x", guest: guest).applying(.hardened).encoded()
            _ = try VMConfig.decode(from: data)
            #expect(!JSONNesting.exceeds(VMConfig.maxNesting / 2, in: data), "a real config nests far less than the limit")
        }
    }

    /// A shared folder or extra disk entry, which carries every key its type encodes.
    private func entry(_ path: String) -> String {
        #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","readOnly":false,"path":"\#(path)"}"#
    }

    @Test(
        arguments: [
            "relative/dir", "~/dir", "disk.img", "./dir", "",
        ])
    func aRelativeHostPathIsRefused(path: String) throws {
        for key in ["sharedFolders", "extraDisks"] {
            _ = try corruption(of: Data(#"{"guest":"linux","\#(key)":[\#(entry(path))]}"#.utf8))
        }
        _ = try corruption(of: Data(#"{"guest":"linux","installerISO":"\#(path)"}"#.utf8))
    }

    @Test func absoluteHostPathsAreAccepted() throws {
        let config = try decode(
            #"{"guest":"linux","sharedFolders":[\#(entry("/Users/me/work"))],"extraDisks":[\#(entry("/Volumes/d/x.img"))],"#
                + #""installerISO":"/Users/me/linux.iso"}"#)
        #expect(config.hostGrants.count == 3)
    }

    @Test func aNumberTooBigForAnyTypeIsRefusedWithoutCrashing() {
        #expect(throws: (any Error).self) { try decode(#"{"guest":"linux","cpuCount":1e999}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"guest":"linux","cpuCount":-1e999}"#) }
    }

    @Test(arguments: [10_000, 1_000_000])
    func aDeeplyNestedArrayIsRefusedBeforeItIsParsed(depth: Int) throws {
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        _ = try corruption(of: Data(json.utf8))
    }

    @Test func nestingInsideAKeyIsRefusedToo() throws {
        let nested = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        let message = try corruption(of: Data(#"{"guest":"linux","name":"x","extra":\#(nested)}"#.utf8))
        #expect(message.contains("nests"), "refused for its depth, not by luck: \(message)")
    }

    @Test func bracketsInsideStringsDoNotCountAsNesting() throws {
        let brackets = String(repeating: "[", count: 200) + #"\"[{"#
        let config = try decode(#"{"guest":"linux","name":"\#(brackets)"}"#)
        #expect(config.name.hasPrefix("[["))
    }

    @Test func aFileOverOneMebibyteIsRefusedWithoutBeingParsed() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        let padding = String(repeating: "a", count: 2 << 20)
        try Data(#"{"guest":"linux","name":"\#(padding)"}"#.utf8).write(to: file)

        #expect(throws: DecodingError.self) { try VMConfig.load(from: file) }
        let message = try corruption(of: Data(contentsOf: file))
        #expect(message.contains("1 MiB"))
    }

    @Test func aFileJustUnderTheLimitStillLoads() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        // A key the app doesn't know carries the bulk, so the size is tested without a name past its own bound.
        let padding = String(repeating: "a", count: VMConfig.maxFileBytes - 100)
        try Data(#"{"guest":"linux","name":"big","padding":"\#(padding)"}"#.utf8).write(to: file)

        #expect(try VMConfig.load(from: file).name == "big")
    }
}

struct NumericSinkTests {
    private func temporaryFile() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }

    @Test(arguments: [-1, 0, Int.min, Int.max, EditorLimits.maxDiskGiB + 1])
    func aDiskImageOfAnImpossibleSizeIsRefusedNotTrapped(gibibytes: Int) {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: DiskImageError.self) { try DiskImage.create(at: file, gibibytes: gibibytes) }
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing is created for a refused size")
    }

    @Test func growingToAnImpossibleSizeLeavesTheImageAlone() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try DiskImage.create(at: file, gibibytes: 1)

        #expect(throws: DiskImageError.self) { try DiskImage.grow(at: file, toGibibytes: Int.max) }
        #expect(throws: DiskImageError.self) { try DiskImage.grow(at: file, toGibibytes: -3) }
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == 1 << 30)
    }

    @Test func theRuntimeLimitConvertsMinutesWithoutOverflowing() {
        #expect(RuntimeLimit.duration(forMinutes: 0) == nil)
        #expect(RuntimeLimit.duration(forMinutes: -4) == nil)
        #expect(RuntimeLimit.duration(forMinutes: 120) == .seconds(7200))
        #expect(RuntimeLimit.duration(forMinutes: Int.max) == .seconds(1440 * 60), "capped at the editor's longest limit")
    }

    @Test(arguments: [GuestOS.macOS, .linux])
    func theGuestDisplaySizeSurvivesAbsurdDensities(guest: GuestOS) {
        var config = VMConfig.new(name: "x", guest: guest)
        config.pixelsPerInch = Int.max
        config.pixelsPerPoint = Int.max

        let size = StartDisplay.size(for: config, window: CGSize(width: 2000, height: 1200), restoring: false)

        #expect(EditorLimits.displayWidth.contains(size.width) && EditorLimits.displayHeight.contains(size.height))
    }

    @Test func aSnapshotWithAnImpossibleSizeIsNotListed() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data("disk".utf8).write(to: bundle.disk)
        try writeEFIVariableStore(at: bundle.efiVariables)
        let good = try bundle.takeSnapshot(named: "good", config: VMConfig.new(name: "x", guest: .linux))
        for size in [-1, 0, Int.max] {
            let bad = Snapshot(name: "bad \(size)", diskGiB: size)
            let folder = bundle.snapshots.appending(path: bad.id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(bad).write(to: folder.appending(path: "snapshot.json"))
        }

        #expect(bundle.listSnapshots().map(\.id) == [good.id])
    }
}
