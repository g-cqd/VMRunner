import os

/// Unified-logging categories. Paths and identifiers are logged `.private`, so they are redacted in
/// logs collected from a user's machine.
enum Log {
    private static let subsystem = "dev.g-cqd.VMRunner"

    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let machine = Logger(subsystem: subsystem, category: "machine")
}
