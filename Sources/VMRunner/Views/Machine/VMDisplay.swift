import SwiftUI
import Virtualization
import os

/// Shows a running machine's screen and forwards keyboard and pointer input to it.
struct VMDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine
    let settings: MachineModel.DisplaySettings

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
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        view.capturesSystemKeys = settings.capturesSystemKeys
        // macOS guests honour the configured pixel density, so the framework's resizing is right for them.
        // For Linux it would hand over Retina-scaled pixels and shrink text, so resize at `scale` ourselves.
        view.automaticallyReconfiguresDisplay = settings.followsWindow && settings.guest == .macOS
        resizer.configure(
            machine: machine, scale: settings.scale, enabled: settings.followsWindow && settings.guest == .linux,
            holdFor: settings.firmwareHoldRemaining)
    }
}

extension VZGraphicsDisplay: ResizableDisplay {}

/// Connects a Linux guest's graphics display to the view that shows it. The policy is `DisplayFollower`.
@MainActor
final class DisplayResizer {
    private var machine: VZVirtualMachine?
    private var follower: DisplayFollower?
    private var lastViewSize = CGSize.zero

    /// `holdFor` is how much of the firmware hold (`DisplayFollower.firmwareHold`) is left when a machine is first seen.
    func configure(machine: VZVirtualMachine, scale: Double, enabled: Bool, holdFor: Duration) {
        if self.machine !== machine {
            self.machine = machine
            follower = DisplayFollower(
                scale: scale, enabled: enabled, hold: holdFor, clock: ContinuousClock(),
                display: { [weak machine] in machine?.graphicsDevices.first?.displays.first },
                report: Self.log)
            if lastViewSize != .zero { follower?.viewResized(to: lastViewSize) }
        }
        follower?.configure(scale: scale, enabled: enabled)
    }

    func viewResized(to size: CGSize) {
        lastViewSize = size
        follower?.viewResized(to: size)
    }

    private static func log(_ event: DisplayFollower.Event) {
        switch event {
        case .refused: Log.display.error("Display resize: \(event.description, privacy: .public)")
        default: Log.display.debug("Display resize: \(event.description, privacy: .public)")
        }
    }
}

/// Hosts the VM view without exposing its intrinsic size, which would otherwise resize the window to the
/// guest framebuffer.
final class DisplayContainer: NSView {
    let machineView = VZVirtualMachineView()
    var onLayout: ((CGSize) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        machineView.frame = bounds
        machineView.autoresizingMask = [.width, .height]
        addSubview(machineView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DisplayContainer is created in code only") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        onLayout?(bounds.size)
    }
}
