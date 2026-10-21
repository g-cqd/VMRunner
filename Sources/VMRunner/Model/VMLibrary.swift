import Foundation
import Observation
import SwiftUI
import Virtualization
import os

/// The machines on disk, their controllers, and any setup in progress.
@MainActor @Observable
final class VMLibrary {
    static let shared = VMLibrary()

    private(set) var machines: [VMConfig] = []
    @ObservationIgnored private var controllers: [UUID: VMController] = [:]
    @ObservationIgnored private var models: [UUID: MachineModel] = [:]
    private(set) var jobs: [UUID: SetupJob] = [:]
    var selection: UUID?
    var showingNewMachine = false
    /// A failure worth telling the user about (for example a settings change that couldn't be saved).
    var alertMessage: String?
    /// Size in points of the detail pane, used to size the guest display at start.
    @ObservationIgnored var displayHint: CGSize?
    /// A start that waits for the user to approve host paths the app has not seen them choose.
    var pendingApproval: PendingApproval?

    /// Host paths in a machine's configuration that the user has not approved yet.
    struct PendingApproval: Identifiable {
        let id: UUID
        let name: String
        let grants: [HostPathGrant]

        var message: String {
            "“\(name)” gives the guest access to host paths you haven't approved in this app. A machine you copied from "
                + "elsewhere can name any file your account can read.\n\n"
                + grants.map { "• \($0.summary)" }.joined(separator: "\n")
        }
    }

    private let machinesDirectory: URL
    @ObservationIgnored private let persistence: ConfigPersistence
    @ObservationIgnored private var approvals: HostPathApprovals

