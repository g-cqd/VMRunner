import SwiftUI

/// A Linux machine's provisioning spec (ADR-0012, experimental): the file, what a check of it finds, and the buttons to
/// choose, check or remove it. The check is a preview; the start reads the spec and its scripts again and decides.
struct ProvisioningSection: View {
    let specPath: String
    let installerAttached: Bool
    let choose: () -> Void
    let remove: () -> Void
    @State private var check: ProvisioningCheck?

    var body: some View {
        Section {
            if specPath.isEmpty {
                Text("No spec: the machine starts without a seed.").font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Spec", value: URL(filePath: specPath).lastPathComponent)
                    .help(specPath)
                checkResult
                if installerAttached {
                    Text("Not used while the installer is attached: detach the installer to use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(specPath.isEmpty ? "Choose Spec…" : "Change Spec…", action: choose)
                    .managedLock(.allowProvisioning)
                    .settingHelp(.provisioning)
                if !specPath.isEmpty {
                    Button("Check Again") { Task { await recheck() } }
                    Button("Remove", role: .destructive, action: remove)
                }
            }
        } header: {
            HelpHeader("Provisioning (experimental)", topic: .provisioning)
        }
        .task(id: specPath) { await recheck() }
    }

    @ViewBuilder private var checkResult: some View {
        switch check {
        case .ready(let lines)?:
            if lines.isEmpty {
                Text("No steps.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        case .refused(let reason)?:
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    /// Reads the spec and its scripts away from the main thread; the result replaces what is shown.
    private func recheck() async {
        guard !specPath.isEmpty else {
            check = nil
            return
        }
        let path = specPath
        check = nil
        let result = await Task.detached(priority: .utility) { ProvisioningCheck(specAt: path) }.value
        // A newer path cancelled this task while the check ran: its result is for a spec that is no longer shown.
        guard !Task.isCancelled else { return }
        check = result
    }
}
