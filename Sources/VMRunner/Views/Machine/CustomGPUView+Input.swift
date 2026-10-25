import AppKit

/// The picture's view is the first responder and the one every event reaches; it passes each to the machine's input surface
/// (`GuestInputSurface`), and swallows it when there is none, so that the system does not beep at a key press.
extension CustomGPUView {
    override func keyDown(with event: NSEvent) { input?.keyDown(event) }
    override func keyUp(with event: NSEvent) { input?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { input?.flagsChanged(event) }
    override func mouseMoved(with event: NSEvent) { input?.mouseMoved(event) }
    override func scrollWheel(with event: NSEvent) { input?.scrollWheel(event) }

    override func mouseDown(with event: NSEvent) { input?.mouseDown(event, button: .left) }
    override func rightMouseDown(with event: NSEvent) { input?.mouseDown(event, button: .right) }
    override func otherMouseDown(with event: NSEvent) { input?.mouseDown(event, button: .other) }

    override func mouseUp(with event: NSEvent) { input?.mouseUp(event, button: .left) }
    override func rightMouseUp(with event: NSEvent) { input?.mouseUp(event, button: .right) }
    override func otherMouseUp(with event: NSEvent) { input?.mouseUp(event, button: .other) }

    override func mouseDragged(with event: NSEvent) { input?.mouseDragged(event, button: .left) }
    override func rightMouseDragged(with event: NSEvent) { input?.mouseDragged(event, button: .right) }
    override func otherMouseDragged(with event: NSEvent) { input?.mouseDragged(event, button: .other) }

    /// Mouse movement without a button reaches a view only through a tracking area of its own.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}
