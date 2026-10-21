import SwiftUI

/// Disk size, caching, flushing, extra disks, and the Linux installer ISO.
struct StorageSection: View {
    let diskGiB: Int
    let floorGiB: Int
    let resize: (Int) -> Void
    @Binding var caching: DiskCaching
    @Binding var sync: DiskSync
    @Binding var extraDisks: [ExtraDisk]
    let addDisk: () -> Void

    var body: some View {
        Section {
            Stepper(
                value: Binding(get: { diskGiB }, set: { resize($0) }), in: floorGiB...EditorLimits.maxDiskGiB,
                step: EditorLimits.diskStepGiB
            ) {
                LabeledContent("Disk size", value: "\(diskGiB) GiB")
            }
            .settingHelp(.diskSize)
            Text("Sparse image: only blocks the guest writes use space. Growing is permanent, and the guest must extend its partition.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Host caching", selection: $caching) {
                ForEach(DiskCaching.allCases) { Text($0.label).tag($0) }
            }
            .settingHelp(.diskCaching)
            Picker("Flush behavior", selection: $sync) {
                ForEach(DiskSync.allCases) { Text($0.label).tag($0) }
            }
            .settingHelp(.diskSync)
            ForEach($extraDisks) { $disk in
                HStack {
                    Image(systemName: "externaldrive")
                    Text(disk.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Read-only", isOn: $disk.readOnly).toggleStyle(.checkbox)
                    Button("Remove", systemImage: "minus.circle") { extraDisks.removeAll { $0.id == disk.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Disk Image…", systemImage: "plus", action: addDisk)
                HelpButton(.extraDisks)
            }
        } header: {
            HelpHeader("Storage", topic: .diskSize)
        }
    }
}

/// The ISO attached to a Linux machine for installation.
struct InstallerSection: View {
    let isoPath: String?
    @Binding var attached: Bool
    let choose: () -> Void

    var body: some View {
        Section {
            if let isoPath {
                LabeledContent("ISO", value: URL(filePath: isoPath).lastPathComponent)
                Toggle("Attach installer at boot", isOn: $attached)
                Text("Untick after installation finishes so the VM boots from its disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(isoPath == nil ? "Choose ISO…" : "Change ISO…", action: choose)
        } header: {
            HelpHeader("Installer", topic: .installerISO)
        }
    }
}
