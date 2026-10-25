import AppKit
import Foundation
import Testing
import Virtualization

@testable import VMRunner
@testable import VirtioGPU
@testable import VirtioInput

/// A device stand-in that keeps the events it is sent.
@MainActor
private final class RecordingSink: InputEventSink {
    private(set) var events: [InputEvent] = []

    func send(_ frames: [InputEvent]) { events += frames }

    /// The key and button events, as `code:value`.
    var keys: [String] { events.filter { $0.type == InputEventType.key }.map { "\($0.code):\($0.value)" } }
    /// The pointer positions: each frame starts with the x axis and has the y axis next.
    var positions: [[Int32]] {
        events.indices.compactMap { index in
            events[index].type == InputEventType.abs && events[index].code == InputCode.absX
                ? [events[index].value, events[index + 1].value] : nil
        }
    }
    var wheel: [Int32] { events.filter { $0.type == InputEventType.rel }.map(\.value) }
}

/// The virtio path's surface, driven by events of the window and observed at the devices' side, with no device and no machine.
@MainActor
struct VirtioInputSurfaceTests {
    private let keyboard = RecordingSink()
    private let pointer = RecordingSink()
    private let range = VirtioInputStaticConfig.tabletRange

    /// The surface with the view it serves and the window the view is in, which the test keeps alive.
    @available(macOS 27.0, *)
    private struct Rig {
        let surface: VirtioInputSurface
        let view: CustomGPUView
        let window: NSWindow
    }

