import SwiftUI

/// App-wide options.
struct SettingsView: View {
    @AppStorage(AppSetting.ipswDeviceIdentifier.rawValue, store: PreferencesDomain.defaults) private var storedDevice = ""
    @AppStorage(AppSetting.keepsRestoreImages.rawValue, store: PreferencesDomain.defaults)
    private var keepsRestoreImages = false
    @AppStorage(AppSetting.holdsLatencyActivity.rawValue, store: PreferencesDomain.defaults)
    private var holdsLatencyActivity = true
    @AppStorage(AppSetting.runsControlService.rawValue, store: PreferencesDomain.defaults)
    private var runsControlService = false
    @State private var model = SettingsModel()

    var body: some View {
        Form {
            TextField("Default Mac model for ipsw.me", text: $storedDevice, prompt: Text(IPSWCatalog.hostModelIdentifier))
                .managedLock(.ipswDeviceIdentifier)
            Section {
                Toggle("Keep macOS restore images after installing", isOn: $keepsRestoreImages)
                    .managedLock(.keepsRestoreImages)
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
                    .managedLock(.holdsLatencyActivity)
                Text(
                    "Stops macOS from slowing this app down while a machine runs, so keys and the mouse reach the guest promptly. "
                        + "It costs some battery."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                HelpHeader("Input", topic: .inputResponsiveness)
            }
            Section {
                // Under the organisation's deny the service is off whatever was stored, so the locked switch shows off.
                if ManagedPreferences.current.isLocked(.allowControlService) {
                    Toggle("Let scripts and AI agents control machines", isOn: .constant(false))
                        .managedLock(.allowControlService)
                        .settingHelp(.controlService)
                } else {
                    Toggle("Let scripts and AI agents control machines", isOn: $runsControlService)
                        .managedLock(.runsControlService)
                        .settingHelp(.controlService)
                }
                Text(
                    "A private local socket on this Mac, off by default. A client needs a control token, and a machine is "
                        + "reachable only while its own Allow agent access switch is on."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let path = ControlService.shared.socketPath {
                    Text("Listening at \(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if let failure = ControlService.shared.failure {
                    Text("The control service could not start: \(failure)").font(.caption).foregroundStyle(.red)
                }
            } header: {
                HelpHeader("Automation", topic: .controlService)
            }
            if !ManagedPreferences.current.isLocked(.allowControlService) {
                ControlTokensSection()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .task { await model.refresh() }
        .onChange(of: holdsLatencyActivity) { LatencyActivity.shared.isEnabled = $1 }
        .onChange(of: runsControlService) { Task { await ControlService.shared.applySetting() } }
        .confirmationDialog("Delete all downloaded IPSW and ISO files?", isPresented: $model.confirmingClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.clearImages() } }
        } message: {
            Text("Existing machines are unaffected. Images download again when needed.")
        }
    }
}
