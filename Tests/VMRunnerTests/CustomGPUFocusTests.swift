import AppKit
import Testing

@testable import VMRunner

/// The picture's view telling its input surface that the keyboard was taken from the guest, so that no key stays down.
@MainActor
struct CustomGPUFocusTests {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    private let view = CustomGPUView()
    private let surface = FakeInputSurface()

    private func focusLosses() -> Int { surface.calls.filter { $0 == "focusLost" }.count }

    private func putViewInWindow() {
        window.contentView?.addSubview(view)
        view.use(surface)
    }

    @Test
    func theSurfaceIsToldWhenTheViewStopsBeingFirstResponder() {
        putViewInWindow()
        #expect(window.makeFirstResponder(view))
        #expect(focusLosses() == 0)
        #expect(window.makeFirstResponder(nil))
        #expect(focusLosses() == 1)
    }

    @Test
    func theSurfaceIsToldWhenTheWindowStopsBeingKey() {
        putViewInWindow()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(focusLosses() == 1)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        #expect(focusLosses() == 1, "another window's notification is not this one's")
    }

    @Test
    func aViewThatMovesToAnotherWindowFollowsTheNewOneOnly() {
        putViewInWindow()
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        other.contentView?.addSubview(view)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(focusLosses() == 0)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(focusLosses() == 1)
    }

    @Test
    func aDetachedViewListensToNothing() {
        putViewInWindow()
        view.detach()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(focusLosses() == 0)
    }
}
