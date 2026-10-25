import Foundation

/// The runner's lines, straight to the standard streams; a line about the guest starts with the seconds since the start.
enum Output {
    static func line(_ text: String, error: Bool = false) {
        let handle = error ? FileHandle.standardError : FileHandle.standardOutput
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }

    /// `bytes` as two lower-case hexadecimal digits each, separated by spaces.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined(separator: " ")
    }
}
