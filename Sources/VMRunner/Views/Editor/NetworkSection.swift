import SwiftUI
import Virtualization

/// Network mode, MAC address, and the options of filtered networking. The rules themselves are in `NetworkPolicySection`.
struct NetworkSection: View {
    @Binding var config: VMConfig

    var body: some View {
        Section {
            Picker("Mode", selection: $config.networkMode) {
                ForEach(NetworkMode.allCases) { Text($0.label).tag($0) }
            }
            .settingHelp(.networkMode)
            if config.networkMode.hasNetworkDevice { macRows }
            if config.networkMode == .filtered { filteredOptions }
            Text("Bridged networking is not offered: it needs the restricted com.apple.vm.networking entitlement.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HelpHeader("Network", topic: .networkMode)
        }
    }

    @ViewBuilder
    private var filteredOptions: some View {
        Picker("When a connection is blocked", selection: $config.networkDenyAction) {
            ForEach(DenyAction.allCases) { Text($0.label).tag($0) }
        }
        .help("Refusing fails fast and tells the guest. Ignoring reveals less, but programs in the guest hang until they time out.")
        Toggle("Reset connections when my Mac changes network", isOn: $config.networkResetsOnHostChange)
            .help(
                "When Wi-Fi, Ethernet or a VPN changes, open connections are reset so the guest reconnects over the new path. "
                    + "Off: they stay and may stall. Applies at the next start.")
        Text("Filtered networking is VMRunner's own network stack. It has not been validated against every guest.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var macRows: some View {
        HStack {
            TextField(
                "MAC address",
                text: Binding(get: { config.macAddress ?? "" }, set: { config.macAddress = $0.isEmpty ? nil : $0 }).limited(),
                prompt: Text("Automatic")
            )
            .help("The guest network card's hardware address. Leave empty for an automatic one that is kept between starts.")
            Button("Randomize") { config.macAddress = VZMACAddress.randomLocallyAdministered().string }
                .help("Pick a new random address. Discards a suspended state.")
            HelpButton(.macAddress)
        }
        if let macAddress = config.macAddress, VZMACAddress(string: macAddress) == nil {
            Label("Not a valid MAC address; an automatic one is used instead.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
