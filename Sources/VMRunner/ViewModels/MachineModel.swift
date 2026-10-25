import AppKit
import Foundation
import Observation
import SwiftUI
import Virtualization

/// What the detail pane shows for one machine, and every action its toolbar and menus offer.
///
/// Views read these properties and call these methods; none of them touches the library, the controller, or the file
/// system directly.
@MainActor @Observable
final class MachineModel {
    /// The settings a running machine's display view needs, and nothing else.
    struct DisplaySettings: Equatable {
        var capturesSystemKeys: Bool
        var followsWindow: Bool
        var guest: GuestOS
        var scale: Double
        /// When the firmware of this run started; `nil` for a run restored from saved state, which is past its firmware.
        var firmwareStartedAt: ContinuousClock.Instant?

        /// Who changes the guest's display size while the machine runs.
        enum Resizer: Equatable {
            /// The display keeps the size it started with.
            case nobody
            /// The machine view: macOS guests honour the configured pixel density, so the framework's resizing is right for them.
            case framework
            /// `DisplayFollower`: for Linux the framework would hand over Retina-scaled pixels and shrink text, so the app
            /// resizes at `scale` pixels per point itself.
            case app
        }

        var resizer: Resizer {
            guard followsWindow else { return .nobody }
            return guest == .macOS ? .framework : .app
        }

        /// How much of `DisplayFollower.firmwareHold` is left at `now`: a view made later in the run (full screen swaps it) has
        /// none, and neither has a macOS guest or one restored from saved state.
        func firmwareHoldRemaining(at now: ContinuousClock.Instant) -> Duration {
            guard guest == .linux, let firmwareStartedAt else { return .zero }
            return max(.zero, DisplayFollower.firmwareHold - firmwareStartedAt.duration(to: now))
        }
    }

    /// What a running machine shows: the framework's screen, or the log of a workload that has no screen.
    enum RunningDisplay {
        case virtualMachine(VZVirtualMachine, DisplaySettings)
        case workloadLog(ContainerLog)
    }

    enum Phase {
        case settingUp(SetupJob)
        case setupIncomplete
        case running(RunningDisplay)
        case editing
    }

    let id: UUID
    let editor: ConfigEditorModel
    var confirmingDelete = false

    // Unowned: the library owns its models, so a strong reference back would be a retain cycle.
    private unowned let library: VMLibrary

    init(id: UUID, library: VMLibrary) {
        self.id = id
        self.library = library
        editor = ConfigEditorModel(id: id, library: library)
    }

    // MARK: State

    private var controller: VMController { library.controller(for: id) }
    var config: VMConfig? { library.machine(id) }
    var configBinding: Binding<VMConfig>? { library.binding(for: id) }
    var title: String { config?.name ?? "" }
    var bundle: VMBundle { library.bundle(id) }

    var phase: Phase? {
        guard let config else { return nil }
        if let job = library.jobs[id] { return .settingUp(job) }
        if !config.isProvisioned { return .setupIncomplete }
        if state.hasMachine, let display = runningDisplay(of: config) { return .running(display) }
        return .editing
    }

    /// What the running machine shows, or `nil` when there is nothing to show yet: a machine with a screen shows it, one that
    /// has none shows its log.
    private func runningDisplay(of config: VMConfig) -> RunningDisplay? {
        if let machine = controller.virtualMachine {
            let settings = DisplaySettings(
                capturesSystemKeys: config.capturesSystemKeys,
                followsWindow: config.automaticallyReconfiguresDisplay,
                guest: config.guest,
                scale: config.displayScale,
                firmwareStartedAt: controller.firmwareStartedAt
            )
            return .virtualMachine(machine, settings)
        }
        guard !controller.capabilities.contains(.display), let log = controller.guest?.workloadLog else { return nil }
        return .workloadLog(log)
    }

    /// Whether the machine runs a container, which has no pause or suspend to offer.
    var isContainer: Bool { config?.workload == .container }
    var guestSymbol: String { config?.guest.symbol ?? "questionmark" }
    var showsControls: Bool { library.jobs[id] == nil && config?.isProvisioned == true }
    /// The machine's one state. Everything below that says what is offered is a reading of it.
    var state: MachineState { controller.state }
    var isRunning: Bool { state.isActive }
    var deadline: Date? { controller.deadline }
    /// The running machine's filtered-network log and VPN signals; `nil` unless the machine runs with filtered networking.
    var networkActivity: NetworkActivity? { controller.capabilities.contains(.networkActivity) ? controller.network : nil }
    /// Why the kill switch has disconnected the running machine's network card; nil while it is connected or has no rule.
    var networkCutoff: NetworkCutoffReason? { controller.guest?.networkCutoff?.reason }
    var canPause: Bool { controller.canPause }
    var canSuspend: Bool { controller.canSuspend }
    var suspendHelp: String {
        controller.canSuspend ? "Save state to disk and stop" : (controller.suspendUnavailableReason ?? "Suspend isn't available")
    }
    /// A file-system check, cheap enough for a toolbar but not something to call in a loop.
    var hasSavedState: Bool { bundle.hasSavedState }
    var startHelp: String { hasSavedState ? "Resume from suspended state" : "Start the virtual machine" }

    var errorMessage: String? {
        get { controller.errorMessage }
        set { controller.errorMessage = newValue }
    }

    // MARK: Layout

    /// The detail pane's size in points, used to size the guest display when the machine starts.
    func reportPaneSize(_ size: CGSize) { library.displayHint = size }

    /// Whether the guest left the display's last resize unanswered; see `VMController.guestIgnoresDisplayResize`.
    var guestIgnoresDisplayResize: Bool { controller.guestIgnoresDisplayResize }
    func displayResizeAnswered(_ responded: Bool) { controller.guestAnswered(displayResize: responded) }

    // MARK: Actions

    func start() { library.startMachine(id) }
    func suspend() { library.suspendMachine(id) }
    func shutDown() { controller.requestStop() }
    func resumeSetup() { library.beginSetup(id) }

    func pause() {
        let controller = controller
        Task { await controller.pause() }
    }

    func resume() {
        let controller = controller
        Task { await controller.resume() }
    }

    func forceStop() {
        let controller = controller
        Task { await controller.forceStop() }
    }

    func retrySetup() {
        library.cancelJob(id)
        library.beginSetup(id)
    }

    func dismissSetup() { library.cancelJob(id) }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
    func discardSavedState() {
        guard !isRunning else { return }
        bundle.discardSavedState()
    }

    func duplicate() {
        do {
            try library.duplicate(id)
        } catch {
            library.alertMessage = "Couldn't duplicate “\(title)”: \(error.localizedDescription)"
        }
    }

    func delete() {
        guard !isRunning else {
            library.alertMessage = "Stop “\(title)” before deleting it."
            return
        }
        library.delete(id)
    }
}
