import AppKit
import Foundation
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// Which path carries a custom GPU machine's input, and the picture's view passing its events to the surface it was given.
@MainActor
struct CustomGPUInputTests {
    /// A scratch defaults domain that does not outlive the test.
    private func scratchDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "CustomGPUInputTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }

    // MARK: The developer default

    @Test(arguments: [nil, "", "framework", "Framework", "VIRTIO", "usb", " virtio", "virtio "])
    func anythingButTheExactNameVirtioIsTheFrameworksPath(stored: String?) {
        #expect(CustomGPUInputPath(storedValue: stored) == .framework)
    }

    @Test
    func theNameVirtioIsTheVirtioPath() {
        #expect(CustomGPUInputPath(storedValue: "virtio") == .virtio)
        #expect(CustomGPUInputPath.defaultsKey == "CustomGPUInput")
    }

    @Test
    func theDefaultIsReadFromTheDomainAndAValueOfAnotherTypeIsIgnored() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CustomGPUInputPath.current(in: defaults) == .framework, "nothing stored")
        defaults.set("virtio", forKey: CustomGPUInputPath.defaultsKey)
        #expect(CustomGPUInputPath.current(in: defaults) == .virtio)
        defaults.set(1, forKey: CustomGPUInputPath.defaultsKey)
        #expect(CustomGPUInputPath.current(in: defaults) == .framework, "a number is not a name")
        defaults.removeObject(forKey: CustomGPUInputPath.defaultsKey)
        #expect(CustomGPUInputPath.current(in: defaults) == .framework)
    }

    // MARK: The view and its surface

    @Test
    func theViewPassesEachKindOfEventToItsSurfaceOnce() throws {
        let view = CustomGPUView()
        let surface = FakeInputSurface()
        view.use(surface)

        let key = try SampleEvents.key(.keyDown)
        view.keyDown(with: key)
        try view.keyUp(with: SampleEvents.key(.keyUp))
        try view.flagsChanged(with: SampleEvents.key(.flagsChanged))
        try view.mouseMoved(with: SampleEvents.mouse(.mouseMoved))
        try view.scrollWheel(with: SampleEvents.scroll())
        try view.mouseDown(with: SampleEvents.mouse(.leftMouseDown))
        try view.rightMouseDown(with: SampleEvents.mouse(.rightMouseDown))
        try view.otherMouseDown(with: SampleEvents.mouse(.otherMouseDown))
        try view.mouseUp(with: SampleEvents.mouse(.leftMouseUp))
        try view.rightMouseUp(with: SampleEvents.mouse(.rightMouseUp))
        try view.otherMouseUp(with: SampleEvents.mouse(.otherMouseUp))
        try view.mouseDragged(with: SampleEvents.mouse(.leftMouseDragged))
        try view.rightMouseDragged(with: SampleEvents.mouse(.rightMouseDragged))
        try view.otherMouseDragged(with: SampleEvents.mouse(.otherMouseDragged))

        #expect(
            surface.calls == [
                "attach", "keyDown", "keyUp", "flagsChanged", "mouseMoved", "scrollWheel", "mouseDown", "mouseDown", "mouseDown",
                "mouseUp", "mouseUp", "mouseUp", "mouseDragged", "mouseDragged", "mouseDragged",
            ])
        #expect(surface.events.first === key, "the event itself is passed on, not a copy")
        #expect(surface.buttons == [.left, .right, .other, .left, .right, .other, .left, .right, .other])
    }

    @Test
    func aViewWithoutASurfaceSwallowsItsEvents() throws {
        let view = CustomGPUView()
        try view.keyDown(with: SampleEvents.key(.keyDown))
        try view.mouseDown(with: SampleEvents.mouse(.leftMouseDown))
        try view.scrollWheel(with: SampleEvents.scroll())
        #expect(view.input == nil, "nothing is attached, and nothing is passed up the responder chain to beep")
    }

    @Test
    func aSurfaceIsAttachedOnceReplacedAndLetGoWhenTheViewIsDetached() throws {
        let view = CustomGPUView()
        let first = FakeInputSurface()
        let second = FakeInputSurface()
        view.use(first)
        view.use(first)
        #expect(first.calls == ["attach"], "the same surface is not attached twice")

        view.use(second)
        #expect(first.calls == ["attach", "detach"] && second.calls == ["attach"])
        try view.keyDown(with: SampleEvents.key(.keyDown))
        #expect(first.calls.count == 2 && second.calls == ["attach", "keyDown"], "events go to the surface in use")

        view.detach()
        #expect(second.calls == ["attach", "keyDown", "detach"] && view.input == nil)
    }

    @Test
    func theSurfaceIsToldWhereThePictureSitsWheneverItMoves() {
        let view = CustomGPUView()
        view.setFrameSize(CGSize(width: 1000, height: 400))
        let surface = FakeInputSurface()
        view.use(surface)
        #expect(surface.placements.last == .zero, "no picture yet")

        view.present(frame: ScanoutUpdate(width: 8, height: 4, format: .b8g8r8x8, pixels: [UInt8](repeating: 0, count: 8 * 4 * 4)))
        #expect(surface.placements.last == CGRect(x: 100, y: 0, width: 800, height: 400))
        #expect(surface.sizes.last == CGSize(width: 1000, height: 400))

        view.setFrameSize(CGSize(width: 400, height: 400))
        view.layoutSubtreeIfNeeded()
        #expect(surface.placements.last == CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    @Test
    func theViewAsksForMouseMovesThroughATrackingArea() throws {
        let view = CustomGPUView()
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        let area = try #require(view.trackingAreas.first)
        #expect(view.trackingAreas.count == 1, "an update replaces the area")
        #expect(area.options.contains(.mouseMoved) && area.options.contains(.inVisibleRect) && area.owner === view)
    }
}
