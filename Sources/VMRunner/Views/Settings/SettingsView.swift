import SwiftUI

/// App-wide options.
struct SettingsView: View {
    @AppStorage("ipswDeviceIdentifier") private var storedDevice = ""
    @AppStorage("keepsRestoreImages") private var keepsRestoreImages = false
    @AppStorage(LatencyActivity.settingKey) private var holdsLatencyActivity = true
    @State private var model = SettingsModel()

    var body: some View {
        Form {
            TextField("Default Mac model for ipsw.me", text: $storedDevice, prompt: Text(IPSWCatalog.hostModelIdentifier))
            Section {
                Toggle("Keep macOS restore images after installing", isOn: $keepsRestoreImages)
                Text(
                    "A restore image is 20–27 GB and only needed once. "
                        + "Duplicate an installed machine instead: clones are instant and share disk blocks."
                )
                .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Downloaded images", value: ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file))
                HStack {
                    Button("Show in Finder", action: model.revealImages)
                    Button("Clear…", role: .destructive) { model.confirmingClear = true }
                }
                LabeledContent("Machines folder") {
                    Button("Show in Finder", action: model.revealMachines)
                }
            } header: {
                HelpHeader("Disk space", topic: .settings)
            }
            Section {
                Toggle("Keep input responsive while a machine runs", isOn: $holdsLatencyActivity)
                Text(
                    "Stops macOS from slowing this app down while a machine runs, so keys and the mouse reach the guest promptly. "
                        + "It costs some battery."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                HelpHeader("Input", topic: .inputResponsiveness)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .task { await model.refresh() }
        .onChange(of: holdsLatencyActivity) { LatencyActivity.shared.isEnabled = $1 }
        .confirmationDialog("Delete all downloaded IPSW and ISO files?", isPresented: $model.confirmingClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.clearImages() } }
        } message: {
            Text("Existing machines are unaffected. Images download again when needed.")
        }
    }
}
