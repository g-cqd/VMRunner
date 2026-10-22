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
    @ObservationIgnored private var hasLoaded = false
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

    /// How a setup job's work is done; a test supplies its own to hold a job open.
    typealias Provision = @MainActor (VMConfig, any MachineStore, SetupJob) async throws -> Void

    private let machinesDirectory: URL
    @ObservationIgnored private let persistence: ConfigPersistence
    @ObservationIgnored private var approvals: HostPathApprovals
    @ObservationIgnored private let makeController: @MainActor () -> VMController
    @ObservationIgnored private let provision: Provision
    /// What the organisation forced; every configuration the library holds is within it.
    @ObservationIgnored private let managed: ManagedPreferences

    /// `approvalsFile` defaults to a file beside the machines folder (outside every bundle). `makeController` and `provision`
    /// default to the real controller and the real provisioner, and `managed` to the policy forced in the app's domain.
    init(
        machinesDirectory: URL = AppPaths.machines, saveDelay: Duration = .milliseconds(400), approvalsFile: URL? = nil,
        managed: ManagedPreferences = ManagedPreferences(),
        makeController: @escaping @MainActor () -> VMController = { VMController() },
        provision: @escaping Provision = { try await Provisioner.run(config: $0, library: $1, job: $2) }
    ) {
        self.machinesDirectory = machinesDirectory
        self.makeController = makeController
        self.provision = provision
        self.managed = managed
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

    /// Reads the machines folder, once. Every window runs the load task as it opens, and a second run would replace the machines
    /// in memory with what is on disk, losing settings that are still waiting to be written, and read every file again. Later
    /// calls return at once; a call that failed to reach the folder is tried again.
    func load() {
        guard !hasLoaded else { return }
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
            .map { managed.clamp($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = selection ?? machines.first?.id
        discardAllEphemeral()
        // An upgrade: machines that exist before approvals were ever recorded are the user's own.
        recordApprovals { try $0.grandfather(machines) }
        migrateFlatCacheInstallers()
        hasLoaded = true
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

    /// Removes disposable copies left behind by a crash or a forced quit. A machine that runs keeps its copy: it is the disk
    /// the guest is using, and a second window running the load task again must not pull it away.
    func discardAllEphemeral() {
        for machine in machines where controllers[machine.id]?.isActive != true { bundle(machine.id).discardEphemeral() }
    }

    /// The app is quitting: every controller lets go of what its machine holds. The machines go with the process.
    func prepareToQuit() {
        for controller in controllers.values { controller.quit() }
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
        let controller = makeController()
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

    func add(_ proposed: VMConfig) throws {
        let config = managed.clamp(proposed)
        try bundle(config.id).create()
        try persist(config)
        // The user made this machine in the New Machine sheet, including a local installer image they picked there.
        var grants = config.hostGrants
        if case .local(let path) = config.source { grants.append(HostPathGrant(.installer, path, writable: false)) }
        approveHostPaths(grants, for: config.id)
        insert(config)
    }

    func update(_ proposed: VMConfig) {
        let config = managed.clamp(proposed)
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
        // A clone of a disk the guest is writing is not a consistent disk.
        guard controllers[id]?.isActive != true else { throw LibraryError.machineInUse }
        copy.id = UUID()
        // The name stays within what a stored configuration may hold, or the copy would not load again.
        let suffix = " Copy"
        copy.name = String(copy.name.prefix(EditorLimits.maxTextLength - suffix.count)) + suffix
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

    /// Starts the setup of a machine. A job that is still in the table, running, failed or unwinding after a cancel, blocks it:
    /// two runs on one bundle would write the same disk.
    func beginSetup(_ id: UUID) {
        guard let config = machine(id), jobs[id] == nil else { return }
        let job = SetupJob()
        jobs[id] = job
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                try await provision(config, self, job)
                finish(job, for: id)
            } catch  where Task.isCancelled || error is CancellationError {
                finish(job, for: id)
            } catch {
                Log.machine.error("Setup failed (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
                job.error = error.localizedDescription
                job.isFinished = true
            }
        }
    }

    /// A job's work is over: it leaves the table, unless a later job has taken its place.
    private func finish(_ job: SetupJob, for id: UUID) {
        job.isFinished = true
        if jobs[id] === job { jobs[id] = nil }
    }

    /// Asks a setup to stop. A job that is still unwinding stays in the table until its work ends, so Resume Setup cannot
    /// start a second run on top of it; a job that already ended (it failed) goes at once.
    func cancelJob(_ id: UUID) {
        guard let job = jobs[id] else { return }
        job.cancel()
        if job.isFinished { jobs[id] = nil }
    }

    // MARK: Machine control (shared by the toolbar, menu, and launch arguments)

    var selectedController: VMController? { selection.map { controller(for: $0) } }

    /// The machine `--start` names, or nil after saying why there is none to start: in the log, for a script that reads it, and in
    /// the library alert, for whoever is at the window. A launch argument has nobody to ask, so a refusal must not be silent.
    func machineToStart(forLaunchArgument key: String) -> UUID? {
        switch LaunchStart.decide(key, in: machines, settingUp: Set(jobs.keys)) {
        case .start(let id):
            return id
        case .refuse(let refusal):
            Log.machine.error("--start: \(refusal.logReason, privacy: .public)")
            alertMessage = refusal.message
            return nil
        }
    }

    /// The host paths in the machine's configuration that the user has not approved.
    func unapprovedHostPaths(for id: UUID) -> [HostPathGrant] {
        machine(id).map { approvals.missing($0.hostGrants, for: id) } ?? []
    }

    /// Starts a machine, or, when its configuration names host paths the user has not approved, asks first (`interactive`)
    /// or refuses and logs (a launch argument has nobody to ask).
    func startMachine(_ id: UUID, interactive: Bool = true) {
        guard let config = machine(id), config.isProvisioned, jobs[id] == nil, controller(for: id).state.canStart else { return }
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
        Task { await controller.suspend() }
    }

    var runningCount: Int { controllers.values.filter(\.isActive).count }
}

extension VMLibrary {
    /// Gives each machine made before machines kept their own installer (ADR-0031) a clone of it in its bundle. Such a machine
    /// stores the path of a file directly in the old flat image cache, which clearing the downloaded images removes. Only a path
    /// the user approved for that machine is migrated, so a copied bundle cannot get a file of the cache cloned into it, and
    /// the clone is approved too. A machine whose file is gone, or whose clone fails, is left as it is.
    func migrateFlatCacheInstallers(imagesDirectory: URL = AppPaths.images) {
        for config in machines {
            guard let path = config.installerISO, ImageStore.isInFlatCache(path, imagesDirectory: imagesDirectory),
                approvals.missing([HostPathGrant(.installer, path, writable: false)], for: config.id).isEmpty
            else { continue }
            do {
                let kept = try ImageStore.keepInstaller(URL(filePath: path), in: bundle(config.id))
                approveHostPaths([HostPathGrant(.installer, kept.path, writable: false)], for: config.id)
                var migrated = config
                migrated.installerISO = kept.path
                update(migrated)
            } catch {
                Log.storage.notice("Kept a machine's old installer path: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}

/// Why the library refused to do something to a machine.
enum LibraryError: LocalizedError {
    case machineInUse

    var errorDescription: String? {
        switch self {
        case .machineInUse: "Stop the machine first: a running machine's disk is changing."
        }
    }
}
