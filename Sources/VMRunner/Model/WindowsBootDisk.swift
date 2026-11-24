import Foundation

/// The owned, read-only medium: protective MBR, mirrored GPT, FAT16 ESP and a per-start display token.
enum WindowsBootDisk {
    static let sector = 512
    static let start = 2048
    static let volumeSectors = 65536
    static let sectors = start + volumeSectors + 33
    static let dataSector = 289
    static let clusterBytes = 1024
    enum Failure: Error { case invalidFirmware, invalidToken }

    static func make(firmware: Data, token: Data) throws -> Data {
        guard !firmware.isEmpty, firmware.count < 1 << 20 else { throw Failure.invalidFirmware }
        guard token.count == 16 else { throw Failure.invalidToken }
        var writer = WindowsBootDiskWriter()
        writer.partitions(token: token)
        writer.filesystem(firmware: firmware, token: token)
        return writer.image
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
        }
        return ~crc
    }
}

/// All offsets are derived from the fixed layout, never from guest or installer data.
private struct WindowsBootDiskWriter {
    private typealias Layout = WindowsBootDisk
    var image = Data(count: Layout.sectors * Layout.sector)

    private mutating func put(_ bytes: Data, at offset: Int) {
        image.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    private mutating func number(_ value: UInt64, at offset: Int, bytes: Int) {
        put(Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }), at: offset)
    }

    mutating func partitions(token: Data) {
        put(Data([0, 2, 0]), at: 447)
        put(Data([0xff, 0xff, 0xff]), at: 451)
        number(0xee, at: 450, bytes: 1)
        number(1, at: 454, bytes: 4)
        number(UInt64(Layout.sectors - 1), at: 458, bytes: 4)
        number(0xaa55, at: 510, bytes: 2)
        var entries = Data(count: 16384)
        entries.replaceSubrange(
            0..<16,
            with: [
                0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
                0xba, 0x4b, 0, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
            ])
        entries.replaceSubrange(16..<32, with: token)
        for (offset, value) in [(32, Layout.start), (40, Layout.start + Layout.volumeSectors - 1)] {
            for byte in 0..<8 { entries[offset + byte] = UInt8(truncatingIfNeeded: UInt64(value) >> (byte * 8)) }
        }
        let label = Data("VMRunner Windows boot".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        entries.replaceSubrange(56..<56 + label.count, with: label)
        put(entries, at: 2 * Layout.sector)
        put(entries, at: (Layout.sectors - 33) * Layout.sector)
        for (current, backup, table) in [(1, Layout.sectors - 1, 2), (Layout.sectors - 1, 1, Layout.sectors - 33)] {
            let base = current * Layout.sector
            put(Data("EFI PART".utf8), at: base)
            number(0x10000, at: base + 8, bytes: 4)
            number(92, at: base + 12, bytes: 4)
            for (offset, value) in [(24, current), (32, backup), (40, 34), (48, Layout.sectors - 34), (72, table)] {
                number(UInt64(value), at: base + offset, bytes: 8)
            }
            put(token, at: base + 56)
            number(128, at: base + 80, bytes: 4)
            number(128, at: base + 84, bytes: 4)
            number(UInt64(Layout.crc32(entries)), at: base + 88, bytes: 4)
            number(UInt64(Layout.crc32(image.subdata(in: base..<base + 92))), at: base + 16, bytes: 4)
        }
    }

    mutating func filesystem(firmware: Data, token: Data) {
        let base = Layout.start * Layout.sector
        put(Data([0xeb, 0x3c, 0x90]) + Data("VMRBOOT ".utf8), at: base)
        for (offset, value, bytes) in [
            (11, 512, 2), (13, 2, 1), (14, 1, 2), (16, 2, 1), (17, 512, 2), (21, 0xf8, 1), (22, 128, 2),
            (24, 32, 2), (26, 64, 2), (28, Layout.start, 4), (32, Layout.volumeSectors, 4),
            (36, 0x80, 1), (38, 0x29, 1), (39, 0x564d_5231, 4), (510, 0xaa55, 2),
        ] { number(UInt64(value), at: base + offset, bytes: bytes) }
        put(Data("VMRBOOT    FAT16   ".utf8), at: base + 43)
        let clusters = (firmware.count + Layout.clusterBytes - 1) / Layout.clusterBytes
        let tokenCluster = 4 + clusters
        for fat in [1, 129] {
            for cluster in 0...tokenCluster {
                let next = cluster == 0 ? 0xfff8 : (cluster < 4 || cluster >= tokenCluster - 1 ? 0xffff : cluster + 1)
                number(UInt64(next), at: base + fat * Layout.sector + cluster * 2, bytes: 2)
            }
        }
        let root = base + 257 * Layout.sector
        entry("EFI        ", directory: true, cluster: 2, size: 0, at: root)
        entry("VMRBOOT ID ", directory: false, cluster: tokenCluster, size: 16, at: root + 32)
        for (cluster, parent, child, childCluster) in [(2, 0, "BOOT       ", 3), (3, 2, "BOOTAA64EFI", 4)] {
            let offset = location(cluster)
            entry(".          ", directory: true, cluster: cluster, size: 0, at: offset)
            entry("..         ", directory: true, cluster: parent, size: 0, at: offset + 32)
            entry(child, directory: cluster == 2, cluster: childCluster, size: cluster == 2 ? 0 : firmware.count, at: offset + 64)
        }
        put(firmware, at: location(4))
        put(token, at: location(tokenCluster))
    }

    private func location(_ cluster: Int) -> Int {
        Layout.start * Layout.sector + Layout.dataSector * Layout.sector + (cluster - 2) * Layout.clusterBytes
    }

    private mutating func entry(_ name: String, directory: Bool, cluster: Int, size: Int, at offset: Int) {
        put(Data(name.utf8), at: offset)
        number(directory ? 0x10 : 0x20, at: offset + 11, bytes: 1)
        number(UInt64(cluster), at: offset + 26, bytes: 2)
        number(UInt64(size), at: offset + 28, bytes: 4)
    }
}
