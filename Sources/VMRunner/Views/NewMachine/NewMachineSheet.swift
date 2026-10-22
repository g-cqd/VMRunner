import SwiftUI

/// The "New Machine" sheet: name and guest, installation media, and starting resources.
struct NewMachineSheet: View {
    @Environment(VMLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = NewMachineModel()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.config.name.limited())
                Picker("Guest", selection: $model.config.guest) {
                    ForEach(GuestOS.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .settingHelp(.guestSystems)
            }
            MediaSection(model: model)
            ResourcesSection(
                cpuCount: $model.config.cpuCount, memoryMiB: $model.config.memoryMiB, diskGiB: $model.config.diskGiB)
            if let error = model.creationError { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .safeAreaInset(edge: .bottom) { footer }
        .onChange(of: model.config.guest) { _, guest in model.guestChanged(to: guest) }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create") { if model.create(in: library) { dismiss() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
        }
        .padding()
    }
}

private struct ResourcesSection: View {
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    @Binding var diskGiB: Int

    var body: some View {
        Section {
            CoreAndMemorySteppers(cpuCount: $cpuCount, memoryMiB: $memoryMiB, memoryStepMiB: EditorLimits.newMemoryStepMiB)
            Stepper(value: $diskGiB, in: EditorLimits.newDiskGiB, step: EditorLimits.diskStepGiB) {
                LabeledContent("Disk", value: "\(diskGiB) GiB")
            }
            .settingHelp(.diskSize)
        } header: {
            Text("Resources")
        }
    }
}
