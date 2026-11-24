import AppKit
import Testing
import VirtioGPU

@testable import VMRunner

@MainActor
struct WindowsDisplayLifecycleTests {
    @Test func rebootOrStopClearsTheFrameAndRevealsTheFrameworkViewWithoutInterceptingInput() throws {
        let screen = CustomScreen(displaySize: CGSize(width: 1920, height: 1200))
        let container = DisplayContainer()
        container.show(screen)
        let overlay = try #require(container.machineView.subviews.compactMap { $0 as? WindowsFrameOverlay }.first)
        #expect(overlay.isHidden && !overlay.acceptsFirstResponder && overlay.hitTest(.zero) == nil)
        screen.show(ScanoutUpdate(width: 1, height: 1, format: .b8g8r8x8, pixels: [0, 0, 255, 0]))
        #expect(!overlay.isHidden && overlay.image != nil && screen.frame != nil)
        screen.clear()
        #expect(overlay.isHidden && overlay.image == nil && screen.frame == nil)
        screen.show(ScanoutUpdate(width: 1, height: 1, format: .b8g8r8x8, pixels: [255, 0, 0, 0]))
        #expect(!overlay.isHidden && overlay.image != nil)
        container.show(nil)
        #expect(overlay.isHidden && overlay.image == nil)
    }
}
