import SwiftUI

/// What the guest can read about its own hardware: the network card's vendor, the disk's kind and serial number, and
/// whether a disposable machine takes a new identity at each start.
struct IdentitySection: View {
    @Binding var config: VMConfig

    /// The serial number as typed, kept to what a stored configuration may hold: ASCII, at most 20 characters.
    private var serial: Binding<String> {
        Binding(
            get: { config.diskSerial },
            set: { config.diskSerial = String($0.filter(\.isASCII).prefix(EditorLimits.maxDiskSerialLength)) })
    }

    var body: some View {
        Section {
            if config.networkMode.hasNetworkDevice {
                Picker("Network card vendor", selection: $config.macVendor) {
                    ForEach(MACVendor.allCases) { Text($0.label).tag($0) }
                }
                .settingHelp(.guestIdentity)
            }
            if config.guest == .linux {
                Picker("Disk interface", selection: $config.diskInterface) {
                    ForEach(DiskInterface.allCases) { Text($0.label).tag($0) }
                }
                .settingHelp(.guestIdentity)
            }
            TextField("Disk serial number", text: serial, prompt: Text("None"))
                .disabled(config.guest == .linux && config.diskInterface == .nvme)
            Toggle("New identity at each start", isOn: $config.freshIdentityPerStart)
                .disabled(!config.ephemeral)
                .settingHelp(.guestIdentity)
            Text(
                "The vendor applies to addresses VMRunner makes: clear the MAC address or press Randomize. The new identity "
                    + "needs a disposable machine. Changes apply at the next start."
            )
            .font(.caption).foregroundStyle(.secondary)
        } header: {
            HelpHeader("Guest identity", topic: .guestIdentity)
        }
    }
}
