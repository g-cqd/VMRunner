import AppKit
import Virtualization

/// The mouse button an event belongs to.
enum GuestMouseButton: Sendable {
    case left
    case right
    /// Any other button; the event's `buttonNumber` says which.
    case other
}

/// What carries a custom GPU machine's keyboard and pointer from its window to the guest. The window's picture view
/// (`CustomGPUView`) keeps the keyboard and receives every event; it passes each one on to the surface it was given, which
/// either feeds the framework's own input view or encodes the events for a virtio input device. Which of the two a machine
/// has is decided once, when the machine is prepared (`CustomGPUInputPath`).
@MainActor
protocol GuestInputSurface: AnyObject, Sendable {
    /// Whether the framework's input view captures system keyboard shortcuts for the guest, the setting of the machine. A path
    /// that does not use the framework's view ignores it.
    var capturesSystemKeys: Bool { get set }

    /// The machine the input is for, told once when the machine exists. A path that needs no framework view ignores it.
    func use(machine: VZVirtualMachine)

    /// The virtio devices this path adds to the machine's configuration, after the GPU; none for a path that uses the framework's
    /// own USB keyboard and pointer, and then the builder gives the machine those. It is made off the main actor, with the rest
    /// of the configuration.
    @available(macOS 27.0, *)
    nonisolated func makeConfigurations() -> [VZCustomVirtioDeviceConfiguration]

    /// `view` forwards its events to the surface from now on, and tells it where the picture sits. A surface serves one view at
    /// a time: a later attach moves it, and a detach from a view it was moved away from changes nothing.
    func attach(to view: CustomGPUView)
    func detach(from view: CustomGPUView)

    /// The window lost the keyboard (it is no longer key, or the view is no longer first responder): whatever the surface holds
    /// down for the guest must come up, because the window will not see it.
    func focusLost()

    /// Where the guest's picture sits in the attached view: `rect` has its origin at the top left of the view, which is
    /// `size` big (`ScreenPlacement.pictureRect`). It is `.zero` while there is no picture.
    func placePicture(_ rect: CGRect, in size: CGSize)

    func keyDown(_ event: NSEvent)
    func keyUp(_ event: NSEvent)
    /// A modifier key changed.
    func flagsChanged(_ event: NSEvent)
    func mouseMoved(_ event: NSEvent)
    func mouseDragged(_ event: NSEvent, button: GuestMouseButton)
    func mouseDown(_ event: NSEvent, button: GuestMouseButton)
    func mouseUp(_ event: NSEvent, button: GuestMouseButton)
    func scrollWheel(_ event: NSEvent)
}
