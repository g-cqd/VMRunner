import ControlProtocol
import Foundation
import GuestConsole
import Observation
import os

/// The local control service (ADR-0056): scripts and AI agents reach it on a private socket in the app's data folder, present
/// a capability token, and act only on machines whose agent access is on. It runs only while the user has turned it on in
/// Settings and the organisation allows it.
@MainActor @Observable
final class ControlService {
    static let shared = ControlService(directory: AppPaths.control, machines: LibraryControlMachines(library: .shared))

    /// The socket's path while the service listens; nil while it is off.
    private(set) var socketPath: String?
    /// Why the service could not start, for Settings; nil while it runs or is off.
    private(set) var failure: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let machines: any ControlMachines
    @ObservationIgnored private let limits: ControlLimits
    @ObservationIgnored private var store: ControlTokenStore?
    @ObservationIgnored private var listener: ControlListener?
    /// A stop that is still waiting for its socket to go; a start waits for it, or it would find the old socket still served.
    @ObservationIgnored private var stopping: Task<Void, Never>?

    init(directory: URL, machines: any ControlMachines, limits: ControlLimits = ControlLimits()) {
        self.directory = directory
        self.machines = machines
        self.limits = limits
    }

    /// Whether the service should run: the user turned it on, and the organisation did not keep it off.
    static func isEnabled(defaults: UserDefaults, policy: ManagedPreferences) -> Bool {
        defaults.bool(forKey: AppSetting.runsControlService.rawValue) && !policy.isLocked(.allowControlService)
    }

    /// The tokens, read from the private folder the first time they are needed; the folder is created then (0700).
    func tokenStore() throws -> ControlTokenStore {
        if let store { return store }
        try AppPaths.createPrivateDirectory(directory)
        let made = try ControlTokenStore(file: directory.appending(path: "tokens.json"))
        store = made
        return made
    }

    /// Starts or stops the service to match the setting and the organisation's policy. A stop still in progress is waited for
    /// first; the setting is read after that, with nothing awaited between the read and the action.
    func applySetting() async {
        while let pending = stopping { await pending.value }
        await setRunning(Self.isEnabled(defaults: PreferencesDomain.defaults, policy: .current))
    }

    /// Starts the service, or stops it and returns once its socket is gone. Nothing is awaited before the start, so the value
    /// the caller read is the one acted on.
    func setRunning(_ on: Bool) async {
        while let pending = stopping { await pending.value }
        if on { start() } else { await stop() }
    }

    /// Stops listening without waiting, for the app's last moment; a socket left behind is removed at the next start.
    func stopAtQuit() {
        listener?.stop()
        listener = nil
        socketPath = nil
    }

    private func start() {
        guard listener == nil else { return }
        let socket = directory.appending(path: "control.sock").path
        do {
            let dispatcher = ControlDispatcher(tokens: try tokenStore(), machines: machines, report: Self.log)
            let connection = ControlConnection(dispatcher: dispatcher, limits: limits)
            listener = try ControlListener(path: socket, connection: connection, limits: limits)
            socketPath = socket
            failure = nil
            Log.control.notice("The control service listens at \(socket, privacy: .private)")
        } catch {
            let reason = (error as? ConsoleError)?.description ?? error.localizedDescription
            failure = reason
            Log.control.error("The control service could not start: \(reason, privacy: .private)")
        }
    }

    private func stop() async {
        failure = nil
        guard let listener else { return }
        self.listener = nil
        socketPath = nil
        listener.stop()
        let task = Task { await listener.waitUntilStopped() }
        stopping = task
        await task.value
        stopping = nil
        Log.control.notice("The control service stopped")
    }

    /// Every refusal of a token, a capability or a machine's access is logged: what was asked and why in the clear, the
    /// token's and the machine's ids redacted. A refusal holds no token, so none can be logged.
    nonisolated private static func log(_ denial: ControlDenial) {
        let token = denial.tokenID?.uuidString ?? "none"
        let machine = denial.machine?.uuidString ?? "none"
        Log.control.notice(
            "Refused \(denial.summary, privacy: .public); token \(token, privacy: .private), machine \(machine, privacy: .private)")
    }
}
