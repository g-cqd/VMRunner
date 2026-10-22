import Foundation

/// The defaults domain the app's settings live in. A run with `VMRUNNER_DATA_DIR` set keeps them in a domain of its own,
/// the app's identifier followed by `overrideSuffix`, so that a run for testing never changes the owner's settings.
enum PreferencesDomain {
    static let overrideSuffix = ".data-directory-override"

    /// The domain for `environment`: nil (the app's standard domain) unless `VMRUNNER_DATA_DIR` is set and not empty.
    static func suiteName(environment: [String: String], appIdentifier: String) -> String? {
        guard let value = environment[AppPaths.dataDirectoryVariable], !value.isEmpty else { return nil }
        return appIdentifier + overrideSuffix
    }

    /// Where every setting is read and written. A computed property, not a stored one: `UserDefaults` is not `Sendable`, and
    /// every instance of one domain reads and writes the same storage, so nothing is lost by making one per use.
    static var defaults: UserDefaults {
        guard let name = suiteName(environment: ProcessInfo.processInfo.environment, appIdentifier: Log.subsystem) else {
            return .standard
        }
        // Never nil: `UserDefaults(suiteName:)` refuses only the app's own identifier and the global domain.
        return UserDefaults(suiteName: name) ?? .standard
    }
}
