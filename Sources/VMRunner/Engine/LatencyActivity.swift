import Foundation

/// The part of `ProcessInfo` that starts and ends an activity, so a test can stand in for the process.
protocol ActivityHost {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: ActivityHost {}

/// Keeps macOS from slowing the app down while a machine runs.
///
/// An app the system thinks idle gets App Nap and its timers are coalesced, and either can add milliseconds before the
/// app hands a key press or a mouse move on to the guest. While at least one machine runs, this holds a
/// user-initiated, latency-critical activity. It deliberately leaves out the option that stops the Mac sleeping when it
/// is idle: the guest alone is no reason to keep the Mac awake.
///
/// Machines are counted by owner, so one activity serves any number of running machines and ends with the last.
@MainActor
final class LatencyActivity {
    /// The `UserDefaults` key of the setting in Settings.
    static let settingKey = "holdsLatencyActivity"

    static let options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]

    /// Whether the setting is on in `defaults`: on until the user turns it off.
    static func isSettingOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }

    static let shared = LatencyActivity(host: ProcessInfo.processInfo, isEnabled: isSettingOn())

    private let host: any ActivityHost
    private var owners = Set<ObjectIdentifier>()
    private var activity: (any NSObjectProtocol)?

    /// Turning it off ends a held activity; turning it on begins one if a machine runs.
    var isEnabled: Bool {
        didSet { update() }
    }

    /// Whether the activity is being held right now.
    var isHeld: Bool { activity != nil }

    init(host: any ActivityHost, isEnabled: Bool) {
        self.host = host
        self.isEnabled = isEnabled
    }

    /// A machine started running. Holding twice for the same owner counts once.
    func hold(for owner: ObjectIdentifier) {
        owners.insert(owner)
        update()
    }

    /// A machine stopped. Releasing an owner that holds nothing does nothing.
    func release(for owner: ObjectIdentifier) {
        owners.remove(owner)
        update()
    }

    private func update() {
        let wanted = isEnabled && !owners.isEmpty
        if wanted, !isHeld {
            activity = host.beginActivity(
                options: Self.options, reason: "A virtual machine is running and needs prompt keyboard and mouse input")
        } else if !wanted, let held = activity {
            host.endActivity(held)
            activity = nil
        }
    }
}
