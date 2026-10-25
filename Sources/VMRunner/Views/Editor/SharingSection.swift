import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// Shared folders, clipboard sharing, and Rosetta.
struct SharingSection: View {
    let guest: GuestOS
    @Binding var folders: [SharedFolder]
    @Binding var clipboard: Bool
    @Binding var rosetta: Bool
    var model: SharingModel
    let addFolder: (URL) -> Void

    @State private var choosingFolder = false

    var body: some View {
        Section {
            ForEach($folders) { $folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Read-only", isOn: $folder.readOnly).toggleStyle(.checkbox)
                    Button("Remove", systemImage: "minus.circle") { folders.removeAll { $0.id == folder.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Button("Add Shared Folder…", systemImage: "plus") { choosingFolder = true }.managedLock(.allowSharedFolders)
            // The hint quotes a mount command; a Windows guest has none to quote and gets a note instead.
            if GuestEditorRows(guest).windowsNotes {
                Text(WindowsRequirements.sharingNote).font(.caption).foregroundStyle(.secondary)
            } else if !folders.isEmpty {
                mountHint
            }
            if GuestEditorRows(guest).clipboardAndRosetta {
                Toggle("Share clipboard (SPICE agent)", isOn: $clipboard).managedLock(.allowClipboardSharing).settingHelp(.clipboard)
                Text("Needs spice-vdagent running in the guest.")
                    .font(.caption).foregroundStyle(.secondary)
                rosettaRow
            }
        } header: {
            HelpHeader("Sharing", topic: .sharedFolders)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { addFolder(url) }
        }
    }

    private var mountHint: some View {
        Text(
            guest == .macOS
                ? "Appears in the guest under /Volumes/My Shared Files."
                : "In the guest: sudo mount -t virtiofs \(ConfigurationBuilder.linuxShareTag) /mnt"
        )
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    @ViewBuilder
    private var rosettaRow: some View {
        switch model.rosetta {
        case .installed:
            Toggle("Rosetta for x86_64 binaries", isOn: $rosetta).settingHelp(.rosetta)
            if rosetta {
                Text(
                    "In the guest: sudo mount -t virtiofs \(ConfigurationBuilder.rosettaTag) /media/rosetta, "
                        + "then register it with binfmt_misc."
                )
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .notInstalled:
            HStack {
                Text("Rosetta for Linux isn't installed.")
                Spacer()
                Button("Install Rosetta") { Task { await model.installRosetta() } }
                HelpButton(.rosetta)
            }
        default:
            Text("Rosetta for Linux isn't supported on this Mac.").foregroundStyle(.secondary)
        }
        if let error = model.rosettaError { Text(error).foregroundStyle(.red) }
    }
}
