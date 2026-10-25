import AppKit
import Testing
import Virtualization

@testable import VMRunner
@testable import VirtioGPU

/// A framework view that records the events it is given.
@MainActor
private final class ViewSpy: VZVirtualMachineView {
    private(set) var calls: [String] = []

    override func keyDown(with event: NSEvent) { calls.append("keyDown") }
    override func keyUp(with event: NSEvent) { calls.append("keyUp") }
    override func flagsChanged(with event: NSEvent) { calls.append("flagsChanged") }
    override func mouseMoved(with event: NSEvent) { calls.append("mouseMoved") }
    override func scrollWheel(with event: NSEvent) { calls.append("scrollWheel") }
    override func mouseDown(with event: NSEvent) { calls.append("mouseDown") }
    override func rightMouseDown(with event: NSEvent) { calls.append("rightMouseDown") }
    override func otherMouseDown(with event: NSEvent) { calls.append("otherMouseDown") }
    override func mouseUp(with event: NSEvent) { calls.append("mouseUp") }
    override func rightMouseUp(with event: NSEvent) { calls.append("rightMouseUp") }
    override func otherMouseUp(with event: NSEvent) { calls.append("otherMouseUp") }
    override func mouseDragged(with event: NSEvent) { calls.append("mouseDragged") }
    override func rightMouseDragged(with event: NSEvent) { calls.append("rightMouseDragged") }
    override func otherMouseDragged(with event: NSEvent) { calls.append("otherMouseDragged") }
}

/// The framework's view as the input of a machine on the custom GPU: kept below the picture, as big as the picture on screen,
/// and fed the events the picture's view passes on. No machine is made.
@MainActor
struct FrameworkInputSurfaceTests {
    private let container = CustomGPUContainer()

    private func picture() -> ScanoutUpdate {
        ScanoutUpdate(width: 1280, height: 800, format: .b8g8r8x8, pixels: [UInt8](repeating: 0, count: 1280 * 800 * 4))
    }

    private func frameworkView(of container: CustomGPUContainer) -> VZVirtualMachineView? {
        container.subviews.compactMap { $0 as? VZVirtualMachineView }.first
    }

    private func size(_ container: CustomGPUContainer, _ size: CGSize) {
        container.setFrameSize(size)
        container.layoutSubtreeIfNeeded()
    }

    @Test
    func theFrameworksViewSitsBelowThePictureAndDoesNotResizeTheDisplay() throws {
        let surface = FrameworkInputSurface()
        container.gpuView.use(surface)
        let below = try #require(frameworkView(of: container))
        let order = container.subviews
        #expect(order.firstIndex(of: below) == 0 && order.last === container.gpuView, "the picture's view is on top")
        #expect(!below.automaticallyReconfiguresDisplay)
        #expect(InputLatencyMonitor.holdsMachineView(container))
    }

    @Test
    func theSystemKeysSettingIsTheMachinesAndIsWrittenOnlyWhenItChanges() throws {
        let surface = FrameworkInputSurface()
        container.gpuView.use(surface)
        let below = try #require(frameworkView(of: container))
        surface.capturesSystemKeys = true
        #expect(below.capturesSystemKeys && surface.capturesSystemKeys)
        surface.capturesSystemKeys = false
        #expect(!below.capturesSystemKeys)
    }

    @Test
    func theFrameworksViewIsAsBigAsThePictureOnScreenAtEverySize() throws {
        container.gpuView.use(FrameworkInputSurface())
        let below = try #require(frameworkView(of: container))
        size(container, CGSize(width: 1000, height: 400))
        #expect(below.frame.size == .zero, "no picture yet")

        container.gpuView.present(frame: picture())
        #expect(below.frame == CGRect(x: 180, y: 0, width: 640, height: 400), "bars at the sides")
        size(container, CGSize(width: 640, height: 640))
        #expect(below.frame == CGRect(x: 0, y: 120, width: 640, height: 400), "bars above and below")
        size(container, CGSize(width: 1280, height: 800))
        #expect(below.frame == CGRect(x: 0, y: 0, width: 1280, height: 800), "no bars")
    }

    @Test
    func theFrameworksViewFollowsTheSurfaceToANewContainerAndStaysThereWhenTheOldOneLetsGo() throws {
        let surface = FrameworkInputSurface()
        container.gpuView.use(surface)
        let moved = CustomGPUContainer()
        moved.gpuView.use(surface)
        #expect(frameworkView(of: container) == nil && frameworkView(of: moved) != nil)

        container.gpuView.detach()
        #expect(frameworkView(of: moved) != nil, "a view that was moved away from lets go of nothing")
        moved.gpuView.detach()
        #expect(frameworkView(of: moved) == nil)
    }

    @Test
    func eachEventIsPassedToTheFrameworksViewOnceByItsKind() throws {
        let spy = ViewSpy()
        let surface = FrameworkInputSurface(view: spy)
        try surface.keyDown(SampleEvents.key(.keyDown))
        try surface.keyUp(SampleEvents.key(.keyUp))
        try surface.flagsChanged(SampleEvents.key(.flagsChanged))
        try surface.mouseMoved(SampleEvents.mouse(.mouseMoved))
        try surface.scrollWheel(SampleEvents.scroll())
        for button in [GuestMouseButton.left, .right, .other] {
            try surface.mouseDown(SampleEvents.mouse(.leftMouseDown), button: button)
            try surface.mouseUp(SampleEvents.mouse(.leftMouseUp), button: button)
            try surface.mouseDragged(SampleEvents.mouse(.leftMouseDragged), button: button)
        }
        #expect(
            spy.calls == [
                "keyDown", "keyUp", "flagsChanged", "mouseMoved", "scrollWheel",
                "mouseDown", "mouseUp", "mouseDragged", "rightMouseDown", "rightMouseUp", "rightMouseDragged",
                "otherMouseDown", "otherMouseUp", "otherMouseDragged",
            ])
    }
}
