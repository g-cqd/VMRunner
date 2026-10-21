import SwiftUI
import Virtualization

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
        resizer.configure(machine: machine, scale: settings.scale, enabled: settings.followsWindow && settings.guest == .linux)
    }
}

/// Keeps a Linux guest's framebuffer at `scale` pixels per point of the view, preserving its aspect ratio.
@MainActor
final class DisplayResizer {
    private var machine: VZVirtualMachine?
    private var scale = 1.0
    private var enabled = false
    private var lastViewSize = CGSize.zero
    private var lastApplied = CGSize.zero
    private var pending: Task<Void, Never>?

    func configure(machine: VZVirtualMachine, scale: Double, enabled: Bool) {
        let changed = self.scale != scale || self.enabled != enabled || self.machine !== machine
        self.machine = machine
        self.scale = scale
        self.enabled = enabled
        if changed { viewResized(to: lastViewSize) }
    }

    func viewResized(to size: CGSize) {
        lastViewSize = size
        guard enabled, size.width >= 64, size.height >= 64 else { return }
        pending?.cancel()
        // Debounce live resize: the guest re-modesets on every call.
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let display = machine?.graphicsDevices.first?.displays.first else { return }
            let pixels = CGSize(width: CGFloat(Int(size.width * scale) & ~1), height: CGFloat(Int(size.height * scale) & ~1))
            guard pixels != lastApplied, pixels != display.sizeInPixels else { return }
            if (try? display.reconfigure(sizeInPixels: pixels)) != nil { lastApplied = pixels }
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
