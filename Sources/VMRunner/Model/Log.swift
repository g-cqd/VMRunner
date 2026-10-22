import Foundation
import os

/// Unified-logging categories. Paths and identifiers are logged `.private`, so they are redacted in
/// logs collected from a user's machine.
enum Log {
    /// The identifier `Resources/Info.plist` gives the app. It is a placeholder; a test keeps the two in step.
    static let fallbackSubsystem = "com.example.VMRunner"
    /// The built app logs under its own bundle identifier, so the subsystem follows whatever the plist says. Outside the
    /// built app (tests, `swift run`) there is no such identifier and the placeholder stands in.
    static let subsystem = Bundle.main.bundleIdentifier.flatMap { $0.hasPrefix("com.apple.") ? nil : $0 } ?? fallbackSubsystem

    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let machine = Logger(subsystem: subsystem, category: "machine")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let display = Logger(subsystem: subsystem, category: "display")
}

extension Error {
    /// What kind of failure this is, safe to log in the clear: the error domain and code, never the description, which
    /// often names a host path (log that one `.private`).
    var logKind: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
