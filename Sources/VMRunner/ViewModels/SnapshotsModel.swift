import Foundation
import Observation

/// The snapshots of one machine and the actions on them.
@MainActor @Observable
final class SnapshotsModel {
    private(set) var snapshots: [Snapshot] = []
    var name = ""
    var errorMessage: String?
    /// The snapshot the user asked to restore and has not yet confirmed.
    var pendingRestore: Snapshot?

    private let bundle: VMBundle

    init(bundle: VMBundle) {
        self.bundle = bundle
    }

    var canTake: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= EditorLimits.maxTextLength
    }

    func reload() async {
        let bundle = bundle
        snapshots = await Task.detached(priority: .utility) { bundle.listSnapshots() }.value
    }

    func take(guest: GuestOS, diskGiB: Int) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canTake else { return }
        do {
            var config = VMConfig.new(name: "", guest: guest)
            config.diskGiB = diskGiB
            _ = try bundle.takeSnapshot(named: trimmed, config: config)
            name = ""
            errorMessage = nil
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ snapshot: Snapshot) async {
        bundle.deleteSnapshot(snapshot)
        await reload()
    }

    /// Restores the confirmed snapshot. Returns it on success so the caller can update the settings.
    func restorePending(guest: GuestOS) -> Snapshot? {
        guard let snapshot = pendingRestore else { return nil }
        pendingRestore = nil
        do {
            try bundle.restoreSnapshot(snapshot, guest: guest)
            errorMessage = nil
            return snapshot
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
