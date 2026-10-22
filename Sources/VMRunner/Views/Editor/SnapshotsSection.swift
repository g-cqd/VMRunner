import SwiftUI

/// Copy-on-write snapshots of a stopped machine's disk and firmware state.
struct SnapshotsSection: View {
    @Bindable var model: SnapshotsModel
    let guest: GuestOS
    let diskGiB: Int
    /// Called after a snapshot was restored, so the settings can pick up the disk size it brought back.
    let didRestore: (Snapshot) -> Void

    var body: some View {
        Section {
            ForEach(model.snapshots) { snapshot in
                HStack {
                    VStack(alignment: .leading) {
                        Text(snapshot.name)
                        Text(snapshot.date, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.pendingRestore = snapshot }
                    Button("Delete", systemImage: "trash") { Task { await model.delete(snapshot) } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Name", text: $model.name.limited(), prompt: Text("Snapshot name"))
                Button("Take Snapshot") { Task { await model.take(guest: guest, diskGiB: diskGiB) } }
                    .disabled(!model.canTake)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            Text("Snapshots are copy-on-write clones of the disk: instant, and they only use space for blocks that change afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HelpHeader("Snapshots", topic: .snapshots)
        }
        .confirmationDialog(
            "Restore “\(model.pendingRestore?.name ?? "")”?",
            isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let restored = model.restorePending(guest: guest) { didRestore(restored) }
            }
        } message: {
            Text("The disk returns to how it was then. Everything since is lost unless you take a snapshot first.")
        }
    }
}
