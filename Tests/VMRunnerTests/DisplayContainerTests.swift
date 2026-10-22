import AppKit
import Testing

@testable import VMRunner

/// The framework's view must fill the container it sits in, at every size the container takes. A real guest showed it keeping
/// the size of the first layout while the window shrank: the picture was then scaled to the oversized view and cropped by the
/// window (the right edge of the console and the top rows lay outside it).
@MainActor
struct DisplayContainerTests {
    private let sizes = [
        CGSize(width: 1396, height: 1022), CGSize(width: 786, height: 648), CGSize(width: 1186, height: 948),
        CGSize(width: 640, height: 400), CGSize(width: 2400, height: 1500),
    ]

    /// How SwiftUI hosts the container: no autoresizing mask, its size given by constraints that change with the window.
    @Test func theMachineViewFillsAContainerThatAutoLayoutSizes() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 3000, height: 2000), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let root = try #require(window.contentView)
        let container = DisplayContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        let width = container.widthAnchor.constraint(equalToConstant: sizes[0].width)
        let height = container.heightAnchor.constraint(equalToConstant: sizes[0].height)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor), container.topAnchor.constraint(equalTo: root.topAnchor),
            width, height,
        ])
        for size in sizes {
            width.constant = size.width
            height.constant = size.height
            root.layoutSubtreeIfNeeded()
            #expect(container.machineView.frame == NSRect(origin: .zero, size: size), "container \(size)")
        }
    }

    @Test func theMachineViewFollowsAContainerThatIsResizedByItsFrame() {
        let container = DisplayContainer()
        for size in sizes {
            container.setFrameSize(size)
            container.layoutSubtreeIfNeeded()
            #expect(container.machineView.frame == container.bounds, "container \(size)")
        }
    }

    @Test func theContainerReportsItsOwnSizeNotTheMachineViews() {
        let container = DisplayContainer()
        var reported: [CGSize] = []
        container.onLayout = { reported.append($0) }
        container.setFrameSize(sizes[0])
        container.setFrameSize(sizes[1])
        #expect(reported.last == sizes[1])
    }

    @Test func theMachineViewTakesTheKeyboardWhenTheDisplayFirstAppearsInAWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let container = DisplayContainer()
        try #require(container.machineView.acceptsFirstResponder, "VZVirtualMachineView refuses the keyboard")
        try #require(window.contentView).addSubview(container)
        #expect(window.firstResponder === container.machineView)
    }

    @Test func theDisplayTakesTheKeyboardOnlyOnce() throws {
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let container = DisplayContainer()
        try #require(first.contentView).addSubview(container)
        try #require(first.firstResponder === container.machineView, "the first window must give the view the keyboard")
        container.removeFromSuperview()
        try #require(second.contentView).addSubview(container)
        #expect(second.firstResponder !== container.machineView)
    }
}
