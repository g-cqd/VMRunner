import SwiftUI

/// What a container machine runs: its image, command, environment, CPUs, memory and network. The New Machine sheet and the
/// editor of a stored machine both show it, each over its own copy of the settings.
struct ContainerSection: View {
    @Binding var container: ContainerSpec
    @Binding var commandLine: String
    @Binding var environmentText: String
    /// Why the settings cannot be used as they stand, or `nil`.
    let problem: String?
    /// False when the stored command or environment cannot be shown as text, so those two fields are read-only.
    var textIsEditable = true
    /// True when the organisation does not allow containers: every control is disabled and the lock is explained.
    var isLocked = false

    /// The memory stepper's step: the smallest memory a container may have, so every value the stepper shows is allowed.
    private static let memoryStepMiB = 128

    var body: some View {
        Section {
            Group {
                TextField("Image", text: $container.image, prompt: Text(ContainerSpec.defaultImage))
                    .settingHelp(.containers)
                TextField("Command", text: $commandLine, prompt: Text(#"e.g. /bin/sh -c "echo hello""#))
                    .disabled(!textIsEditable)
                    .settingHelp(.containers)
                Text(
                    "Words are split at spaces; use double quotes to keep spaces in one word. "
                        + "Leave it empty to run the container runner's own check."
                )
                .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment")
                    TextEditor(text: $environmentText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 56)
                        .disabled(!textIsEditable)
                        .accessibilityLabel("Environment, one NAME=value per line")
                    Text("One NAME=value per line.").font(.caption).foregroundStyle(.secondary)
                }
                .settingHelp(.containers)
                if !textIsEditable {
                    Text(Self.readOnlyNote).font(.caption).foregroundStyle(.secondary)
                }
                ValueStepper(title: "CPU cores", value: $container.cpus, range: ContainerLimits.cpus, text: "\(container.cpus)")
                    .settingHelp(.containers)
                ValueStepper(
                    title: "Memory", value: $container.memoryMiB, range: ContainerLimits.memoryMiB, step: Self.memoryStepMiB,
                    text: "\(container.memoryMiB) MiB"
                )
                .settingHelp(.containers)
                Picker("Network", selection: $container.network) {
                    ForEach(ContainerNetwork.allCases) { Text($0.label).tag($0) }
                }
                .settingHelp(.containers)
                Text(Self.explanation(of: container.network)).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(isLocked)
            if isLocked {
                Label(ManagedPreferences.lockedHelp, systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        } header: {
            HelpHeader("Container", topic: .containers)
        }
    }

    static let readOnlyNote =
        "This machine's command or environment can't be written as text here without changing it, "
        + "so only the other settings can be changed."

    static func explanation(of network: ContainerNetwork) -> String {
        switch network {
        case .none:
            "The container has no network."
        case .loopback:
            "The container gets a network device that leads nowhere outside this Mac: the runner itself reads its frames, "
                + "so nothing reaches your network or the internet."
        }
    }
}
