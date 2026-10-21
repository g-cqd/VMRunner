import SwiftUI
import Virtualization

/// Network mode and MAC address.
struct NetworkSection: View {
    @Binding var mode: NetworkMode
    @Binding var macAddress: String?

    var body: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(NetworkMode.allCases) { Text($0.label).tag($0) }
            }
            .settingHelp(.networkMode)
            if mode == .nat { macRows }
            Text("Bridged networking is not offered: it needs the restricted com.apple.vm.networking entitlement.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HelpHeader("Network", topic: .networkMode)
        }
    }

    @ViewBuilder
    private var macRows: some View {
        HStack {
            TextField(
                "MAC address", text: Binding(get: { macAddress ?? "" }, set: { macAddress = $0.isEmpty ? nil : $0 }),
                prompt: Text("Automatic"))
            Button("Randomize") { macAddress = VZMACAddress.randomLocallyAdministered().string }
            HelpButton(.macAddress)
        }
        if let macAddress, VZMACAddress(string: macAddress) == nil {
            Label("Not a valid MAC address; an automatic one is used instead.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
