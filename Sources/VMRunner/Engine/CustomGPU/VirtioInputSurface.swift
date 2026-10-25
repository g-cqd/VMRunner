import AppKit
import VirtioInput
import Virtualization

/// Where the frames of events for one virtio input device go: the device, or a stand-in in a test.
@MainActor
protocol InputEventSink: AnyObject {
    func send(_ frames: [InputEvent])
}

/// The virtio path for a machine on the custom GPU: the window's events become events of two virtio input devices the app
/// implements, a keyboard and an absolute pointer, and the machine has no USB keyboard or pointer (the guest sees only these, so
/// the two paths compare cleanly). The devices belong to the surface and live as long as the machine does, because the
/// framework holds the device it makes weakly.
///
/// Keys go through `VirtioKeyMap` (a key it does not map is ignored), modifiers by the change of the flags and the key that
/// changed, the pointer as a position in the range of the tablet over the rectangle the picture occupies in the view (so a
/// point on the bars around it lands on the picture's edge), the left, right and middle buttons, and the vertical wheel. When
/// the window loses the keyboard the keys and buttons held are released, because it would never see them come up.
@available(macOS 27.0, *)
@MainActor
final class VirtioInputSurface: GuestInputSurface {
    private let keyboard: any InputEventSink
    private let pointer: any InputEventSink
    /// The devices, when they are the real ones: what the machine's configuration takes.
    private let devices: [VirtioInputDevice]
    private var keys = KeyboardState()
    private var pointerState = PointerState()
    private weak var host: CustomGPUView?
    /// Where the picture sits in the host (origin at the top left), and the host's size.
    private var picture = CGRect.zero
    private var viewSize = CGSize.zero

    /// A surface over these sinks. `devices` are the ones among them that belong in the machine's configuration; none, for the
    /// stand-ins of a test.
    init(keyboard: any InputEventSink, pointer: any InputEventSink, devices: [VirtioInputDevice] = []) {
        self.keyboard = keyboard
        self.pointer = pointer
        self.devices = devices
    }

    /// A surface with a keyboard and a pointer of its own.
    convenience init() {
        let keyboard = VirtioInputDevice(layout: .keyboard, label: "keyboard")
        let pointer = VirtioInputDevice(layout: .tablet, label: "pointer")
        self.init(keyboard: keyboard, pointer: pointer, devices: [keyboard, pointer])
    }

    /// The framework's view and its setting have no part in this path.
    var capturesSystemKeys = false

    func use(machine: VZVirtualMachine) {}

    /// The keyboard's device, then the pointer's.
    nonisolated func makeConfigurations() -> [VZCustomVirtioDeviceConfiguration] {
        devices.map { $0.makeConfiguration() }
    }

    func attach(to host: CustomGPUView) {
        self.host = host
    }

    func detach(from host: CustomGPUView) {
        guard self.host === host else { return }
        self.host = nil
    }

    func placePicture(_ rect: CGRect, in size: CGSize) {
        (picture, viewSize) = (rect, size)
    }

    func focusLost() {
        keyboard.send(keys.releaseAll())
        pointer.send(pointerState.releaseAll())
    }

    func keyDown(_ event: NSEvent) { keyboard.send(keys.press(keyCode: event.keyCode, isRepeat: event.isARepeat)) }
    func keyUp(_ event: NSEvent) { keyboard.send(keys.release(keyCode: event.keyCode)) }
    func flagsChanged(_ event: NSEvent) { keyboard.send(keys.modifiersChanged(keyCode: event.keyCode, flags: event.modifierFlags)) }

    func mouseMoved(_ event: NSEvent) { move(to: event) }
    func mouseDragged(_ event: NSEvent, button: GuestMouseButton) { move(to: event) }

    func mouseDown(_ event: NSEvent, button: GuestMouseButton) {
        move(to: event)
        guard let pressed = PointerState.button(button, number: event.buttonNumber) else { return }
        pointer.send(pointerState.press(pressed))
    }

    func mouseUp(_ event: NSEvent, button: GuestMouseButton) {
        move(to: event)
        guard let released = PointerState.button(button, number: event.buttonNumber) else { return }
        pointer.send(pointerState.release(released))
    }

    func scrollWheel(_ event: NSEvent) {
        pointer.send(pointerState.scroll(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas))
    }

    private func move(to event: NSEvent) {
        let point = host?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        pointer.send(PointerState.position(of: point, picture: picture, in: viewSize))
    }
}
