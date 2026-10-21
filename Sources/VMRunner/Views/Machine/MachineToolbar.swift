import SwiftUI

/// Start, pause, suspend, shut down, force stop, and the "More" menu.
struct MachineToolbar: ToolbarContent {
    let model: MachineModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if model.showsControls {
                if model.isRunning {
                    runningControls
                } else {
                    Button("Start", systemImage: "play.fill", action: model.start)
                        .help(model.startHelp)
                }
            }
            moreMenu
        }
    }

    @ViewBuilder
    private var runningControls: some View {
        if model.isPaused {
            Button("Resume", systemImage: "play.fill", action: model.resume)
        } else {
            Button("Pause", systemImage: "pause.fill", action: model.pause)
        }
        if let deadline = model.deadline {
            Label {
                Text(deadline, style: .timer).monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            .help("Time until the runtime limit shuts this machine down")
        }
        if let activity = model.networkActivity { NetworkActivityButton(activity: activity) }
        Button("Suspend", systemImage: "moon.zzz.fill", action: model.suspend)
            .disabled(!model.canSuspend)
            .help(model.suspendHelp)
        Button("Shut Down", systemImage: "power", action: model.shutDown)
            .help("Ask the guest to shut down")
        Button("Force Stop", systemImage: "xmark.octagon.fill", action: model.forceStop)
            .help("Stop immediately, like pulling the power cord")
    }

    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Reveal in Finder", action: model.revealInFinder)
            Button("Duplicate", action: model.duplicate)
                .disabled(model.isRunning)
            Button("Discard Suspended State", action: model.discardSavedState)
                .disabled(model.isRunning || !model.hasSavedState)
            Divider()
            Button("Delete…", role: .destructive) { model.confirmingDelete = true }
                .disabled(model.isRunning)
        }
        .help("Duplicate, delete, and other actions for this machine")
    }
}
