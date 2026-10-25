import SwiftUI

/// What a new container machine runs: its image, command, environment, CPUs, memory and network.
struct ContainerSection: View {
    @Bindable var model: NewMachineModel

    /// The memory stepper's step: the smallest memory a container may have, so every value the stepper shows is allowed.
    private static let memoryStepMiB = 128

    var body: some View {
        Section {
            TextField("Image", text: $model.container.image, prompt: Text(ContainerSpec.defaultImage))
            TextField("Command", text: $model.commandLine, prompt: Text(#"e.g. /bin/sh -c "echo hello""#))
            Text(
                "Words are split at spaces; use double quotes to keep spaces in one word. "
                    + "Leave it empty to run the container runner's own check."
            )
            .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment")
                TextEditor(text: $model.environmentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 56)
                    .accessibilityLabel("Environment, one NAME=value per line")
                Text("One NAME=value per line.").font(.caption).foregroundStyle(.secondary)
            }
            ValueStepper(
                title: "CPU cores", value: $model.container.cpus, range: ContainerLimits.cpus, text: "\(model.container.cpus)"
            )
            ValueStepper(
                title: "Memory", value: $model.container.memoryMiB, range: ContainerLimits.memoryMiB, step: Self.memoryStepMiB,
                text: "\(model.container.memoryMiB) MiB"
            )
            Picker("Network", selection: $model.container.network) {
                ForEach(ContainerNetwork.allCases) { Text($0.label).tag($0) }
            }
            Text(Self.explanation(of: model.container.network)).font(.caption).foregroundStyle(.secondary)
            if let problem = model.containerProblem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Container")
        }
    }

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
