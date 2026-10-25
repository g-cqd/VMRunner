import SwiftUI
import Virtualization
import os

/// Shows a running machine's screen and forwards keyboard and pointer input to it.
struct VMDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine
    let settings: MachineModel.DisplaySettings
    /// Told, for each resize the app asks of the guest, whether the guest answered it.
    let guestAnswered: (Bool) -> Void

    func makeCoordinator() -> DisplayResizer { DisplayResizer() }

    func makeNSView(context: Context) -> DisplayContainer {
        let container = DisplayContainer()
        container.onLayout = { [weak resizer = context.coordinator] size in
            resizer?.viewResized(to: size)
        }
        configure(container.machineView, resizer: context.coordinator)
        return container
    }

    func updateNSView(_ container: DisplayContainer, context: Context) {
        configure(container.machineView, resizer: context.coordinator)
    }

    private func configure(_ view: VZVirtualMachineView, resizer: DisplayResizer) {
        if view.virtualMachine !== machine {
            DisplayDiagnostics.note("view attached to a \(settings.guest.label) machine")
            view.virtualMachine = machine
        }
        // SwiftUI calls this on every update; write only what differs, and compare with what the view holds now rather than
        // with what was written last, because the framework switches the property off on a view when another view of the
        // same display switches it on (full screen swaps the view for a new one).
        if view.capturesSystemKeys != settings.capturesSystemKeys { view.capturesSystemKeys = settings.capturesSystemKeys }
        let frameworkResizes = settings.resizer == .framework
        if view.automaticallyReconfiguresDisplay != frameworkResizes {
            DisplayDiagnostics.note(
                "view.automaticallyReconfiguresDisplay was \(view.automaticallyReconfiguresDisplay), now \(frameworkResizes)")
            view.automaticallyReconfiguresDisplay = frameworkResizes
        }
        resizer.configure(
            machine: machine, scale: settings.scale, enabled: settings.resizer == .app,
            holdFor: settings.firmwareHoldRemaining(at: .now), guestAnswered: guestAnswered)
    }
}

extension VZGraphicsDisplay: ResizableDisplay {}

/// Connects a Linux guest's graphics display to the view that shows it. The policy is `DisplayFollower`.
@MainActor
final class DisplayResizer {
    private var machine: VZVirtualMachine?
    private var source: (any CustomDisplaySource)?
    private var customDisplay: CustomGPUResizableDisplay?
    private var follower: DisplayFollower?
    private var trace: DisplayTrace?
    private var lastViewSize = CGSize.zero
    private var guestAnswered: (Bool) -> Void = { _ in }

    /// `holdFor` is how much of the firmware hold (`DisplayFollower.firmwareHold`) is left when a machine is first seen.
    func configure(
        machine: VZVirtualMachine, scale: Double, enabled: Bool, holdFor: Duration, guestAnswered: @escaping (Bool) -> Void
    ) {
        self.guestAnswered = guestAnswered
        if self.machine !== machine {
            self.machine = machine
            trace = DisplayTrace(machine: machine)
            makeFollower(scale: scale, enabled: enabled, holdFor: holdFor) { [weak machine] in
                machine?.graphicsDevices.first?.displays.first
            }
        }
        follower?.configure(scale: scale, enabled: enabled)
    }

    /// The same for a machine on the custom GPU: the display the follower resizes is the adapter over the source's device.
    func configure(
        source: any CustomDisplaySource, scale: Double, enabled: Bool, holdFor: Duration, guestAnswered: @escaping (Bool) -> Void
    ) {
        self.guestAnswered = guestAnswered
        if self.source !== source {
            self.source = source
            let display = CustomGPUResizableDisplay(source: source)
            customDisplay = display
            makeFollower(scale: scale, enabled: enabled, holdFor: holdFor) { [weak display] in display }
        }
        follower?.configure(scale: scale, enabled: enabled)
    }

    private func makeFollower(
        scale: Double, enabled: Bool, holdFor: Duration, display: @escaping () -> (any ResizableDisplay)?
    ) {
        follower = DisplayFollower(
            scale: scale, enabled: enabled, hold: holdFor, clock: ContinuousClock(), display: display,
            report: { [weak self] in self?.handle($0) })
        if lastViewSize != .zero { follower?.viewResized(to: lastViewSize) }
    }

    func viewResized(to size: CGSize) {
        lastViewSize = size
        follower?.viewResized(to: size)
    }

    /// Whether the guest answered a resize is always logged (a notice: it is rare and the one fact the owner needs); the rest
    /// of the follower's events only with `--display-diagnostics`.
    private func handle(_ event: DisplayFollower.Event) {
        switch event {
        case .refused: Log.display.error("Display resize: \(event.description, privacy: .public)")
        case .askedAgain: Log.display.notice("Display resize: \(event.description, privacy: .public)")
        case .guestResponded, .reachedWithoutRequest:
            Log.display.notice("Display resize: \(event.description, privacy: .public)")
            guestAnswered(true)
        case .guestIgnored:
            Log.display.notice("Display resize: \(event.description, privacy: .public)")
            guestAnswered(false)
        default: DisplayDiagnostics.note("resize: \(event.description)")
        }
    }
}

/// The framework's machine view, hosted like every screen.
final class DisplayContainer: ScreenContainer {
    let machineView: VZVirtualMachineView

    init() {
        let view = VZVirtualMachineView()
        machineView = view
        super.init(hosting: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DisplayContainer is created in code only") }
}
