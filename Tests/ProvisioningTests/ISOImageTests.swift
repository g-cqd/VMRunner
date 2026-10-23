import CryptoKit
import Foundation
import Testing

@testable import Provisioning

/// The system's `tar`, whose ISO 9660 reader is independent of the writer under test. Tests that use it are skipped when
/// it is missing; every Mac the gate runs on has it.
struct SystemTar {
    static let path = "/usr/bin/tar"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// Runs `tar` with `arguments` and returns its exit status and standard output.
    static func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// The names `tar -t` lists in the image at `url`, without the root's `.`.
    static func names(in url: URL) throws -> [String] {
        let listing = try run(["-tf", url.path])
        #expect(listing.status == 0)
        let text = String(data: listing.output, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0 != "." }.sorted()
    }

    /// The contents `tar -x` extracts for `name` from the image at `url`.
    static func contents(of name: String, in url: URL) throws -> String {
        let extracted = try run(["-xOf", url.path, name])
        #expect(extracted.status == 0)
        return String(data: extracted.output, encoding: .utf8) ?? ""
    }
}

private let sample = [
    ISOFile(name: "user-data", contents: Array("#cloud-config\n".utf8)),
    ISOFile(name: "meta-data", contents: Array("instance-id: probe\nlocal-hostname: probe\n".utf8)),
    ISOFile(name: "network-config", contents: Array("version: 2\n".utf8)),
]

struct ISOImageTests {
    private func bytes(_ image: [UInt8], _ range: Range<Int>) -> [UInt8] {
        Array(image[range])
    }

    @Test
    func theDescriptorsCarryTheLabelInBothNameSets() {
        let image = ISOImage.build(label: "cidata", files: sample)
        #expect(image.count == 28 * 2048, "16 + 9 sectors of structure, then one sector per file")
        #expect(image[32_768] == 1)
        #expect(bytes(image, 32_769..<32_775) == Array("CD001".utf8) + [1])
        #expect(bytes(image, 32_808..<32_840) == Array("CIDATA".utf8) + [UInt8](repeating: 0x20, count: 26))
        #expect(image[34_816] == 2)
        #expect(bytes(image, 34_904..<34_907) == Array("%/E".utf8), "the Joliet escape sequence")
        #expect(bytes(image, 34_856..<34_868) == [0, 0x63, 0, 0x69, 0, 0x64, 0, 0x61, 0, 0x74, 0, 0x61], "cidata in UTF-16")
        #expect(image[36_864] == 255, "the set terminator")
    }

    @Test
    func theSameFilesGiveTheSameBytesWhateverTheirOrder() {
        let image = ISOImage.build(label: "cidata", files: sample)
        #expect(ISOImage.build(label: "cidata", files: sample.reversed()) == image)
    }

    /// The digest of the image a separate model of this layout produced for `sample`; `tar` read that image correctly.
    @Test
    func theImageIsGolden() {
        let image = ISOImage.build(label: "cidata", files: sample)
        let digest = SHA256.hash(data: image).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(digest == "2c9a3db44c205ec8b9b91ef8fb70388f6f1b6bcc630ac524e63c3cfa532502e8")
    }

    @Test(.enabled(if: SystemTar.isAvailable))
    func anIndependentReaderListsAndExtractsTheFilesByTheirJolietNames() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "seed.iso")
        try Data(ISOImage.build(label: "cidata", files: sample)).write(to: url)
        #expect(try SystemTar.names(in: url) == ["meta-data", "network-config", "user-data"])
        for file in sample {
            #expect(try SystemTar.contents(of: file.name, in: url) == String(bytes: file.contents, encoding: .utf8))
        }
    }

    @Test(.enabled(if: SystemTar.isAvailable))
    func aFileLargerThanASectorSpansSeveralAndReadsBackWhole() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let large = String(repeating: "0123456789abcdef", count: 300)
        let files = [ISOFile(name: "user-data", contents: Array(large.utf8)), ISOFile(name: "meta-data", contents: [])]
        let image = ISOImage.build(label: "cidata", files: files)
        #expect(image.count == (25 + 3) * 2048, "4800 bytes take three sectors, an empty file none")
        let url = folder.appending(path: "seed.iso")
        try Data(image).write(to: url)
        #expect(try SystemTar.contents(of: "user-data", in: url) == large)
        #expect(try SystemTar.contents(of: "meta-data", in: url).isEmpty)
    }
}
