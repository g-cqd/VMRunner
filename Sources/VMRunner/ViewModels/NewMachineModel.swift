import Foundation
import Observation

/// The draft behind the "New Machine" sheet: what the user picked, whether it is complete, and the config it produces.
@MainActor @Observable
final class NewMachineModel {
    enum MacSource: String, CaseIterable, Identifiable {
        case latest = "Latest supported"
        case ipswMe = "ipsw.me"
        case file = "Local .ipsw"
        var id: Self { self }
    }

    enum LinuxSource: Hashable {
        case catalog(String)
        case file
    }

    static let deviceDefaultsKey = AppSetting.ipswDeviceIdentifier.rawValue

    var config = VMConfig.new(name: "macOS", guest: .macOS)
    /// Whether the new machine is a virtual machine or a container. A container uses `container`, `commandLine` and
    /// `environmentText`; `config` then only carries its name and identity.
    var workload = WorkloadKind.vm
    var container = ContainerSpec()
    /// The command as typed on one line; `ContainerInput.arguments(from:)` splits it.
    var commandLine = ""
    /// The environment as typed, one `NAME=value` per line.
    var environmentText = ""
    var macSource = MacSource.latest
    var linuxSource: LinuxSource
    var deviceIdentifier: String
    var selectedBuild: String?
    var localPath: String?
    /// A Windows machine's driver disc: an ISO attached as a second, read-only USB drive. Optional.
    var driverDiscPath: String?
    /// The SHA-256 the person expects the Windows installer to have, as typed. Empty: the installer is not checked.
    var expectedSHA256 = ""
    /// True while the installer is being hashed before a Windows machine is made.
    private(set) var isVerifying = false
    private(set) var firmwares: [IPSWFirmware] = []
    private(set) var isLoadingFirmwares = false
    private(set) var loadError: String?
    private(set) var creationError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = PreferencesDomain.defaults) {
        self.defaults = defaults
        linuxSource = LinuxCatalog.images.first.map { .catalog($0.id) } ?? .file
        let stored = defaults.string(forKey: Self.deviceDefaultsKey) ?? ""
        deviceIdentifier = stored.isEmpty ? IPSWCatalog.hostModelIdentifier : stored
    }

    // MARK: Derived

    var canCreate: Bool {
        let name = config.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= EditorLimits.maxTextLength, !isVerifying else { return false }
        if workload == .container { return containerProblem == nil }
        switch config.guest {
        case .macOS:
            switch macSource {
            case .latest: return true
            case .ipswMe: return selectedBuild != nil
            case .file: return hasStorableLocalPath
            }
        case .linux:
            if case .file = linuxSource { return hasStorableLocalPath }
            return true
        case .windows:
            return hasStorableLocalPath && InstallerDigest.problem(in: expectedSHA256) == nil
                && (driverDiscPath.map(Self.canStore) ?? true)
        }
    }

    /// A configuration refuses a local file whose path is not absolute, or longer than a host path can be.
    static func canStore(localPath path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= EditorLimits.maxPathLength
    }

    private var hasStorableLocalPath: Bool { localPath.map(Self.canStore) ?? false }

    /// The config for the current choices, with its media source filled in.
    func makeConfig() -> VMConfig {
        var machine = config
        machine.name = machine.name.trimmingCharacters(in: .whitespaces)
        switch machine.guest {
        case .macOS:
            switch macSource {
            case .latest: machine.source = .latestMac
            case .ipswMe: machine.source = firmwares.first { $0.buildid == selectedBuild }?.source
            case .file: machine.source = localPath.map(ImageSource.local)
            }
        case .linux:
            switch linuxSource {
            case .catalog(let id): machine.source = .linuxCatalog(id: id)
            case .file: machine.source = localPath.map(ImageSource.local)
            }
        case .windows:
            // A Windows machine installs from a file on this Mac; the sheet has no other source to offer.
            machine.source = localPath.map(ImageSource.local)
            machine.driverDiscPath = driverDiscPath
        }
        return machine
    }

    /// The config of a container machine for the current choices, checked by the same rules a stored configuration is.
    func makeContainerConfig() throws -> VMConfig {
        var machine = VMConfig.newContainer(name: config.name.trimmingCharacters(in: .whitespaces), container: container)
        machine.id = config.id
        return try ContainerDraft(spec: container, commandLine: commandLine, environmentText: environmentText).applied(to: machine)
    }

    /// What is wrong with the container settings as they stand, or `nil` when a container machine can be made.
    var containerProblem: String? {
        do {
            _ = try makeContainerConfig()
            return nil
        } catch {
            return VMConfig.reason(for: error)
        }
    }

    // MARK: Actions

    /// Takes the file the user picked as the installation media, unless a configuration could not store its location.
    func chooseLocalFile(_ url: URL) {
        guard url.isFileURL, Self.canStore(localPath: url.path) else {
            creationError = "That file's location can't be used. Pick a file on this Mac."
            return
        }
        localPath = url.path
        creationError = nil
    }

    /// Takes the file the user picked as a Windows machine's driver disc, unless a configuration could not store its location or
    /// it lies inside the Machines folder, where the app keeps its own files.
    func chooseDriverDisc(_ url: URL) {
        guard url.isFileURL, Self.canStore(localPath: url.path), !AppPaths.isInside(url, AppPaths.machines) else {
            creationError = "That file's location can't be used. Pick a file on this Mac, outside the Machines folder."
            return
        }
        driverDiscPath = url.path
        creationError = nil
    }

    /// Switching guest resets the resources to that guest's defaults but keeps a name the user typed.
    func guestChanged(to guest: GuestOS) {
        let name = config.name
        let id = config.id
        config = .new(name: GuestOS.allCases.map(\.label).contains(name) ? guest.label : name, guest: guest)
        config.id = id
        clearMedia()
    }

    private func clearMedia() {
        localPath = nil
        driverDiscPath = nil
        expectedSHA256 = ""
    }

    /// Switching to a container renames a placeholder name; switching back to a virtual machine restores that guest's defaults,
    /// as `guestChanged(to:)` does, and gives a placeholder name back.
    func workloadChanged(to workload: WorkloadKind) {
        let name = config.name
        switch workload {
        case .container:
            if GuestOS.allCases.map(\.label).contains(name) { config.name = WorkloadKind.container.label }
        case .vm:
            let id = config.id
            config = .new(name: name == WorkloadKind.container.label ? config.guest.label : name, guest: config.guest)
            config.id = id
            clearMedia()
        }
        creationError = nil
    }

    func loadFirmwares() async {
        isLoadingFirmwares = true
        loadError = nil
        defaults.set(deviceIdentifier, forKey: Self.deviceDefaultsKey)
        defer { isLoadingFirmwares = false }
        do {
            firmwares = try await IPSWCatalog.firmwares(for: deviceIdentifier)
            selectedBuild = firmwares.first?.buildid
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Adds the machine to the library and, for a virtual machine, starts its setup. Returns false and sets `creationError` on
    /// failure. A Windows machine whose installer has an expected SHA-256 is made by `createAfterVerifying(in:)` only: this
    /// refuses it, so no path makes one without the check.
    func create(in library: VMLibrary) -> Bool {
        if workload == .vm, config.guest == .windows, !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            creationError = "The installer's SHA-256 has not been checked yet."
            return false
        }
        return add(to: library)
    }

    /// What the Create button calls. A Windows machine's installer is hashed first, away from the main actor, when an expected
    /// SHA-256 was typed; the machine is made only if it matches. Cancelling the task stops the hashing and makes nothing.
    func createAfterVerifying(in library: VMLibrary) async -> Bool {
        guard workload == .vm, config.guest == .windows else { return create(in: library) }
        isVerifying = true
        defer { isVerifying = false }
        do {
            if let localPath { try await InstallerDigest.verify(URL(filePath: localPath), against: expectedSHA256) }
            try Task.checkCancellation()
        } catch is CancellationError {
            return false
        } catch {
            creationError = VMConfig.reason(for: error)
            return false
        }
        return add(to: library)
    }

    private func add(to library: VMLibrary) -> Bool {
        do {
            if workload == .container {
                // A container machine has nothing to install: it is ready as soon as it is added.
                try library.add(makeContainerConfig())
                return true
            }
            let machine = makeConfig()
            if machine.guest == .windows { try machine.validate() }
            try library.add(machine)
            library.beginSetup(machine.id)
            return true
        } catch {
            creationError = VMConfig.reason(for: error)
            return false
        }
    }
}
