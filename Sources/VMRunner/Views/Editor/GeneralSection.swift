import SwiftUI

/// Name, guest, version, and how much space the machine uses. A container machine shows its kind in place of a guest.
struct GeneralSection: View {
    @Binding var name: String
    let guest: GuestOS
    let version: String?
    let allocatedBytes: Int64
    let isSuspended: Bool
    var workload = WorkloadKind.vm

    var body: some View {
        Section {
            TextField("Name", text: $name.limited())
            if workload == .container {
                LabeledContent("Kind", value: workload.label)
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file))
                    .settingHelp(.containers)
            } else {
                LabeledContent("Guest", value: guest.label)
                if let version { LabeledContent("Version", value: version) }
                LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file))
                    .settingHelp(.diskUsage)
            }
            if isSuspended {
                Label(
                    "Suspended — Start resumes where you left off. Changing the disk, the network device, Secure Boot or the "
                        + "host-information sharing discards it; other hardware changes may make the restore fail, and the machine "
                        + "then cold boots.", systemImage: "moon.zzz"
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            HelpHeader("General", topic: .overview)
        }
    }
}
