import SwiftUI

/// Start, pause, suspend, shut down, force stop, and the "More" menu. What each button offers is read from the machine's
/// state: a button the state does not allow is disabled, and a step in progress is named next to them.
struct MachineToolbar: ToolbarContent {
    let model: MachineModel
    /// The state the controls are drawn for. The view that builds the toolbar reads it and passes it in, so a change of state
    /// is a change of this value and the controls are drawn again, whether or not a toolbar tracks what its body reads.
    let state: MachineState

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if model.showsControls {
                if state.isActive {
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
        if state.showsResume {
            Button("Resume", systemImage: "play.fill", action: model.resume)
                .disabled(!state.canResume)
        } else {
            Button("Pause", systemImage: "pause.fill", action: model.pause)
                .disabled(!model.canPause)
        }
        if let status = state.statusText {
            Text(status).foregroundStyle(.secondary)
        }
        if let deadline = model.deadline {
            Label {
                Text(deadline, style: .timer).monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            .help("Time until the runtime limit shuts this machine down")
        }
        if let cutoff = model.networkCutoff {
            Label("Network cut", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
                .help(cutoff.text)
        }
        if let activity = model.networkActivity { NetworkActivityButton(activity: activity) }
        Button("Suspend", systemImage: "moon.zzz.fill", action: model.suspend)
            .disabled(!model.canSuspend)
            .help(model.suspendHelp)
        Button("Shut Down", systemImage: "power", action: model.shutDown)
            .disabled(!state.canShutDown)
            .help(state == .paused ? "Resume the machine first, or use Force Stop" : "Ask the guest to shut down")
        Button("Force Stop", systemImage: "xmark.octagon.fill", action: model.forceStop)
            .disabled(!state.canForceStop)
            .help(state == .stopping ? "Stop waiting and let the machine go" : "Stop immediately, like pulling the power cord")
    }

    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Reveal in Finder", action: model.revealInFinder)
            Button("Duplicate", action: model.duplicate)
                .disabled(state.isActive)
            Button("Discard Suspended State", action: model.discardSavedState)
                .disabled(state.isActive || !model.hasSavedState)
            Divider()
            Button("Delete…", role: .destructive) { model.confirmingDelete = true }
                .disabled(state.isActive)
        }
        .help("Duplicate, delete, and other actions for this machine")
    }
}
