import AppKit
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// A view that records the key presses that reach it, standing in for whatever sits above the custom GPU's view.
private final class KeySpy: NSView {
    var keyDowns = 0
    override func keyDown(with event: NSEvent) { keyDowns += 1 }
}

/// The custom GPU's view and the container that hosts it, as far as they can be seen without a machine.
@MainActor
struct CustomGPUViewTests {
    private let display = CGSize(width: 1280, height: 800)

    private func screen() -> CustomScreen { CustomScreen(displaySize: display) }

    private func picture(_ mark: UInt8, width: UInt32 = 1280, height: UInt32 = 800) -> ScanoutUpdate {
        ScanoutUpdate(
            width: width, height: height, format: .b8g8r8x8, pixels: [UInt8](repeating: mark, count: Int(width * height) * 4))
    }

    private func sized(_ view: CustomGPUView, _ size: CGSize) {
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
    }

    private func cursor(x: UInt32, y: UInt32) -> CursorUpdate {
        let image = ScanoutUpdate(width: 64, height: 64, format: .b8g8r8a8, pixels: [UInt8](repeating: 255, count: 64 * 64 * 4))
        return CursorUpdate(x: x, y: y, hotX: 4, hotY: 4, image: .shown(image))
    }

    @Test
    func theViewShowsThePictureOverBlackScaledToFit() throws {
        let view = CustomGPUView()
        let layer = try #require(view.layer)
        #expect(layer.contentsGravity == .resizeAspect)
        #expect(layer.backgroundColor == CGColor(gray: 0, alpha: 1))
        #expect(layer.contents == nil && view.pictureSize == .zero)

        view.present(frame: picture(7, width: 8, height: 4))
        #expect(layer.contents != nil && view.pictureSize == CGSize(width: 8, height: 4))
    }

    @Test
    func aViewShowsTheScreenItIsGivenFromItsNewestPictureAndStopsWhenDetached() throws {
        let screen = screen()
        screen.show(picture(1, width: 4, height: 4))
        let view = CustomGPUView()
        view.show(screen)
        #expect(view.pictureSize == CGSize(width: 4, height: 4), "the newest picture is drawn when the view is given the screen")

        view.detach()
        screen.show(picture(2, width: 8, height: 8))
        #expect(view.pictureSize == CGSize(width: 4, height: 4), "a detached view is not drawn to")
    }

    @Test
    func theCursorIsPlacedByTheGuestsPositionAndHotSpotAndHiddenWithoutAPicture() throws {
        let view = CustomGPUView()
        sized(view, CGSize(width: 640, height: 400))
        let overlay = try #require(view.layer?.sublayers?.first)
        view.present(frame: picture(0))
        #expect(overlay.isHidden, "no cursor yet")

        view.present(cursor: CursorState.after(cursor(x: 100, y: 50), previous: nil))
        #expect(!overlay.isHidden)
        // Half size; the guest's top left origin becomes the layer's bottom left: y = 400 - (23 + 32).
        #expect(overlay.frame == CGRect(x: 48, y: 345, width: 32, height: 32))

        let hidden = CursorUpdate(x: 100, y: 50, hotX: 4, hotY: 4, image: .hidden)
        view.present(cursor: CursorState.after(hidden, previous: CursorState.after(cursor(x: 100, y: 50), previous: nil)))
        #expect(overlay.isHidden)
    }

    @Test
    func theCursorFollowsTheViewWhenItIsResized() throws {
        let view = CustomGPUView()
        sized(view, CGSize(width: 1280, height: 800))
        view.present(frame: picture(0))
        view.present(cursor: CursorState.after(cursor(x: 100, y: 50), previous: nil))
        let overlay = try #require(view.layer?.sublayers?.first)
        #expect(overlay.frame == CGRect(x: 96, y: 800 - 46 - 64, width: 64, height: 64))

        sized(view, CGSize(width: 640, height: 400))
        #expect(overlay.frame == CGRect(x: 48, y: 345, width: 32, height: 32))
    }

    @Test
    func theViewTakesKeyboardFocusButSwallowsKeyPresses() throws {
        let view = CustomGPUView()
        #expect(view.acceptsFirstResponder)
        let spy = KeySpy()
        spy.addSubview(view)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        view.keyDown(with: event)
        #expect(spy.keyDowns == 0, "a key press is not passed up to be refused with a beep")
    }

    @Test
    func theContainerGivesTheKeyboardToTheViewOnceAndFillsAtEverySize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let container = CustomGPUContainer()
        try #require(window.contentView).addSubview(container)
        #expect(window.firstResponder === container.gpuView)

        for size in [CGSize(width: 1396, height: 1022), CGSize(width: 640, height: 400)] {
            container.setFrameSize(size)
            container.layoutSubtreeIfNeeded()
            #expect(container.gpuView.frame == container.bounds, "container \(size)")
        }
        var reported: [CGSize] = []
        container.onLayout = { reported.append($0) }
        container.setFrameSize(CGSize(width: 700, height: 500))
        #expect(reported.last == CGSize(width: 700, height: 500))
    }

    @Test
    func theLatencyMonitorTakesTheCustomGPUsViewForAMachinesView() {
        let root = NSView()
        let inner = NSView()
        root.addSubview(inner)
        #expect(!InputLatencyMonitor.holdsMachineView(root))
        inner.addSubview(CustomGPUContainer())
        #expect(InputLatencyMonitor.holdsMachineView(root))
        #expect(InputLatencyMonitor.holdsMachineView(DisplayContainer()))
    }
}
