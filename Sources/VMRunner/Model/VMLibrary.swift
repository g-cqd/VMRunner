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

    private let machinesDirectory: URL

    init(machinesDirectory: URL = AppPaths.machines) {
        self.machinesDirectory = machinesDirectory
    }

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
        let bundles = (try? fileManager.contentsOfDirectory(at: machinesDirectory, includingPropertiesForKeys: nil)) ?? []
        machines =
            bundles
            .filter { $0.pathExtension == "vm" }
            .compactMap(loadConfig)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = selection ?? machines.first?.id
        discardAllEphemeral()
    }

    /// Reads one bundle's config, skipping any whose folder name doesn't match its id (a stray copy would
    /// otherwise alias the original and deleting it would delete the original's disk).
    private func loadConfig(in directory: URL) -> VMConfig? {
        do {
            let config = try VMConfig.decode(from: Data(contentsOf: directory.appending(path: "config.json")))
            guard directory.lastPathComponent == "\(config.id.uuidString).vm" else {
                Log.storage.error("Ignoring \(directory.lastPathComponent, privacy: .private): name doesn't match its id")
                return nil
            }
            return config
        } catch {
            Log.storage.error(
                "Couldn't read \(directory.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
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
        insert(config)
    }

    func update(_ config: VMConfig) {
        guard let index = machines.firstIndex(where: { $0.id == config.id }) else { return }
        // Secure Boot lives in the firmware variable store, not in the VZ configuration, so the framework
        // can't tell that saved state no longer matches. Drop it.
        if machines[index].secureBoot != config.secureBoot { bundle(config.id).discardSavedState() }
        machines[index] = config
        do {
            try persist(config)
        } catch {
            Log.storage.error("Couldn't save settings: \(error.localizedDescription, privacy: .public)")
            alertMessage = "Couldn't save “\(config.name)”: \(error.localizedDescription)"
        }
    }

    private func persist(_ config: VMConfig) throws {
        try config.encoded().write(to: bundle(config.id).config, options: .atomic)
    }

    private func insert(_ config: VMConfig) {
        machines.append(config)
        machines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = config.id
    }

    func delete(_ id: UUID) {
        if controllers[id]?.isActive == true { return }
        jobs[id]?.cancel()
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
            try copy.encoded().write(to: staged.config, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination.url)
        } catch {
            source.remove(staging)
            throw error
        }
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
                Log.machine.error("Setup failed: \(error.localizedDescription, privacy: .public)")
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

    func startMachine(_ id: UUID) {
        guard let config = machine(id), config.isProvisioned, jobs[id] == nil else { return }
        let controller = controller(for: id)
        let windowSize = displayHint
        Task { await controller.start(config, bundle: bundle(id), library: self, windowSize: windowSize) }
    }

    func suspendMachine(_ id: UUID) {
        let controller = controller(for: id)
        let bundle = bundle(id)
        Task { await controller.suspend(to: bundle) }
    }

    var runningCount: Int { controllers.values.filter(\.isActive).count }
}
