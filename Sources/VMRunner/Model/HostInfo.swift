import Foundation

/// Which facts about this Mac a guest can read from the host-information share. Each is off until the user turns it on,
/// and the Isolated and Hardened profiles turn them all off.
struct HostInfoSharing: Codable, Hashable, Sendable {
    var battery = false
    var power = false
    var thermal = false
    var networkPath = false
    var timeZone = false

    /// Whether nothing is shared, so the machine gets no share at all.
    var isEmpty: Bool { !(battery || power || thermal || networkPath || timeZone) }

    /// What is shared, in words, for the exposure summary.
    var names: [String] {
        [
            (battery, "battery level"), (power, "power source"), (thermal, "thermal state"), (networkPath, "network path"),
            (timeZone, "time zone"),
        ]
        .filter { $0.0 }.map { $0.1 }
    }
}
