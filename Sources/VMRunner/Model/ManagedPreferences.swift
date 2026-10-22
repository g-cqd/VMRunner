import Foundation

/// A machine setting an organisation can restrict through managed preferences (ADR-0013). The raw value is the key a
/// configuration profile forces in the app's domain.
enum ManagedKey: String, CaseIterable, Sendable {
    case allowSharedFolders = "AllowSharedFolders"
    case allowClipboardSharing = "AllowClipboardSharing"
    case allowMicrophone = "AllowMicrophone"
    case allowSuspend = "AllowSuspend"
    case allowHostInformation = "AllowHostInformation"
    case requireDisposableMachines = "RequireDisposableMachines"
    case maxRuntimeMinutes = "MaxRuntimeMinutes"
}

/// What an organisation forced in the app's managed preferences, read once. Only a forced value is policy
/// (`UserDefaults.objectIsForced(forKey:)`); a value the user wrote never is. A forced value of the wrong type restricts.
struct ManagedPreferences: Equatable, Sendable {
    /// The `Allow…` keys forced to anything but `true`.
    private(set) var denied: Set<ManagedKey> = []
    /// `RequireDisposableMachines` forced to anything but `false`.
    private(set) var requiresDisposable = false
    /// The longest run `MaxRuntimeMinutes` allows, when it is forced.
    private(set) var maxRuntimeMinutes: Int?

    /// Reads the keys forced in `defaults`: by default the app's own domain, which a configuration profile targets, so a
    /// run that keeps its settings in a domain of its own (`VMRUNNER_DATA_DIR`) obeys the same policy.
    init(reading defaults: UserDefaults = .standard) {
        self.init(forcedValue: { defaults.objectIsForced(forKey: $0) ? defaults.object(forKey: $0) : nil })
    }

    /// `forcedValue` returns a key's forced value, or nil when the key is not forced.
    init(forcedValue: (String) -> Any?) {
        for key in ManagedKey.allCases {
            guard let value = forcedValue(key.rawValue) else { continue }
            switch key {
            case .requireDisposableMachines:
                requiresDisposable = (value as? Bool) != false
            case .maxRuntimeMinutes:
                // A value that is not a whole number, or lies outside what the editor offers, becomes the shortest limit.
                let offered = EditorLimits.runtimeStepMinutes...EditorLimits.runtimeMinutes.upperBound
                maxRuntimeMinutes = (value as? Int).flatMap { offered.contains($0) ? $0 : nil } ?? EditorLimits.runtimeStepMinutes
            default:
                if (value as? Bool) != true { denied.insert(key) }
            }
        }
    }

    /// `config` with every forced restriction applied; whatever the policy allows is left as it is.
    func clamp(_ config: VMConfig) -> VMConfig {
        var config = config
        if denied.contains(.allowSharedFolders) { config.sharedFolders = [] }
        if denied.contains(.allowClipboardSharing) { config.sharesClipboard = false }
        if denied.contains(.allowMicrophone) { config.audioInput = false }
        if denied.contains(.allowSuspend) { config.allowsSuspend = false }
        if denied.contains(.allowHostInformation) { config.hostInfo = HostInfoSharing() }
        if requiresDisposable { config.ephemeral = true }
        if let limit = maxRuntimeMinutes, config.maxRuntimeMinutes == 0 || config.maxRuntimeMinutes > limit {
            config.maxRuntimeMinutes = limit
        }
        return config
    }
}
