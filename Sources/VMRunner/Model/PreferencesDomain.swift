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

    /// Whether this run keeps its settings out of the standard domain. Such a run also neither autosaves its main window's
    /// frame nor restores its windows, which AppKit would record in the standard domain and the saved application state.
    static var isSeparate: Bool { suiteName(environment: ProcessInfo.processInfo.environment, appIdentifier: Log.subsystem) != nil }

    /// Registers (never writes) the defaults every launch needs. `ApplePersistenceIgnoreState` makes AppKit neither restore windows
    /// from saved application state nor save it: the app has no documents to restore, and a stale entry in the system's
    /// restoration store once made every launch open no window at all.
    static func registerLaunchDefaults(on defaults: UserDefaults = .standard) {
        defaults.register(defaults: [launchKey: true])
    }

    /// The AppKit key `registerLaunchDefaults` registers.
    static let launchKey = "ApplePersistenceIgnoreState"
}
