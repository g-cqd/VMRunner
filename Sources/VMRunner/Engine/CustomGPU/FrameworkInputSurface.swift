import AppKit
import Virtualization

/// The framework's own input for a machine on the custom GPU: a `VZVirtualMachineView` that is never shown. The machine has the
/// USB keyboard and screen-coordinate pointer of any other Linux machine, and the framework's view turns events into input for
/// them. The view has no graphics device to draw (the pixels come from the custom GPU), so it sits in the container **below**
/// the picture's view and the picture's view, which stays on top and keeps the keyboard, passes it every event. It cannot hide
/// the picture, and nothing hit-tests to it.
///
/// The framework's view maps a point of its own bounds to a position of the guest's screen, so its frame is the rectangle the
/// picture occupies on screen (`placePicture`): with bars around a picture of another shape, a point then lands on the guest
/// pixel under it. Whether the framework's view takes events passed to it this way, rather than delivered by the window, is
/// what a run against a real guest shows.
@MainActor
final class FrameworkInputSurface: GuestInputSurface {
    private let view: VZVirtualMachineView
    private weak var host: CustomGPUView?

    init(view: VZVirtualMachineView = VZVirtualMachineView()) {
        self.view = view
        // The custom GPU's display follows the window through the device (`CustomGPUResizableDisplay`), never through this view.
        view.automaticallyReconfiguresDisplay = false
    }

    var capturesSystemKeys: Bool {
        get { view.capturesSystemKeys }
        // Written only when it differs: the framework switches the property off on a view when another view of the same
        // machine switches it on.
        set { if view.capturesSystemKeys != newValue { view.capturesSystemKeys = newValue } }
    }

    func use(machine: VZVirtualMachine) {
        view.virtualMachine = machine
    }

    func attach(to host: CustomGPUView) {
        self.host = host
        view.removeFromSuperview()
        // AppKit declares `superview` unowned(unsafe); it is alive for the duration of this call and not kept.
        unsafe host.superview?.addSubview(view, positioned: .below, relativeTo: host)
    }

    func detach(from host: CustomGPUView) {
        guard self.host === host else { return }
        view.removeFromSuperview()
        self.host = nil
    }

    func placePicture(_ rect: CGRect, in size: CGSize) {
        // AppKit declares `superview` unowned(unsafe); it is alive for the duration of this call and not kept.
        guard let host, let container = unsafe host.superview else { return }
        view.frame = container.convert(ScreenPlacement.flipped(rect, in: size), from: host)
    }

    func keyDown(_ event: NSEvent) { view.keyDown(with: event) }
    func keyUp(_ event: NSEvent) { view.keyUp(with: event) }
    func flagsChanged(_ event: NSEvent) { view.flagsChanged(with: event) }
    func mouseMoved(_ event: NSEvent) { view.mouseMoved(with: event) }
    func scrollWheel(_ event: NSEvent) { view.scrollWheel(with: event) }

    func mouseDragged(_ event: NSEvent, button: GuestMouseButton) {
        switch button {
        case .left: view.mouseDragged(with: event)
        case .right: view.rightMouseDragged(with: event)
        case .other: view.otherMouseDragged(with: event)
        }
    }

    func mouseDown(_ event: NSEvent, button: GuestMouseButton) {
        switch button {
        case .left: view.mouseDown(with: event)
        case .right: view.rightMouseDown(with: event)
        case .other: view.otherMouseDown(with: event)
        }
    }

    func mouseUp(_ event: NSEvent, button: GuestMouseButton) {
        switch button {
        case .left: view.mouseUp(with: event)
        case .right: view.rightMouseUp(with: event)
        case .other: view.otherMouseUp(with: event)
        }
    }
}
