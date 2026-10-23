/// A file of an ISO 9660 image's root directory: its name as a guest reads it, and its bytes.
struct ISOFile: Equatable, Sendable {
    /// Lowercase ASCII letters, digits and `-`, 1 to 30 characters.
    let name: String
    let contents: [UInt8]
}

/// An ISO 9660 image with Joliet names holding a few small files in its root directory, built in memory. Every date in it
/// is fixed, so the same label and files always give the same bytes.
///
/// Layout, in 2048-byte sectors: 0 to 15 empty; 16 the primary volume descriptor; 17 the Joliet supplementary descriptor;
/// 18 the set terminator; 19 to 22 the path tables (little- then big-endian, primary then Joliet); 23 the primary root
/// directory; 24 the Joliet root directory; then each file from a sector of its own, in name order. Primary names are the
/// names in uppercase, which a guest without Joliet lowercases back; Linux and cloud-init read the Joliet names.
enum ISOImage {
    static let sectorSize = 2048
    private static let firstFileSector = 25
    private static let pathTableSize = 10
    /// The recording date of every directory record: 1970-01-01 00:00:00 UTC.
    private static let recordingDate: [UInt8] = [70, 1, 1, 0, 0, 0, 0]

    /// A file's record in one of the two root directories.
    private struct Entry {
        let identifier: [UInt8]
        let sector: Int
        let length: Int
    }

    /// The image of `files` under `label` (1 to 16 ASCII letters and digits). At most 8 files, which is what a seed holds.
    static func build(label: String, files: [ISOFile]) -> [UInt8] {
        precondition(isValid(label: label), "a label of 1 to 16 ASCII letters and digits")
        precondition(files.count <= 8 && files.allSatisfy { isValid(name: $0.name) }, "at most 8 files with short names")
        let sorted = files.sorted { $0.name < $1.name }
        var sectors: [Int] = []
        var next = firstFileSector
        for file in sorted {
            sectors.append(next)
            next += (file.contents.count + sectorSize - 1) / sectorSize
        }
        var image = [UInt8](repeating: 0, count: next * sectorSize)
        func put(_ bytes: [UInt8], at sector: Int) {
            image.replaceSubrange(sector * sectorSize..<sector * sectorSize + bytes.count, with: bytes)
        }
        put(volumeDescriptor(joliet: false, label: label.uppercased(), pathTable: 19, root: 23, total: next), at: 16)
        put(volumeDescriptor(joliet: true, label: label, pathTable: 21, root: 24, total: next), at: 17)
        put(terminator(), at: 18)
        put(pathTable(root: 23, bigEndian: false), at: 19)
        put(pathTable(root: 23, bigEndian: true), at: 20)
        put(pathTable(root: 24, bigEndian: false), at: 21)
        put(pathTable(root: 24, bigEndian: true), at: 22)
        let primary = zip(sorted, sectors).map {
            Entry(identifier: Array($0.name.uppercased().utf8), sector: $1, length: $0.contents.count)
        }
        let joliet = zip(sorted, sectors).map {
            Entry(identifier: utf16BigEndian($0.name), sector: $1, length: $0.contents.count)
        }
        put(rootDirectory(at: 23, entries: primary), at: 23)
        put(rootDirectory(at: 24, entries: joliet), at: 24)
        for (file, sector) in zip(sorted, sectors) { put(file.contents, at: sector) }
        return image
    }

