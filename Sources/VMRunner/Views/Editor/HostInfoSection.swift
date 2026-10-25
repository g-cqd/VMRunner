import SwiftUI

/// The facts about this Mac the guest can read, one switch per category, how to read them, and what they say now.
struct HostInfoSection: View {
    let guest: GuestOS
    @Binding var sharing: HostInfoSharing

    var body: some View {
        Section {
            row("Battery level", $sharing.battery)
            row("Power source and Low Power Mode", $sharing.power)
            row("Thermal state", $sharing.thermal)
            row("Network path (no addresses or names)", $sharing.networkPath)
            row("Time zone", $sharing.timeZone)
            if !sharing.isEmpty {
                // The hint quotes a mount command; a Windows guest has none to quote.
                if guest != .windows { mountHint }
                preview
            }
        } header: {
            HelpHeader("Host information", topic: .hostInformation)
        }
    }

    private func row(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).managedLock(.allowHostInformation).settingHelp(.hostInformation)
    }

    private var mountHint: some View {
        Text(
            guest == .macOS
                ? "In the guest: mkdir ~/host && mount_virtiofs \(ConfigurationBuilder.hostInfoTag) ~/host"
                : "In the guest: sudo mkdir -p /mnt/host && sudo mount -t virtiofs \(ConfigurationBuilder.hostInfoTag) /mnt/host"
        )
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    /// The files as they would read now. The network path is followed only while the machine runs, so it reads unknown here.
    private var preview: some View {
        DisclosureGroup("What the guest would read now") {
            let files = HostFacts.current(network: nil).files(for: sharing)
            ForEach(HostFacts.fileNames.filter { files[$0] != nil }, id: \.self) { name in
                LabeledContent(name, value: (files[name] ?? "").split(separator: "\n").joined(separator: ", "))
            }
        }
        .font(.callout)
    }
}
