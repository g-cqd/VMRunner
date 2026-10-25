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
        EditorForm {
            ForEach(EditorSection.visible(for: config)) { section in
                content(of: section)
            }
        }
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

    @ViewBuilder
    private func content(of section: EditorSection) -> some View {
        switch section {
        case .general:
            GeneralSection(
                name: $config.name, guest: config.guest, version: config.guestVersion,
                allocatedBytes: model.allocatedBytes, isSuspended: model.hasSavedState, workload: config.workload)
        case .container:
            // The draft is per machine: a new identity starts a new draft.
            ContainerEditorSection(config: $config).id(config.id)
        case .security:
            SecuritySection(config: $config, bundle: model.bundle)
        case .compute:
            ComputeSection(
                cpuCount: $config.cpuCount, memoryMiB: $config.memoryMiB,
                nestedVirtualization: $config.nestedVirtualization, guest: config.guest)
        case .storage:
            StorageSection(
                diskGiB: config.diskGiB, floorGiB: model.diskFloorGiB, resize: model.setDiskSize,
                caching: $config.diskCaching, sync: $config.diskSync, extraDisks: $config.extraDisks,
                addDisk: { model.pickerTarget = .extraDisk })
        case .installer:
            InstallerSection(
                isoPath: config.installerISO, attached: $config.installerAttached,
                choose: { model.pickerTarget = .installerISO })
        case .provisioning:
            ProvisioningSection(
                specPath: config.provisioningSpecPath, installerAttached: config.attachedInstallerPath != nil,
                approved: model.isProvisioningSpecApproved(config.provisioningSpecPath),
                choose: { model.pickerTarget = .provisioningSpec }, remove: { config.provisioningSpecPath = "" })
        case .display:
            displaySection
        case .input:
            InputSection(guest: config.guest, pointing: $config.pointingDevice, capturesSystemKeys: $config.capturesSystemKeys)
        case .audio:
            AudioSection(output: $config.audioOutput, input: $config.audioInput)
        case .network:
            NetworkSection(config: $config)
        case .networkPolicy:
            NetworkPolicySection(policy: $config.networkPolicy, model: model.network)
        case .identity:
            IdentitySection(config: $config)
        case .sharing:
            SharingSection(
                guest: config.guest, folders: $config.sharedFolders, clipboard: $config.sharesClipboard,
                rosetta: $config.rosetta, model: sharing, addFolder: model.addSharedFolder)
        case .hostInfo:
            HostInfoSection(guest: config.guest, sharing: $config.hostInfo)
        case .boot:
            BootSection(recovery: $config.bootIntoRecovery, hasBooted: config.hasBooted, provisioning: $config.provisioning)
        case .devices:
            DevicesSection(
                balloon: $config.memoryBalloon, entropy: $config.entropyDevice, vsock: $config.socketDevice,
                serialConsole: $config.serialConsole, guest: config.guest)
        case .agentAccess:
            AgentAccessSection(agentAccess: $config.agentAccess)
        case .snapshots:
            SnapshotsSection(model: model.snapshots, guest: config.guest, diskGiB: config.diskGiB, didRestore: model.didRestore)
        }
    }

    private var displaySection: some View {
        DisplaySection(
            guest: config.guest, choice: $config.displayChoice,
            width: $config.displayWidth, height: $config.displayHeight, pixelsPerInch: $config.pixelsPerInch,
            followsWindow: $config.automaticallyReconfiguresDisplay, pixelsPerPoint: $config.pixelsPerPoint,
            gpu: $config.gpu)
    }
}
