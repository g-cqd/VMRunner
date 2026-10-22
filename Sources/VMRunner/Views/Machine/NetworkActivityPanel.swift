import NetStack
import SwiftUI

/// Toolbar button for a running filtered machine: the VPN symbol, and a popover with the details.
struct NetworkActivityButton: View {
    let activity: NetworkActivity

    @State private var showing = false

    var body: some View {
        Button("Network", systemImage: activity.vpn.symbol) { showing.toggle() }
            .help("Recent connections and VPN signals of the filtered network")
            .popover(isPresented: $showing, arrowEdge: .bottom) { NetworkActivityPanel(activity: activity) }
    }
}

/// Read-only: the VPN indicators and a bounded log of recent connections, newest first.
struct NetworkActivityPanel: View {
    let activity: NetworkActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filtered network").font(.headline)
                HelpButton(.networkPolicy)
                Spacer()
                Text("\(activity.allowedCount) allowed · \(activity.deniedCount) blocked")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Connections and DNS lookups since the machine started")
            }
            vpnRows
            Divider()
            log
        }
        .padding()
        .frame(width: 460, height: 420)
    }

    private var vpnRows: some View {
        let vpn = activity.vpn
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(vpn.hostText, systemImage: "laptopcomputer")
                    .help("Whether a VPN connection is up on your Mac. Guest traffic leaves through your Mac's network.")
                HelpButton(.guestVpn)
            }
            Label(vpn.guestText, systemImage: vpn.level == .guestVPN ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(vpn.level == .guestVPN ? .orange : .primary)
                .help("A heuristic over the guest's traffic: it can miss tunnels hidden inside HTTPS and can be wrong.")
            ForEach(vpn.guestEvidence, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var log: some View {
        if activity.flows.isEmpty {
            ContentUnavailableView("No connections yet", systemImage: "network")
        } else {
            List(activity.flows) { entry in
                FlowRow(entry: entry)
            }
            .listStyle(.plain)
        }
    }
}

private struct FlowRow: View {
    let entry: FlowLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.outcome == .allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(entry.outcome == .allowed ? .green : .red)
                .accessibilityLabel(entry.outcome == .allowed ? "Allowed" : "Blocked")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.destination).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("\(entry.transport.label) · \(entry.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .help("\(entry.destination)\n\(entry.detail)")
        .textSelection(.enabled)
    }
}
