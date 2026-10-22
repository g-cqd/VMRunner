import Foundation

/// Where the first three bytes of an address VMRunner makes for a machine come from.
enum MACVendor: String, Codable, CaseIterable, Sendable {
    /// Random, with the locally administered bit set, as the framework makes them: no manufacturer owns such an address.
    case locallyAdministered
    case apple, intel, realtek

    /// The manufacturer's registered prefix (its OUI), or nil for a locally administered address.
    var prefix: [UInt8]? {
        switch self {
        case .locallyAdministered: nil
        case .apple: [0x00, 0x03, 0x93]
        case .intel: [0x00, 0x1B, 0x21]
        case .realtek: [0x00, 0xE0, 0x4C]
        }
    }

    /// A new unicast address in lowercase `xx:xx:xx:xx:xx:xx`: this vendor's prefix and three random bytes, or six random
    /// bytes with the locally administered bit set and the group bit clear.
    func makeAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max) }
        if let prefix {
            bytes.replaceSubrange(0..<3, with: prefix)
        } else {
            bytes[0] = (bytes[0] | 0x02) & 0xFE
        }
        return bytes.map { [$0].hexString }.joined(separator: ":")
    }
}