    private static func volumeDescriptor(joliet: Bool, label: String, pathTable: Int, root: Int, total: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: sectorSize)
        bytes[0] = joliet ? 2 : 1
        bytes.replaceSubrange(1..<7, with: Array("CD001".utf8) + [1])
        bytes.replaceSubrange(8..<40, with: text("", width: 32, joliet: joliet))
        bytes.replaceSubrange(40..<72, with: text(label, width: 32, joliet: joliet))
        bytes.replaceSubrange(80..<88, with: bothEndian32(total))
        if joliet { bytes.replaceSubrange(88..<91, with: Array("%/E".utf8)) }
        bytes.replaceSubrange(120..<124, with: bothEndian16(1))
        bytes.replaceSubrange(124..<128, with: bothEndian16(1))
        bytes.replaceSubrange(128..<132, with: bothEndian16(sectorSize))
        bytes.replaceSubrange(132..<140, with: bothEndian32(pathTableSize))
        bytes.replaceSubrange(140..<144, with: littleEndian32(pathTable))
        bytes.replaceSubrange(148..<152, with: bigEndian32(pathTable + 1))
        bytes.replaceSubrange(156..<190, with: record(identifier: [0], sector: root, length: sectorSize, isDirectory: true))
        bytes.replaceSubrange(190..<813, with: text("", width: 623, joliet: joliet))
        for start in [813, 830, 847, 864] {
            bytes.replaceSubrange(start..<start + 17, with: Array("0000000000000000".utf8) + [0])
        }
        bytes[881] = 1
        return bytes
    }

    private static func terminator() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: sectorSize)
        bytes[0] = 255
        bytes.replaceSubrange(1..<7, with: Array("CD001".utf8) + [1])
        return bytes
    }

    /// The path table of a volume whose only directory is its root.
    private static func pathTable(root: Int, bigEndian: Bool) -> [UInt8] {
        var bytes: [UInt8] = [1, 0]
        bytes += bigEndian ? bigEndian32(root) : littleEndian32(root)
        bytes += bigEndian ? [0, 1] : [1, 0]
        bytes += [0, 0]
        return bytes
    }

    private static func rootDirectory(at sector: Int, entries: [Entry]) -> [UInt8] {
        var bytes = record(identifier: [0], sector: sector, length: sectorSize, isDirectory: true)
        bytes += record(identifier: [1], sector: sector, length: sectorSize, isDirectory: true)
        for entry in entries {
            bytes += record(identifier: entry.identifier, sector: entry.sector, length: entry.length, isDirectory: false)
        }
        return bytes
    }

    private static func record(identifier: [UInt8], sector: Int, length: Int, isDirectory: Bool) -> [UInt8] {
        var bytes: [UInt8] = [0, 0]
        bytes += bothEndian32(sector)
        bytes += bothEndian32(length)
        bytes += recordingDate
        bytes += [isDirectory ? 2 : 0, 0, 0]
        bytes += bothEndian16(1)
        bytes.append(UInt8(identifier.count))
        bytes += identifier
        if identifier.count.isMultiple(of: 2) { bytes.append(0) }
        bytes[0] = UInt8(bytes.count)
        return bytes
    }

    /// `value` in a fixed-width field: ASCII padded with spaces, or for Joliet UTF-16 big-endian padded with UTF-16 spaces
    /// (an odd last byte stays zero).
    private static func text(_ value: String, width: Int, joliet: Bool) -> [UInt8] {
        var bytes = joliet ? utf16BigEndian(value) : Array(value.utf8)
        let pad: [UInt8] = joliet ? [0, 0x20] : [0x20]
        while bytes.count + pad.count <= width { bytes += pad }
        while bytes.count < width { bytes.append(0) }
        return bytes
    }

    private static func utf16BigEndian(_ value: String) -> [UInt8] {
        value.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    private static func littleEndian32(_ value: Int) -> [UInt8] {
        let word = UInt32(value)
        return [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF), UInt8(word >> 24)]
    }

    private static func bigEndian32(_ value: Int) -> [UInt8] {
        Array(littleEndian32(value).reversed())
    }

    private static func bothEndian32(_ value: Int) -> [UInt8] {
        littleEndian32(value) + bigEndian32(value)
    }

    private static func bothEndian16(_ value: Int) -> [UInt8] {
        let low = UInt8(value & 0xFF)
        let high = UInt8((value >> 8) & 0xFF)
        return [low, high, high, low]
    }

    private static func isValid(label: String) -> Bool {
        (1...16).contains(label.count) && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isValid(name: String) -> Bool {
        (1...30).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}
