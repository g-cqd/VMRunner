import SwiftUI

/// Name, guest, version, and how much space the machine uses.
struct GeneralSection: View {
    @Binding var name: String
    let guest: GuestOS
    let version: String?
    let allocatedBytes: Int64
    let isSuspended: Bool

    var body: some View {
        Section {
            TextField("Name", text: $name.limited())
            LabeledContent("Guest", value: guest.label)
            if let version { LabeledContent("Version", value: version) }
            LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file))
                .settingHelp(.diskUsage)
            if isSuspended {
                Label("Suspended — Start resumes where you left off. Changing hardware settings discards it.", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HelpHeader("General", topic: .overview)
        }
    }
}
