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

    static let deviceDefaultsKey = "ipswDeviceIdentifier"

    var config = VMConfig.new(name: "macOS", guest: .macOS)
    var macSource = MacSource.latest
    var linuxSource: LinuxSource
    var deviceIdentifier: String
    var selectedBuild: String?
    var localPath: String?
    private(set) var firmwares: [IPSWFirmware] = []
    private(set) var isLoadingFirmwares = false
    private(set) var loadError: String?
    private(set) var creationError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        linuxSource = LinuxCatalog.images.first.map { .catalog($0.id) } ?? .file
        let stored = defaults.string(forKey: Self.deviceDefaultsKey) ?? ""
        deviceIdentifier = stored.isEmpty ? IPSWCatalog.hostModelIdentifier : stored
    }

    // MARK: Derived

    var canCreate: Bool {
        guard !config.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch config.guest {
        case .macOS:
            switch macSource {
            case .latest: return true
            case .ipswMe: return selectedBuild != nil
            case .file: return localPath != nil
            }
        case .linux:
            if case .file = linuxSource { return localPath != nil }
            return true
        }
    }

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
        }
        return machine
    }

    // MARK: Actions

    /// Switching guest resets the resources to that guest's defaults but keeps a name the user typed.
    func guestChanged(to guest: GuestOS) {
        let name = config.name
        let id = config.id
        config = .new(name: name == "macOS" || name == "Linux" ? guest.label : name, guest: guest)
        config.id = id
        localPath = nil
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

    /// Adds the machine to the library and starts its setup. Returns false and sets `creationError` on failure.
    func create(in library: VMLibrary) -> Bool {
        let machine = makeConfig()
        do {
            try library.add(machine)
            library.beginSetup(machine.id)
            return true
        } catch {
            creationError = error.localizedDescription
            return false
        }
    }
}
