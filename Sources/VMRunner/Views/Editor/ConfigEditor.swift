import SwiftUI
import UniformTypeIdentifiers

/// Every setting of a stopped machine. Edits persist immediately and apply on the next boot.
///
/// This view only arranges sections. Each section receives just the fields it shows, and the logic lives in
/// `ConfigEditorModel`.
struct ConfigEditor: View {
    @Bindable var model: ConfigEditorModel
    @Binding var config: VMConfig

    @State private var sharing = SharingModel()

    var body: some View {
        Form {
            GeneralSection(
                name: $config.name, guest: config.guest, version: config.guestVersion,
                allocatedBytes: model.allocatedBytes, isSuspended: model.hasSavedState)
            SecuritySection(config: $config, bundle: model.bundle)
            ComputeSection(
                cpuCount: $config.cpuCount, memoryMiB: $config.memoryMiB,
                nestedVirtualization: $config.nestedVirtualization, guest: config.guest)
            StorageSection(
                diskGiB: config.diskGiB, floorGiB: model.diskFloorGiB, resize: model.setDiskSize,
                caching: $config.diskCaching, sync: $config.diskSync, extraDisks: $config.extraDisks,
                addDisk: { model.pickerTarget = .extraDisk })
            if config.guest == .linux {
                InstallerSection(
                    isoPath: config.installerISO, attached: $config.installerAttached,
                    choose: { model.pickerTarget = .installerISO })
            }
            displaySection
            InputSection(guest: config.guest, pointing: $config.pointingDevice, capturesSystemKeys: $config.capturesSystemKeys)
            AudioSection(output: $config.audioOutput, input: $config.audioInput)
            NetworkSection(config: $config)
            if config.networkMode == .filtered {
                NetworkPolicySection(policy: $config.networkPolicy, model: model.network)
            }
            SharingSection(
                guest: config.guest, folders: $config.sharedFolders, clipboard: $config.sharesClipboard,
                rosetta: $config.rosetta, model: sharing, addFolder: model.addSharedFolder)
            if config.guest == .macOS {
                BootSection(recovery: $config.bootIntoRecovery, hasBooted: config.hasBooted, provisioning: $config.provisioning)
            }
            DevicesSection(balloon: $config.memoryBalloon, entropy: $config.entropyDevice, vsock: $config.socketDevice)
            SnapshotsSection(model: model.snapshots, guest: config.guest, diskGiB: config.diskGiB, didRestore: model.didRestore)
        }
        .formStyle(.grouped)
        .task { await model.opened() }
        .fileImporter(
            isPresented: Binding(get: { model.pickerTarget != nil }, set: { if !$0 { model.pickerTarget = nil } }),
            allowedContentTypes: [.diskImage, .data]
        ) { [target = model.pickerTarget] result in
            if let url = try? result.get() { model.importFile(url, for: target) }
        }
        .alert(
            "VMRunner",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var displaySection: some View {
        DisplaySection(
            guest: config.guest, choice: $config.displayChoice,
            width: $config.displayWidth, height: $config.displayHeight, pixelsPerInch: $config.pixelsPerInch,
            followsWindow: $config.automaticallyReconfiguresDisplay, pixelsPerPoint: $config.pixelsPerPoint)
    }
}
