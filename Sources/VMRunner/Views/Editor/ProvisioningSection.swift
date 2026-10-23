import SwiftUI

/// A Linux machine's provisioning spec (ADR-0012, experimental): the file, what a check of it finds, and the buttons to
/// choose, check or remove it. The check is a preview; the start reads the spec and its scripts again and decides.
struct ProvisioningSection: View {
    let specPath: String
    let installerAttached: Bool
    /// Whether the user approved the spec: the check reads it only then.
    let approved: Bool
    let choose: () -> Void
    let remove: () -> Void
    @State private var check: ProvisioningCheck?
    /// Counts "Check Again" presses: each one restarts the check task.
    @State private var rechecks = 0

    var body: some View {
        Section {
            if specPath.isEmpty {
                Text(Self.emptyNote()).font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Spec", value: URL(filePath: specPath).lastPathComponent)
                    .help(specPath)
                if approved {
                    checkResult
                } else {
                    Text("Not approved yet: the next start asks first.").font(.caption).foregroundStyle(.secondary)
                }
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
                    Button("Check Again") { rechecks += 1 }
                    Button("Remove", role: .destructive, action: remove)
                }
            }
        } header: {
            HelpHeader("Provisioning (experimental)", topic: .provisioning)
        }
        .task(id: "\(specPath)\u{0}\(approved)\u{0}\(rechecks)") { await recheck() }
    }

    /// What an empty spec field says: a managed key that turns provisioning off says so.
    static func emptyNote(in policy: ManagedPreferences = .current) -> String {
        policy.isLocked(.allowProvisioning)
            ? "Your organisation turned provisioning off." : "No spec: the machine starts without a seed."
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

    /// Reads the spec and its scripts away from the main thread, and only once the user approved it. A task cancelled by a new
    /// path or by "Check Again" stores nothing, so an old result never replaces a newer one.
    private func recheck() async {
        check = nil
        guard approved, !specPath.isEmpty else { return }
        let path = specPath
        let result = await Task.detached(priority: .utility) { ProvisioningCheck(specAt: path) }.value
        guard !Task.isCancelled else { return }
        check = result
    }
}
