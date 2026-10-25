import SwiftUI

/// The detail pane for one machine. It picks what to show from the model's phase and hosts the toolbar and dialogs.
struct MachineView: View {
    @Bindable var model: MachineModel

    var body: some View {
        // Read here, in the body, so a change of state draws the toolbar again.
        let state = model.state
        if model.config != nil {
            MachinePane(model: model)
                .onGeometryChange(for: CGSize.self, of: \.size) { model.reportPaneSize($0) }
                .navigationTitle(model.title)
                .toolbar { MachineToolbar(model: model, state: state) }
                .alert(
                    MachineWording.errorTitle(for: model.workload),
                    isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
                ) {
                    Button("OK") {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .confirmationDialog("Delete “\(model.title)”?", isPresented: $model.confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { model.delete() }
                } message: {
                    Text(MachineWording.deleteDetail(for: model.workload))
                }
        }
    }
}

/// The running machine's picture: the custom GPU's when the machine has one, else the framework's view, which the caller
/// makes (it needs the framework's machine, which this view does not name).
private struct RunningScreen<Framework: View>: View {
    let model: MachineModel
    @ViewBuilder let framework: Framework

    var body: some View {
        if let source = model.customDisplay {
            CustomGPUDisplay(source: source)
        } else {
            framework
        }
    }
}

/// Switches between setup progress, an interrupted-setup prompt, the running display, and the settings form.
private struct MachinePane: View {
    let model: MachineModel

    var body: some View {
        switch model.phase {
        case .settingUp(let job):
            SetupJobView(job: job, symbol: model.guestSymbol, retry: model.retrySetup, dismiss: model.dismissSetup)
        case .setupIncomplete:
            ContentUnavailableView {
                Label("Setup Incomplete", systemImage: "arrow.down.circle.dotted")
            } description: {
                Text("Installation was interrupted. Downloads resume where they stopped.")
            } actions: {
                Button("Resume Setup", action: model.resumeSetup)
                    .buttonStyle(.borderedProminent)
                HelpButton(.setup)
            }
        case .running(.virtualMachine(let machine, let settings)):
            RunningScreen(model: model) {
                VMDisplay(machine: machine, settings: settings, guestAnswered: model.displayResizeAnswered)
            }
            .overlay { MachineStatusOverlay(model: model) }
        case .running(.workloadLog(let log)):
            ContainerLogView(log: log)
                .overlay { MachineStatusOverlay(model: model) }
        case .editing:
            if let config = model.configBinding {
                ConfigEditor(model: model.editor, config: config)
            }
        case nil:
            EmptyView()
        }
    }
}
