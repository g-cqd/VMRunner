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

/// What this Mac reports, as the host-information share publishes it. A plain value, so the files can be checked without
/// a battery or a network.
struct HostFacts: Equatable, Sendable {
    enum PowerSource: String, Sendable { case ac, battery, unknown }
    enum Thermal: String, Sendable { case nominal, fair, serious, critical }

    /// The internal battery's charge in percent; nil on a Mac without one, or when it can't be read.
    var batteryPercent: Int?
    var powerSource = PowerSource.unknown
    var lowPowerMode = false
    var thermal = Thermal.nominal
    /// The Mac's network path; nil until the first sample.
    var network: HostNetworkPath?
    /// The time zone's identifier, such as `Europe/Paris`.
    var timeZone = ""

    /// The share's file names, one per category.
    static let fileNames = ["battery", "power", "thermal", "network", "timezone"]

    /// The text of the file of each category `sharing` turns on, one `key=value` per line. A category that is off has no
    /// file.
    func files(for sharing: HostInfoSharing) -> [String: String] {
        var files: [String: String] = [:]
        if sharing.battery { files["battery"] = "percent=\(batteryPercent.map { String($0) } ?? "none")\n" }
        if sharing.power { files["power"] = "source=\(powerSource.rawValue)\nlowPowerMode=\(lowPowerMode ? 1 : 0)\n" }
        if sharing.thermal { files["thermal"] = "state=\(thermal.rawValue)\n" }
        if sharing.networkPath { files["network"] = network.map(Self.networkText) ?? "status=unknown\n" }
        if sharing.timeZone { files["timezone"] = "identifier=\(timeZone)\n" }
        return files
    }

    private static func networkText(_ path: HostNetworkPath) -> String {
        "status=\(path.isSatisfied ? "satisfied" : "unsatisfied")\ninterface=\(path.interface.rawValue)\n"
            + "expensive=\(path.isExpensive ? 1 : 0)\nconstrained=\(path.isConstrained ? 1 : 0)\n"
    }
}
