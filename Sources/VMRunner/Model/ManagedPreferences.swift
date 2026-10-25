import Foundation

/// A machine setting an organisation can restrict through managed preferences (ADR-0013). The raw value is the key a
/// configuration profile forces in the app's domain.
enum ManagedKey: String, CaseIterable, Sendable {
    case allowSharedFolders = "AllowSharedFolders"
    case allowClipboardSharing = "AllowClipboardSharing"
    case allowMicrophone = "AllowMicrophone"
    case allowSuspend = "AllowSuspend"
    case allowHostInformation = "AllowHostInformation"
    case allowControlService = "AllowControlService"
    case allowProvisioning = "AllowProvisioning"
    case allowContainers = "AllowContainers"
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
    /// The longest run `MaxRuntimeMinutes` allows, when it is forced to a limit; nil when it is not forced or forced to 0.
    private(set) var maxRuntimeMinutes: Int?
    /// The app's own settings whose value the organisation forced.
    private(set) var forcedSettings: Set<AppSetting> = []

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
                maxRuntimeMinutes = Self.runtimeLimit(forced: value)
            default:
                if (value as? Bool) != true { denied.insert(key) }
            }
        }
        forcedSettings = Set(AppSetting.allCases.filter { forcedValue($0.rawValue) != nil })
    }

    /// The limit a forced `MaxRuntimeMinutes` sets. 0 sets none: the organisation imposes no cap, and the control stays
    /// unlocked. Any other value that is not a whole number from 15 to 1440 (a Boolean, a string, a negative number, a
    /// number out of range) becomes the shortest limit, 15 minutes: a value of the wrong type restricts.
    private static func runtimeLimit(forced value: Any) -> Int? {
        // A Boolean bridges to 0 or 1 as a number: tell it apart first, so a forced `false` never reads as no limit.
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let minutes = value as? Int else {
            return EditorLimits.runtimeStepMinutes
        }
        if minutes == 0 { return nil }
        let offered = EditorLimits.runtimeStepMinutes...EditorLimits.runtimeMinutes.upperBound
        return offered.contains(minutes) ? minutes : EditorLimits.runtimeStepMinutes
    }

    /// The policy forced in the app's own domain now. Cheap enough to read when a view is drawn.
    static var current: Self { Self() }

    /// What a locked control's tooltip says.
    static let lockedHelp = "Set by your organisation. Ask your administrator to change it."

    /// Why a container will not start while `AllowContainers` is forced off.
    static let containersDeniedMessage = "Your organisation doesn't allow containers on this Mac. Ask your administrator to change it."

    /// The kinds a new machine can be: a container only while the organisation allows containers.
    var offeredWorkloads: [WorkloadKind] {
        WorkloadKind.allCases.filter { $0 != .container || !denied.contains(.allowContainers) }
    }

    /// Whether the control for `key` is locked: the organisation restricted it.
    func isLocked(_ key: ManagedKey) -> Bool {
        switch key {
        case .requireDisposableMachines: requiresDisposable
        case .maxRuntimeMinutes: maxRuntimeMinutes != nil
        default: denied.contains(key)
        }
    }

    /// Whether the control for one of the app's own settings is locked: the organisation forced its value.
    func isLocked(_ setting: AppSetting) -> Bool { forcedSettings.contains(setting) }

    /// `config` with every forced restriction applied; whatever the policy allows is left as it is.
    func clamp(_ config: VMConfig) -> VMConfig {
        var config = config
        if denied.contains(.allowSharedFolders) { config.sharedFolders = [] }
        if denied.contains(.allowClipboardSharing) { config.sharesClipboard = false }
        if denied.contains(.allowMicrophone) { config.audioInput = false }
        if denied.contains(.allowSuspend) { config.allowsSuspend = false }
        if denied.contains(.allowHostInformation) { config.hostInfo = HostInfoSharing() }
        if denied.contains(.allowControlService) { config.agentAccess = false }
        if denied.contains(.allowProvisioning) { config.provisioningSpecPath = "" }
        if requiresDisposable { config.ephemeral = true }
        if let limit = maxRuntimeMinutes, config.maxRuntimeMinutes == 0 || config.maxRuntimeMinutes > limit {
            config.maxRuntimeMinutes = limit
        }
        return config
    }
}