    /// `approvalsFile` defaults to a file beside the machines folder (outside every bundle).
    init(machinesDirectory: URL = AppPaths.machines, saveDelay: Duration = .milliseconds(400), approvalsFile: URL? = nil) {
        self.machinesDirectory = machinesDirectory
        approvals = HostPathApprovals(
            file: approvalsFile
                ?? machinesDirectory.deletingLastPathComponent().appending(path: "\(machinesDirectory.lastPathComponent).approvals.json"))
        persistence = ConfigPersistence(quietPeriod: saveDelay, clock: ContinuousClock()) { config in
            try config.encoded().writePrivately(to: VMBundle(id: config.id, in: machinesDirectory).config)
        }
        persistence.onFailure = { [weak self] config, error in
            guard let self else { return }
            Log.storage.error(
                "Couldn't save settings (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            alertMessage = "Couldn't save “\(config.name)”: \(error.localizedDescription)"
        }
    }

    /// Writes any settings change that is still waiting for edits to pause. Call before reading the files on disk.
    func flushPendingWrites() { persistence.flush() }

    func bundle(_ id: UUID) -> VMBundle { VMBundle(id: id, in: machinesDirectory) }

    // MARK: Loading

    func load() {
        let fileManager = FileManager.default
        do {
            try AppPaths.createPrivateDirectory(machinesDirectory)
        } catch {
            alertMessage = "Couldn't create the machines folder: \(error.localizedDescription)"
            return
        }
        let entries =
            (try? fileManager.contentsOfDirectory(at: machinesDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        machines =
            entries
            .filter { $0.pathExtension == "vm" }
            .filter(isNotSymbolicLink)
            .compactMap(loadConfig)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = selection ?? machines.first?.id
        discardAllEphemeral()
        // An upgrade: machines that exist before approvals were ever recorded are the user's own.
        recordApprovals { try $0.grandfather(machines) }
    }

    /// Runs `change` on the approvals and reports a failure to save them.
    private func recordApprovals(_ change: (inout HostPathApprovals) throws -> Void) {
        do {
            try change(&approvals)
        } catch {
            Log.storage.error("Couldn't save host path approvals: \(error.localizedDescription, privacy: .private)")
            alertMessage = "Couldn't save which host folders and disks you approved: \(error.localizedDescription)"
        }
    }

    /// Records that the user chose these paths for the machine. Call it only from what the user did (a file picker, the
    /// New Machine sheet), never from a settings change that may come from a file on disk.
    func approveHostPaths(_ grants: [HostPathGrant], for id: UUID) {
        recordApprovals { try $0.approve(grants, for: id) }
    }

    /// A bundle must be a real folder in the machines folder: a link could point anywhere and be repointed after the check.
    private func isNotSymbolicLink(_ entry: URL) -> Bool {
        guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return true }
        Log.storage.error("Ignoring \(entry.lastPathComponent, privacy: .private): a bundle can't be a symbolic link")
        return false
    }

    /// Reads one bundle's config, skipping any whose folder name doesn't match its id (a stray copy would
    /// otherwise alias the original and deleting it would delete the original's disk).
    private func loadConfig(in directory: URL) -> VMConfig? {
        do {
            let config = try VMConfig.load(from: directory.appending(path: "config.json"))
            guard directory.lastPathComponent == "\(config.id.uuidString).vm" else {
                Log.storage.error("Ignoring \(directory.lastPathComponent, privacy: .private): name doesn't match its id")
                return nil
            }
            return config
        } catch {
            Log.storage.error(
                """
                Couldn't read \(directory.lastPathComponent, privacy: .private) (\(error.logKind, privacy: .public)): \
                \(error.localizedDescription, privacy: .private)
                """)
            return nil
        }
    }

    /// Removes disposable copies left behind by a crash or a forced quit.
    func discardAllEphemeral() {
        for machine in machines { bundle(machine.id).discardEphemeral() }
    }

    // MARK: Machines

    func machine(_ id: UUID) -> VMConfig? {
        machines.first { $0.id == id }
    }

    /// The view model for a machine's detail pane, created on first use.
    func model(for id: UUID) -> MachineModel {
        if let existing = models[id] { return existing }
        let model = MachineModel(id: id, library: self)
        models[id] = model
        return model
    }

    func controller(for id: UUID) -> VMController {
        if let existing = controllers[id] { return existing }
        let controller = VMController()
        controllers[id] = controller
        return controller
    }

    /// Two-way binding that persists every edit.
    func binding(for id: UUID) -> Binding<VMConfig>? {
        guard let current = machine(id) else { return nil }
        return Binding(
            get: { self.machine(id) ?? current },
            set: { self.update($0) }
        )
    }

    func add(_ config: VMConfig) throws {
        try bundle(config.id).create()
        try persist(config)
        // The user made this machine in the New Machine sheet, including a local installer image they picked there.
        var grants = config.hostGrants
        if case .local(let path) = config.source { grants.append(HostPathGrant(.installer, path, writable: false)) }
        approveHostPaths(grants, for: config.id)
        insert(config)
    }

    func update(_ config: VMConfig) {
        guard let index = machines.firstIndex(where: { $0.id == config.id }) else { return }
        let previous = machines[index]
        // Secure Boot lives in the firmware variable store, not in the VZ configuration, so the framework
        // can't tell that saved state no longer matches. Drop it. A different network device (NAT, none, or the
        // user-mode stack) is a different device configuration, which saved state can't be restored into.
        // Turning suspend off or disposable on promises that no memory image is kept (the exposure summary says so), so
        // the image already on disk goes too.
        let forbidsSavedState = (previous.allowsSuspend && !config.allowsSuspend) || (!previous.ephemeral && config.ephemeral)
        if previous.secureBoot != config.secureBoot || previous.networkMode != config.networkMode || forbidsSavedState {
            bundle(config.id).discardSavedState()
        }
        machines[index] = config
        persistence.schedule(config)
        // Rules edited while the machine runs reach its network stack at once; the controller ignores it when none runs.
        if previous.networkPolicy != config.networkPolicy { controllers[config.id]?.networkPolicyDidChange(config.networkPolicy) }
    }

    private func persist(_ config: VMConfig) throws {
        try config.encoded().writePrivately(to: bundle(config.id).config)
    }

    private func insert(_ config: VMConfig) {
        machines.append(config)
        machines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = config.id
    }

    func delete(_ id: UUID) {
        if controllers[id]?.isActive == true { return }
        jobs[id]?.cancel()
        persistence.discard(id)
        recordApprovals { try $0.forget(id) }
        bundle(id).remove(bundle(id).url)
        machines.removeAll { $0.id == id }
        controllers[id] = nil
        models[id] = nil
        jobs[id] = nil
        if selection == id { selection = machines.first?.id }
    }

    /// Copy-on-write clone (APFS) with a fresh identity.
    ///
    /// The clone is built under a temporary name and only renamed into place once its config and identifier
    /// are written, so a failure or a crash never leaves a half-made machine that shares the source's id.
    func duplicate(_ id: UUID) throws {
        guard var copy = machine(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        copy.macAddress = nil
        copy.lastDisplayWidth = nil
        copy.lastDisplayHeight = nil

        let source = bundle(id)
        let destination = bundle(copy.id)
        let staging = machinesDirectory.appending(path: ".\(UUID().uuidString).duplicate", directoryHint: .isDirectory)
        do {
            try APFS.clone(source.url, to: staging)
            let staged = VMBundle(url: staging)
            staged.discardSavedState()
            staged.discardEphemeral()
            let identifier =
                copy.guest == .macOS
                ? VZMacMachineIdentifier().dataRepresentation
                : VZGenericMachineIdentifier().dataRepresentation
            try identifier.write(to: staged.machineIdentifier)
            try copy.encoded().writePrivately(to: staged.config)
            try FileManager.default.moveItem(at: staging, to: destination.url)
        } catch {
            source.remove(staging)
            throw error
        }
        recordApprovals { try $0.inherit(from: id, to: copy.id) }
        insert(copy)
    }

    // MARK: Setup jobs

    func beginSetup(_ id: UUID) {
        guard let config = machine(id), jobs[id]?.isRunning != true else { return }
        let job = SetupJob()
        jobs[id] = job
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                try await Provisioner.run(config: config, library: self, job: job)
                jobs[id] = nil
            } catch  where Task.isCancelled || error is CancellationError {
                job.task = nil
                jobs[id] = nil
            } catch {
                Log.machine.error("Setup failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
                job.error = error.localizedDescription
            }
        }
    }

    func cancelJob(_ id: UUID) {
        jobs[id]?.cancel()
        jobs[id] = nil
    }

    // MARK: Machine control (shared by the toolbar, menu, and launch arguments)

    var selectedController: VMController? { selection.map { controller(for: $0) } }

    /// The host paths in the machine's configuration that the user has not approved.
    func unapprovedHostPaths(for id: UUID) -> [HostPathGrant] {
        machine(id).map { approvals.missing($0.hostGrants, for: id) } ?? []
    }

    /// Starts a machine, or, when its configuration names host paths the user has not approved, asks first (`interactive`)
    /// or refuses and logs (a launch argument has nobody to ask).
    func startMachine(_ id: UUID, interactive: Bool = true) {
        guard let config = machine(id), config.isProvisioned, jobs[id] == nil else { return }
        let unapproved = unapprovedHostPaths(for: id)
        guard unapproved.isEmpty else {
            if interactive {
                pendingApproval = PendingApproval(id: id, name: config.name, grants: unapproved)
            } else {
                let paths = unapproved.map(\.summary).joined(separator: ", ")
                Log.machine.error(
                    "Not starting “\(config.name, privacy: .private)”: host paths aren't approved: \(paths, privacy: .private)")
            }
            return
        }
        let controller = controller(for: id)
        let windowSize = displayHint
        Task { await controller.start(config, bundle: bundle(id), library: self, windowSize: windowSize) }
    }

    /// The user's answer "Approve and Start" to `pendingApproval`.
    func approvePendingAndStart() {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        approveHostPaths(pending.grants, for: pending.id)
        startMachine(pending.id)
    }

    func suspendMachine(_ id: UUID) {
        let controller = controller(for: id)
        let bundle = bundle(id)
        Task { await controller.suspend(to: bundle) }
    }

    var runningCount: Int { controllers.values.filter(\.isActive).count }
}
