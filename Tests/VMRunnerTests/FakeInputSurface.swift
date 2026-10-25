import AppKit
import Testing
import Virtualization

@testable import VMRunner

/// An input surface that records what it is given, for the views and sources that take one.
@MainActor
final class FakeInputSurface: GuestInputSurface {
    /// Every call in order, by name; the picture placements and the events are kept apart.
    private(set) var calls: [String] = []
    private(set) var events: [NSEvent] = []
    private(set) var buttons: [GuestMouseButton] = []
    private(set) var placements: [CGRect] = []
    private(set) var sizes: [CGSize] = []
    var capturesSystemKeys = false

    func use(machine: VZVirtualMachine) { calls.append("use") }
    func focusLost() { calls.append("focusLost") }

    @available(macOS 27.0, *)
    nonisolated func makeConfigurations() -> [VZCustomVirtioDeviceConfiguration] { [] }
    func attach(to view: CustomGPUView) { calls.append("attach") }
    func detach(from view: CustomGPUView) { calls.append("detach") }

    func placePicture(_ rect: CGRect, in size: CGSize) {
        placements.append(rect)
        sizes.append(size)
    }

    func keyDown(_ event: NSEvent) { record("keyDown", event) }
    func keyUp(_ event: NSEvent) { record("keyUp", event) }
    func flagsChanged(_ event: NSEvent) { record("flagsChanged", event) }
    func mouseMoved(_ event: NSEvent) { record("mouseMoved", event) }
    func scrollWheel(_ event: NSEvent) { record("scrollWheel", event) }
    func mouseDragged(_ event: NSEvent, button: GuestMouseButton) { record("mouseDragged", event, button) }
    func mouseDown(_ event: NSEvent, button: GuestMouseButton) { record("mouseDown", event, button) }
    func mouseUp(_ event: NSEvent, button: GuestMouseButton) { record("mouseUp", event, button) }

    private func record(_ name: String, _ event: NSEvent, _ button: GuestMouseButton? = nil) {
        calls.append(name)
        events.append(event)
        if let button { buttons.append(button) }
    }
}

/// Events of every kind the picture's view passes on, made without a window.
@MainActor
enum SampleEvents {
    static func key(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    static func key(
        _ type: NSEvent.EventType, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: isRepeat, keyCode: keyCode))
    }

    static func mouse(_ type: NSEvent.EventType, at location: CGPoint = .zero) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    /// A press or release of the mouse button `number` (2 is the third button), as the system makes it.
    static func button(_ type: CGEventType, number: UInt32) throws -> NSEvent {
        let button = try #require(CGMouseButton(rawValue: number))
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button))
        return try #require(NSEvent(cgEvent: event))
    }

    static func scroll(_ units: CGScrollEventUnit = .line, by amount: Int32 = 1) throws -> NSEvent {
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
        return try #require(cgEvent.flatMap { NSEvent(cgEvent: $0) })
    }
}
