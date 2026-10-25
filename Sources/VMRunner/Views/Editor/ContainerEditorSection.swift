import SwiftUI

/// The container section over a stored machine. The settings are edited as a draft, and each change that is valid is saved
/// through the configuration binding like any other editor change; one that is not valid is explained and not saved.
struct ContainerEditorSection: View {
    @Binding var config: VMConfig
    private let policy: ManagedPreferences
    @State private var draft: ContainerDraft
    @State private var problem: String?

    init(config: Binding<VMConfig>, policy: ManagedPreferences = .current) {
        _config = config
        self.policy = policy
        _draft = State(initialValue: ContainerDraft(config.wrappedValue.container ?? ContainerSpec()))
    }

    var body: some View {
        ContainerSection(
            container: $draft.spec, commandLine: $draft.commandLine, environmentText: $draft.environmentText,
            problem: problem, textIsEditable: draft.textIsEditable, isLocked: policy.isLocked(.allowContainers)
        )
        .onChange(of: draft) { _, draft in save(draft) }
    }

    private func save(_ draft: ContainerDraft) {
        do {
            config = try draft.applied(to: config)
            problem = nil
        } catch {
            problem = VMConfig.reason(for: error)
        }
    }
}
