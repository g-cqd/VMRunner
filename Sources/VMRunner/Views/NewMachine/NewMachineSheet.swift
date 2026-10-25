import SwiftUI

/// The "New Machine" sheet: name and kind, then for a virtual machine its guest, installation media and starting resources,
/// or for a container its image, command, environment and limits.
struct NewMachineSheet: View {
    @Environment(VMLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = NewMachineModel()
    /// The creation in progress: a Windows installer is hashed first, which Cancel and closing the sheet stop.
    @State private var creating: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.config.name.limited())
                // A single choice is no choice: when the organisation does not allow containers, the picker is not shown.
                let kinds = ManagedPreferences.current.offeredWorkloads
                if kinds.count > 1 {
                    Picker("Kind", selection: $model.workload) {
                        ForEach(kinds) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isVerifying)
                    .settingHelp(.containers)
                }
                if model.workload == .vm {
                    Picker("Guest", selection: $model.config.guest) {
                        ForEach(GuestOS.newMachineChoices) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isVerifying)
                    .settingHelp(.guestSystems)
                }
            }
            if model.workload == .vm {
                if model.config.guest == .windows {
                    WindowsMediaSection(model: model)
                } else {
                    MediaSection(model: model)
                }
                ResourcesSection(
                    guest: model.config.guest, cpuCount: $model.config.cpuCount, memoryMiB: $model.config.memoryMiB,
                    diskGiB: $model.config.diskGiB)
            } else {
                ContainerSection(
                    container: $model.container, commandLine: $model.commandLine, environmentText: $model.environmentText,
                    problem: model.containerProblem)
            }
            if model.workload == .vm, model.config.guest == .windows { WindowsRequirementsSection() }
            if let error = model.creationError { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .safeAreaInset(edge: .bottom) { footer }
        .onChange(of: model.config.guest) { _, guest in model.guestChanged(to: guest) }
        .onChange(of: model.workload) { _, workload in model.workloadChanged(to: workload) }
        .onDisappear { creating?.cancel() }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create") {
                creating = Task { if await model.createAfterVerifying(in: library) { dismiss() } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate)
        }
        .padding()
    }
}

private struct ResourcesSection: View {
    let guest: GuestOS
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    @Binding var diskGiB: Int

    var body: some View {
        Section {
            CoreAndMemorySteppers(cpuCount: $cpuCount, memoryMiB: $memoryMiB, memoryStepMiB: EditorLimits.newMemoryStepMiB)
            ValueStepper(
                title: "Disk", value: $diskGiB, range: EditorLimits.newDiskGiB(for: guest), step: EditorLimits.diskStepGiB,
                text: "\(diskGiB) GiB"
            )
            .settingHelp(.diskSize)
        } header: {
            Text("Resources")
        }
    }
}
