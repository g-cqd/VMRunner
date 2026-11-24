import AppKit

/// Display only. Owner input goes unchanged to the visible framework view underneath, never to a synthesized input path.
final class WindowsFrameOverlay: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
