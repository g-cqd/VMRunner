import CryptoKit
import Foundation
import Testing
import Virtualization

@testable import VMRunner

struct WindowsBootTests {
    private func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    @Test func theEmbeddedFirmwareMatchesItsDigestAndIsARM64EFI() throws {
        let firmware = try #require(Data(base64Encoded: WindowsBootFirmwareData.base64, options: .ignoreUnknownCharacters))
        #expect(SHA256.hash(data: firmware).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() == WindowsBootFirmwareData.sha256)
        #expect(firmware.prefix(2) == Data("MZ".utf8))
        let pe = Int(number(firmware, 0x3c, 4))
        #expect(number(firmware, pe, 4) == 0x4550)
        #expect(number(firmware, pe + 4, 2) == 0xaa64)
        #expect(number(firmware, pe + 24 + 68, 2) == 10, "EFI application")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appending(path: "Firmware/WindowsBoot/FramebufferBoot.c"))
        #expect(
            SHA256.hash(data: source).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() == WindowsBootFirmwareData.sourceSHA256)
    }

    @Test func theBootDiskHasValidMirroredGPTFATAndExactFirmwareAndToken() throws {
        let firmware = Data((0..<3001).map { UInt8(truncatingIfNeeded: $0) })
        let token = Data(repeating: 0x42, count: 16)
        let disk = try WindowsBootDisk.make(firmware: firmware, token: token)
        #expect(disk.count == WindowsBootDisk.sectors * 512)
        #expect(number(disk, 510, 2) == 0xaa55 && disk[450] == 0xee)
        #expect(disk.subdata(in: 447..<450) == Data([0, 2, 0]))
        #expect(disk.subdata(in: 451..<454) == Data([0xff, 0xff, 0xff]))
        for sector in [1, WindowsBootDisk.sectors - 1] {
            let offset = sector * 512
            var header = disk.subdata(in: offset..<offset + 92)
            let checksum = number(header, 16, 4)
            header.replaceSubrange(16..<20, with: [0, 0, 0, 0])
            #expect(UInt64(WindowsBootDisk.crc32(header)) == checksum)
            let table = Int(number(disk, offset + 72, 8)) * 512
            let entries = disk.subdata(in: table..<table + 16384)
            #expect(UInt64(WindowsBootDisk.crc32(entries)) == number(disk, offset + 88, 4))
            #expect(entries.prefix(4) == Data([0x28, 0x73, 0x2a, 0xc1]), "ESP, not Microsoft Basic Data")
        }
        let base = 2048 * 512
        #expect(number(disk, base + 11, 2) == 512 && disk[base + 13] == 2)
        #expect(disk.subdata(in: base + 512..<base + 129 * 512) == disk.subdata(in: base + 129 * 512..<base + 257 * 512))
        let file = base + 289 * 512 + 2 * 1024
        #expect(disk.subdata(in: file..<file + firmware.count) == firmware)
        let tokenOffset = file + 3 * 1024
        #expect(disk.subdata(in: tokenOffset..<tokenOffset + 16) == token)
        let root = base + 257 * 512
        #expect(String(bytes: disk[root + 32..<root + 43], encoding: .utf8) == "VMRBOOT ID ")
        #expect(WindowsBootDisk.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
    }

    @Test func invalidInputsAreRejectedBeforeAnImageIsAllocated() {
        #expect(throws: WindowsBootDisk.Failure.self) { try WindowsBootDisk.make(firmware: Data(), token: Data(count: 16)) }
        #expect(throws: WindowsBootDisk.Failure.self) { try WindowsBootDisk.make(firmware: Data(count: 1 << 20), token: Data(count: 16)) }
        #expect(throws: WindowsBootDisk.Failure.self) { try WindowsBootDisk.make(firmware: Data([1]), token: Data(count: 15)) }
    }

    @Test func preparationPreservesTheOriginalEFIStoreAndCleansOnlyOwnedRunFiles() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = VMBundle(url: folder)
        let original = Data("original firmware state".utf8)
        try original.write(to: bundle.efiVariables)
        let first = try WindowsBootMedia.prepareSynchronously(in: bundle)
        let second = try WindowsBootMedia.prepareSynchronously(in: bundle)
        #expect(first.token.count == 16 && second.token != first.token)
        #expect(try Data(contentsOf: bundle.efiVariables) == original)
        #expect(FileManager.default.fileExists(atPath: second.variables.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: second.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        bundle.discardEphemeral()
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        #expect(!FileManager.default.fileExists(atPath: second.variables.path))
        #expect(try Data(contentsOf: bundle.efiVariables) == original)
    }
}

struct WindowsFrameRecordTests {
    private let token = Data(repeating: 0x42, count: 16)
    private func store(address: UInt64 = 0x2_0000_0000, width: Int = 1920, height: Int = 1200, status: UInt64 = 0) -> Data {
        var data = Data(count: 24)
        func put(_ value: UInt64, _ count: Int) {
            data.append(contentsOf: (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        put(UInt64(WindowsFrameRecord.name.count), 4)
        put(56, 4)
        data.append(WindowsFrameRecord.guid)
        data.append(WindowsFrameRecord.name)
        data.append(token)
        put(address, 8)
        put(UInt64(width), 4)
        put(UInt64(height), 4)
        put(UInt64(width * 4), 4)
        put(UInt64(width * height * 4), 4)
        put(status, 8)
        put(1, 8)
        return data
    }

    @Test func coherentRecordsDecodeAndTheNewestWins() throws {
        let old = store(address: 0x3_0000_0000)
        let latest = store()
        let record = try #require(WindowsFrameRecord.decode(old + latest, token: token))
        #expect(record.address == 0x2_0000_0000 && record.byteCount == 9_216_000)
        #expect(record.width == 1920 && record.height == 1200 && record.status == 0 && record.generation == 1)
        let prefixed = Data(count: 10) + latest
        #expect(WindowsFrameRecord.decode(prefixed.dropFirst(10), token: token) == record)
    }

    @Test func malformedTruncatedStaleAndOversizedRecordsAreRefused() {
        let good = store()
        for size in 0..<good.count { #expect(WindowsFrameRecord.decode(good.prefix(size), token: token) == nil) }
        #expect(WindowsFrameRecord.decode(good, token: Data(count: 16)) == nil)
        #expect(WindowsFrameRecord.decode(Data(count: (1 << 20) + 1) + good, token: token) == nil)
        #expect(WindowsFrameRecord.decode(store(address: 0), token: token) == nil)
        #expect(WindowsFrameRecord.decode(store(address: 1), token: token) == nil)
        #expect(WindowsFrameRecord.decode(store(address: UInt64.max - 4095), token: token) == nil)
        #expect(WindowsFrameRecord.decode(store(width: 1919), token: token) == nil)
        #expect(WindowsFrameRecord.decode(store(height: 1199), token: token) == nil)
        var malformed = good
        malformed[28] = 47
        #expect(WindowsFrameRecord.decode(malformed, token: token) == nil)
        malformed = good
        malformed[32] ^= 1
        #expect(WindowsFrameRecord.decode(malformed, token: token) == nil)
    }

    @Test func bootFailureCanBeReportedWithoutMappingAnyPixels() {
        let record = WindowsFrameRecord.decode(store(address: 0, width: 0, height: 0, status: 0x8000_0000_0000_000e), token: token)
        #expect(record?.status == 0x8000_0000_0000_000e)
    }
}
