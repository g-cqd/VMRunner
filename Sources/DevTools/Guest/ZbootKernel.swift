import Foundation

/// Alpine's aarch64 kernel (`vmlinuz-virt`) is an EFI application that carries the kernel gzip-compressed ("zboot"). The
/// framework's Linux boot loader wants the raw arm64 `Image`, so the payload is cut out and decompressed.
///
/// The header is 32 bytes: `MZ`, two zero bytes, `zimg`, the payload's offset and size (32-bit little endian each), eight
/// reserved bytes and the four-byte compression name (`gzip`).
enum ZbootKernel {
    struct Payload: Equatable {
        let offset: Int
        let size: Int
    }

    /// Where the gzip payload lies in `header` (the first bytes of the file) for a file of `fileSize` bytes.
    static func payload(inHeader header: [UInt8], fileSize: Int) throws -> Payload {
        guard header.count >= 32, header.starts(with: [0x4D, 0x5A]), Array(header[4..<8]) == Array("zimg".utf8) else {
            throw ToolError("the kernel is not an EFI zboot image (no 'zimg' header)")
        }
        guard Array(header[24..<28]) == Array("gzip".utf8) else {
            throw ToolError("the kernel's payload is not gzip-compressed: \(String(bytes: header[24..<28], encoding: .utf8) ?? "?")")
        }
        let offset = Int(littleEndian32(header, at: 8))
        let size = Int(littleEndian32(header, at: 12))
        guard offset >= 32, size > 0, offset <= fileSize, size <= fileSize - offset else {
            throw ToolError("the kernel's payload (offset \(offset), \(size) bytes) lies outside the \(fileSize)-byte file")
        }
        return Payload(offset: offset, size: size)
    }

    /// The first bytes of an arm64 `Image`: the magic `ARM\x64` at offset 56.
    static func isArm64Image(_ head: [UInt8]) -> Bool {
        head.count >= 60 && Array(head[56..<60]) == [0x41, 0x52, 0x4D, 0x64]
    }

    /// Writes the decompressed kernel of the zboot file `source` to `destination`. `gunzip` decompresses `<destination>.gz`
    /// in place, leaving `destination` (what `gzip -d` does).
    static func extractImage(from source: URL, to destination: URL, gunzip: (_ archive: URL) async throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let header = [UInt8](try handle.read(upToCount: 32) ?? Data())
        let location = try payload(inHeader: header, fileSize: fileSize)
        try handle.seek(toOffset: UInt64(location.offset))
        let compressed = try handle.read(upToCount: location.size) ?? Data()
        guard compressed.count == location.size else { throw ToolError("the kernel is shorter than its header says") }

        let staging = destination.appendingPathExtension("gz")
        defer { try? FileManager.default.removeItem(at: staging) }
        try compressed.write(to: staging)
        try await gunzip(staging)

        let image = try FileHandle(forReadingFrom: destination)
        defer { try? image.close() }
        guard isArm64Image([UInt8](try image.read(upToCount: 64) ?? Data())) else {
            try? FileManager.default.removeItem(at: destination)
            throw ToolError("the decompressed kernel is not an arm64 Image (no ARM\\x64 magic at offset 56)")
        }
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * UInt32($1)) }
    }
}