    /// A view of 1000 × 400 points in a window whose content has the same size (so a point of the window is a point of the view),
    /// showing a 1280 × 800 picture: 640 × 400 with bars of 180 points.
    @available(macOS 27.0, *)
    private func rig() -> Rig {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let view = CustomGPUView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        window.contentView?.addSubview(view)
        let surface = VirtioInputSurface(keyboard: keyboard, pointer: pointer)
        view.use(surface)
        view.present(
            frame: ScanoutUpdate(width: 1280, height: 800, format: .b8g8r8x8, pixels: [UInt8](repeating: 0, count: 1280 * 800 * 4)))
        return Rig(surface: surface, view: view, window: window)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func keysGoToTheKeyboardByTheLibrarysTableAndRepeatsAndUnmappedKeysAreIgnored() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        surface.keyDown(try SampleEvents.key(.keyDown, keyCode: 0x00))
        surface.keyDown(try SampleEvents.key(.keyDown, keyCode: 0x00, isRepeat: true))
        surface.keyDown(try SampleEvents.key(.keyDown, keyCode: 0x34))
        surface.keyUp(try SampleEvents.key(.keyUp, keyCode: 0x00))
        surface.keyUp(try SampleEvents.key(.keyUp, keyCode: 0x24))
        #expect(keyboard.keys == ["30:1", "30:0"])
        #expect(keyboard.events.filter { $0 == .report }.count == 2 && pointer.events.isEmpty)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aChangeOfAModifierIsDiffedByItsKeyCode() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        surface.flagsChanged(try SampleEvents.key(.flagsChanged, keyCode: 0x38, flags: .shift))
        surface.flagsChanged(try SampleEvents.key(.flagsChanged, keyCode: 0x37, flags: [.shift, .command]))
        surface.flagsChanged(try SampleEvents.key(.flagsChanged, keyCode: 0x38, flags: .command))
        surface.flagsChanged(try SampleEvents.key(.flagsChanged, keyCode: 0x37, flags: []))
        #expect(keyboard.keys == ["42:1", "125:1", "42:0", "125:0"])
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func thePointerIsPlacedOverThePicturesRectangleAndClampedOutsideIt() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        let (low, high) = (range.lowerBound, range.upperBound)
        for point in [CGPoint(x: 180, y: 400), CGPoint(x: 820, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 500, y: 9999)] {
            surface.mouseMoved(try SampleEvents.mouse(.mouseMoved, at: point))
        }
        surface.mouseDragged(try SampleEvents.mouse(.leftMouseDragged, at: CGPoint(x: 820, y: 400)), button: .left)
        #expect(
            pointer.positions == [[low, low], [high, high], [low, (low + high + 1) / 2], [(low + high + 1) / 2, low], [high, low]])
        #expect(keyboard.events.isEmpty)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func nothingMovesTheGuestsPointerBeforeThereIsAPicture() throws {
        guard #available(macOS 27.0, *) else { return }
        let surface = VirtioInputSurface(keyboard: keyboard, pointer: pointer)
        surface.mouseMoved(try SampleEvents.mouse(.mouseMoved, at: CGPoint(x: 5, y: 5)))
        #expect(pointer.events.isEmpty)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aClickMovesThePointerThenPressesAndReleasesTheButtonAndTheThirdIsTheMiddleOne() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        surface.mouseDown(try SampleEvents.mouse(.leftMouseDown, at: CGPoint(x: 500, y: 200)), button: .left)
        surface.mouseUp(try SampleEvents.mouse(.leftMouseUp, at: CGPoint(x: 500, y: 200)), button: .left)
        surface.mouseDown(try SampleEvents.mouse(.rightMouseDown, at: CGPoint(x: 500, y: 200)), button: .right)
        surface.mouseUp(try SampleEvents.mouse(.rightMouseUp), button: .right)
        surface.mouseDown(try SampleEvents.button(.otherMouseDown, number: 2), button: .other)
        surface.mouseUp(try SampleEvents.button(.otherMouseUp, number: 2), button: .other)
        surface.mouseDown(try SampleEvents.button(.otherMouseDown, number: 3), button: .other)
        surface.mouseUp(try SampleEvents.button(.otherMouseUp, number: 3), button: .other)
        #expect(pointer.keys == ["272:1", "272:0", "273:1", "273:0", "274:1", "274:0"], "the fourth button has none")
        #expect(pointer.positions.count == 8, "every click carries a position, before the button")
        #expect(pointer.events.first?.type == InputEventType.abs)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theWheelTurnsByTheEventsVerticalDeltaOnly() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        let lines = try SampleEvents.scroll(.line, by: 3)
        surface.scrollWheel(lines)
        let expected = Int32(lines.scrollingDeltaY)
        #expect(expected != 0 && pointer.wheel == [expected] && !lines.hasPreciseScrollingDeltas)
        let pixels = try SampleEvents.scroll(.pixel, by: 64)
        surface.scrollWheel(pixels)
        #expect(pixels.hasPreciseScrollingDeltas && pointer.wheel.last == Int32(pixels.scrollingDeltaY / PointerState.pointsPerNotch))
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func whenTheWindowLosesTheKeyboardEveryKeyAndButtonHeldComesUp() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        surface.keyDown(try SampleEvents.key(.keyDown, keyCode: 0x00))
        surface.flagsChanged(try SampleEvents.key(.flagsChanged, keyCode: 0x3B, flags: .control))
        surface.mouseDown(try SampleEvents.mouse(.leftMouseDown, at: CGPoint(x: 500, y: 200)), button: .left)
        surface.focusLost()
        #expect(keyboard.keys == ["30:1", "29:1", "29:0", "30:0"])
        #expect(pointer.keys == ["272:1", "272:0"])
        surface.focusLost()
        #expect(keyboard.keys.count == 4 && pointer.keys.count == 2, "nothing is held any more")
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aViewThatWasMovedAwayFromLeavesThePictureAsItWas() throws {
        guard #available(macOS 27.0, *) else { return }
        let setup = rig()
        defer { withExtendedLifetime(setup) {} }
        let surface = setup.surface
        let other = CustomGPUView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        surface.detach(from: other)
        surface.mouseMoved(try SampleEvents.mouse(.mouseMoved, at: CGPoint(x: 500, y: 200)))
        #expect(pointer.positions.count == 1)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theRealSurfaceHasAKeyboardAndATabletOfTheLibrarysLayoutsAndASurfaceOverStandInsHasNone() {
        guard #available(macOS 27.0, *) else { return }
        #expect(VirtioInputSurface(keyboard: keyboard, pointer: pointer).makeConfigurations().isEmpty)
        let configurations = VirtioInputSurface().makeConfigurations()
        #expect(configurations.map(\.deviceID) == [18, 18])
        #expect(
            configurations.map { $0.deviceSpecificConfiguration?.configurationData } == [
                Data(VirtioInputStaticConfig.keyboard.bytes), Data(VirtioInputStaticConfig.tablet.bytes),
            ])
        let defaults = VZCustomVirtioDeviceConfiguration().optionalFeatures
        for configuration in configurations {
            #expect(configuration.pciClassID == 0x09 && configuration.pciSubclassID == 0x80 && configuration.virtioQueueCount == 2)
            #expect(configuration.mandatoryFeatures.subset0 == 0 && configuration.mandatoryFeatures.subset1 == 1)
            #expect(
                configuration.optionalFeatures.subset0 == defaults.subset0 && configuration.optionalFeatures.subset1 == defaults.subset1)
            #expect(!configuration.supportsSaveRestore && configuration.provider != nil)
            #expect(configuration.deviceSpecificConfiguration?.configurationData.count == InputWire.configSize)
        }
    }
}
