import Foundation

/// Versioned, coherent EFI framebuffer record. Treat the variable store as untrusted, bounded input, never host pointers.
/// The per-start token prevents an earlier run's variable journal from selecting an unrelated RAM range.
struct WindowsFrameRecord: Equatable {
    let address: UInt64
    let width: Int
    let height: Int
    let byteCount: Int
    let status: UInt64
    let generation: UInt64

    static let maximumStoreBytes = 1 << 20
    static let name = Data("VMRFrame-v1\0".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
    static let guid = Data([0x8a, 0xe2, 0xb4, 0xd1, 0x41, 0x06, 0xdc, 0x44, 0x8a, 0xee, 0x65, 0x43, 0x12, 0x99, 0x30, 0x26])

    static func decode(_ store: Data, token: Data) -> Self? {
        guard token.count == 16, store.count <= maximumStoreBytes,
            let range = store.range(of: name, options: .backwards), range.lowerBound >= store.startIndex + 24,
            range.upperBound <= store.endIndex - 56,
            store.subdata(in: range.lowerBound - 16..<range.lowerBound) == guid
        else { return nil }
        func number(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(store[offset + $1]) << ($1 * 8) }
        }
        guard number(range.lowerBound - 24, 4) == UInt64(name.count), number(range.lowerBound - 20, 4) == 56,
            store.subdata(in: range.upperBound..<range.upperBound + 16) == token
        else { return nil }
        let base = range.upperBound
        let address = number(base + 16, 8)
        let width = Int(number(base + 24, 4))
        let height = Int(number(base + 28, 4))
        let stride = Int(number(base + 32, 4))
        let bytes = Int(number(base + 36, 4))
        let status = number(base + 40, 8)
        if status == 0 {
            guard width == 1920, height == 1200, stride == width * 4, bytes == stride * height,
                address != 0, address.isMultiple(of: 4096), address <= UInt64.max - UInt64(bytes)
            else { return nil }
        }
        return Self(address: address, width: width, height: height, byteCount: bytes, status: status, generation: number(base + 48, 8))
    }
}
