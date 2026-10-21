import SwiftUI

/// The rules of a filtered network: the policy mode, the private-range switch, and the allow and block lists.
struct NetworkPolicySection: View {
    @Binding var policy: NetworkPolicy
    var model: NetworkPolicyModel

    var body: some View {
        Section {
            Picker("Policy", selection: $policy.mode) {
                ForEach(NetworkPolicy.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .settingHelp(.networkPolicy)
            Text(policy.mode.summary).font(.caption).foregroundStyle(.secondary)
            Toggle("Block my Mac and local networks", isOn: $policy.blockPrivateRanges)
                .help(
                    "Blocks private, loopback, link-local and other non-public addresses, including your Mac's side of the virtual "
                        + "network. Turn off to let the guest reach devices on your LAN.")
            if let warning = model.allowListWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            HelpHeader("Network policy", topic: .networkPolicy)
        }
        if policy.mode == .allowListed {
            Section {
                ForEach(PolicyList.allowLists) { PolicyListEditor(list: $0, model: model) }
            } header: {
                HelpHeader("Allowed", topic: .policyRules)
            }
        }
        Section {
            ForEach(PolicyList.blockLists) { PolicyListEditor(list: $0, model: model) }
            Text("A block rule always wins over an allow rule. Domain rules are advisory; use addresses where it matters.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HelpHeader("Blocked", topic: .policyLimits)
        }
    }
}

/// One editable list: its rules with a remove button each, and a field to add another with the engine's error under it.
private struct PolicyListEditor: View {
    let list: PolicyList
    let model: NetworkPolicyModel

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(Array(model.rules(in: list).enumerated()), id: \.offset) { index, rule in
                HStack {
                    Text(rule).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { model.remove(at: index, from: list) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Remove \(rule)")
                }
            }
            HStack {
                TextField(
                    list.title, text: Binding(get: { model.drafts[list] ?? "" }, set: { model.drafts[list] = $0 }),
                    prompt: Text(list.example)
                )
                .labelsHidden()
                .onSubmit { model.add(to: list) }
                .help(list.tooltip)
                Button("Add", systemImage: "plus") { model.add(to: list) }
                    .disabled(!model.canAdd(to: list))
                    .help("Add this rule to the list")
            }
            if let problem = model.problem(for: list) {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
        } label: {
            Text("\(list.title) (\(model.count(in: list)))").help(list.tooltip)
        }
    }
}
