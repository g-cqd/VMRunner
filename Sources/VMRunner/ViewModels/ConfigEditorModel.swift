import Foundation
import Observation

/// State and actions behind the settings form of a stopped machine.
@MainActor @Observable
final class ConfigEditorModel {
    enum PickerTarget: Identifiable {
        case extraDisk, installerISO
        var id: Self { self }
    }

    let id: UUID
    let snapshots: SnapshotsModel
    let network: NetworkPolicyModel
    var pickerTarget: PickerTarget?
    var alertMessage: String?
    private(set) var allocatedBytes: Int64 = 0
    /// Raw images can grow but never shrink, so the stepper floor is the size when the editor opened.
    private(set) var diskFloorGiB: Int

    // Unowned: the library (through its machine models) owns this model, so a strong reference would be a cycle.
    private unowned let library: VMLibrary

    init(id: UUID, library: VMLibrary) {
        self.id = id
        self.library = library
        diskFloorGiB = library.machine(id)?.diskGiB ?? 0
        snapshots = SnapshotsModel(bundle: library.bundle(id))
        network = NetworkPolicyModel(id: id, library: library)
    }

    var bundle: VMBundle { library.bundle(id) }
    var hasSavedState: Bool { bundle.hasSavedState }

    /// Called each time the form appears: resets the grow-only floor and refreshes the numbers.
    func opened() async {
        diskFloorGiB = library.machine(id)?.diskGiB ?? diskFloorGiB
        async let usage: Void = refreshUsage()
        await snapshots.reload()
        await usage
    }

    /// Measures the machine's folder off the main thread (it walks every file).
    func refreshUsage() async {
        let bundle = bundle
        allocatedBytes = await Task.detached(priority: .utility) { bundle.allocatedBytes }.value
    }

    /// Grows the disk image, or clamps a shrink request to the floor.
    func setDiskSize(_ gibibytes: Int) {
        guard var config = library.machine(id) else { return }
        guard gibibytes > config.diskGiB else {
            config.diskGiB = max(gibibytes, diskFloorGiB)
            library.update(config)
            return
        }
        do {
            try DiskImage.grow(at: bundle.disk, toGibibytes: gibibytes)
            config.diskGiB = gibibytes
            bundle.discardSavedState()
            library.update(config)
        } catch {
            alertMessage = "Couldn't grow the disk: \(error.localizedDescription)"
        }
    }

    /// Applies a restored snapshot's disk size to the settings.
    func didRestore(_ snapshot: Snapshot) {
        guard var config = library.machine(id) else { return }
        config.diskGiB = snapshot.diskGiB
        diskFloorGiB = snapshot.diskGiB
        library.update(config)
    }

    /// Applies the file the user picked for `target`.
    func importFile(_ url: URL, for target: PickerTarget?) {
        guard var config = library.machine(id), let target else { return }
        let grant: HostPathGrant
        switch target {
        case .extraDisk:
            config.extraDisks.append(ExtraDisk(path: url.path))
            grant = HostPathGrant(.extraDisk, url.path, writable: true)
        case .installerISO:
            config.installerISO = url.path
            config.installerAttached = true
            grant = HostPathGrant(.installer, url.path, writable: false)
        }
        library.update(config)
        // The user picked this file just now; a writable approval also covers it being switched to read-only.
        library.approveHostPaths([grant], for: id)
    }

    /// Adds the folder the user picked to the machine's shared folders.
    func addSharedFolder(_ url: URL) {
        guard var config = library.machine(id) else { return }
        config.sharedFolders.append(SharedFolder(path: url.path))
        library.update(config)
        library.approveHostPaths([HostPathGrant(.sharedFolder, url.path, writable: true)], for: id)
    }
}
