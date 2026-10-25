import AppKit
import Testing

@testable import VMRunner
@testable import VirtioInput

/// What the window's keys, modifiers, pointer and wheel become for the guest's virtio input devices.
struct GuestInputTranslationTests {
    private func keys(_ events: [InputEvent]) -> [String] {
        events.filter { $0.type == InputEventType.key }.map { "\($0.code):\($0.value)" }
    }

    // MARK: Keys

    @Test
    func aKeyIsPressedAndReleasedAndAnUnmappedKeyIsIgnored() {
        var state = KeyboardState()
        #expect(state.press(keyCode: 0x00, isRepeat: false) == InputEvents.key(30, .press), "A")
        #expect(state.release(keyCode: 0x00) == InputEvents.key(30, .release))
        #expect(state.press(keyCode: 0x34, isRepeat: false).isEmpty, "no such key on a Mac keyboard")
        #expect(state.press(keyCode: 0xFFFF, isRepeat: false).isEmpty)
    }

    @Test
    func aRepeatSendsNothingBecauseTheGuestRepeatsByItself() {
        var state = KeyboardState()
        _ = state.press(keyCode: 0x00, isRepeat: false)
        #expect(state.press(keyCode: 0x00, isRepeat: true).isEmpty)
        #expect(keys(state.releaseAll()) == ["30:0"])
    }

    @Test
    func onlyAKeyThatWentDownIsReleased() {
        var state = KeyboardState()
        #expect(state.release(keyCode: 0x00).isEmpty, "pressed before the window had the keyboard, or taken by a menu")
        _ = state.press(keyCode: 0x00, isRepeat: false)
        #expect(!state.release(keyCode: 0x00).isEmpty)
        #expect(state.release(keyCode: 0x00).isEmpty, "a second release has nothing to release")
    }

    @Test
    func everyKeyHeldIsReleasedWhenTheWindowLosesTheKeyboardAndOnlyOnce() {
        var state = KeyboardState()
        for code: UInt16 in [0x00, 0x0B, 0x24] { _ = state.press(keyCode: code, isRepeat: false) }
        #expect(keys(state.releaseAll()) == ["28:0", "30:0", "48:0"], "in the order of the Linux codes")
        #expect(state.releaseAll().isEmpty)
    }

    // MARK: Modifiers

    @Test
    func theLeftAndRightModifierKeysAreToldApartByTheirKeyCode() {
        var state = KeyboardState()
        #expect(keys(state.modifiersChanged(keyCode: 0x38, flags: .shift)) == ["42:1"], "left shift down")
        #expect(keys(state.modifiersChanged(keyCode: 0x3C, flags: .shift)) == ["54:1"], "right shift down; the flag was set already")
        #expect(keys(state.modifiersChanged(keyCode: 0x38, flags: .shift)) == ["42:0"], "left shift up while right holds the flag")
        #expect(keys(state.modifiersChanged(keyCode: 0x3C, flags: [])) == ["54:0"], "the flag is clear: right shift up")
    }

    @Test(arguments: [
        (UInt16(0x3B), NSEvent.ModifierFlags.control, UInt16(29)), (0x3E, .control, 97), (0x3A, .option, 56), (0x3D, .option, 100),
        (0x37, .command, 125), (0x36, .command, 126), (0x3F, .function, 464),
    ])
    func everyModifierKeyIsPressedAndReleasedAsItsLinuxKey(keyCode: UInt16, flag: NSEvent.ModifierFlags, linux: UInt16) {
        var state = KeyboardState()
        #expect(state.modifiersChanged(keyCode: keyCode, flags: flag) == InputEvents.key(linux, .press))
        #expect(state.modifiersChanged(keyCode: keyCode, flags: []) == InputEvents.key(linux, .release))
    }

    @Test
    func aClearFlagReleasesEveryKeyOfItsKindAndOnlyThose() {
        var state = KeyboardState()
        _ = state.modifiersChanged(keyCode: 0x38, flags: .shift)
        _ = state.modifiersChanged(keyCode: 0x3C, flags: .shift)
        _ = state.modifiersChanged(keyCode: 0x3B, flags: [.shift, .control])
        // The events for the shift keys' release were lost: the flag says that none is down.
        #expect(keys(state.modifiersChanged(keyCode: 0x3C, flags: .control)) == ["42:0", "54:0"])
        #expect(keys(state.releaseAll()) == ["29:0"], "control is still held")
    }

    @Test
    func capsLockIsATapBecauseTheGuestsOwnCapsLockToggles() {
        var state = KeyboardState()
        let tap = InputEvents.key(58, .press) + InputEvents.key(58, .release)
        #expect(state.modifiersChanged(keyCode: 0x39, flags: .capsLock) == tap)
        #expect(state.modifiersChanged(keyCode: 0x39, flags: []) == tap)
        #expect(state.releaseAll().isEmpty)
    }

    @Test
    func aChangeOfAKeyThatIsNotAModifierSendsNothing() {
        var state = KeyboardState()
        #expect(state.modifiersChanged(keyCode: 0x00, flags: .shift).isEmpty)
        #expect(state.modifiersChanged(keyCode: 0x34, flags: []).isEmpty)
    }

    // MARK: Pointer

    private let tablet = VirtioInputStaticConfig.tabletRange
    private let view = CGSize(width: 1000, height: 400)
    /// A 1280 × 800 picture in that view: 640 × 400 with bars of 180 on each side.
    private let picture = CGRect(x: 180, y: 0, width: 640, height: 400)

    private func position(_ x: Double, _ y: Double) -> [Int32] {
        PointerState.position(of: CGPoint(x: x, y: y), picture: picture, in: view).filter { $0.type == InputEventType.abs }.map(\.value)
    }

    @Test
    func thePointerIsScaledToTheTabletOverThePicturesRectangleWithItsOriginAtTheTopLeft() {
        let (low, high) = (tablet.lowerBound, tablet.upperBound)
        #expect(position(180, 400) == [low, low], "the picture's top left (AppKit's y is 400 there)")
        #expect(position(820, 0) == [high, high], "its bottom right")
        #expect(position(180, 0) == [low, high], "bottom left")
        #expect(position(500, 200) == [(low + high + 1) / 2, (low + high + 1) / 2])
    }

    @Test
    func aPointOnTheBarsOrOutsideTheViewLandsOnTheNearestEdgeOfThePicture() {
        let (low, high) = (tablet.lowerBound, tablet.upperBound)
        #expect(position(10, 200) == [low, (low + high + 1) / 2])
        #expect(position(990, 200) == [high, (low + high + 1) / 2])
        #expect(position(-5000, 9000) == [low, low])
        #expect(position(.nan, .infinity) == [low, low], "not numbers land at the start of the range")
    }

    @Test
    func thePointerSendsNothingWhileThereIsNoPicture() {
        #expect(PointerState.position(of: CGPoint(x: 5, y: 5), picture: .zero, in: view).isEmpty)
    }

    @Test
    func thePositionEndsInAReportSoTheGuestDeliversItAsOneMove() {
        let events = PointerState.position(of: CGPoint(x: 500, y: 200), picture: picture, in: view)
        #expect(events.count == 3 && events.last == .report)
    }

    // MARK: Buttons

    @Test
    func theLeftAndRightButtonsAndTheThirdAreTheTabletsAndTheOthersAreNot() {
        #expect(PointerState.button(.left, number: 0) == .left)
        #expect(PointerState.button(.right, number: 1) == .right)
        #expect(PointerState.button(.other, number: 2) == .middle)
        #expect(PointerState.button(.other, number: 3) == nil)
        #expect(PointerState.button(.other, number: 4) == nil)
    }

    @Test
    func aButtonIsReleasedOnlyIfItWasPressedAndAllAreWhenTheWindowLosesThePointer() {
        var state = PointerState()
        #expect(state.release(.left).isEmpty)
        _ = state.press(.right)
        _ = state.press(.left)
        #expect(state.releaseAll() == InputEvents.button(.left, pressed: false) + InputEvents.button(.right, pressed: false))
        #expect(state.releaseAll().isEmpty)
    }

    // MARK: Wheel

    @Test
    func aMouseWheelSendsOneNotchPerLineAndKeepsTheFractionForTheNextEvent() {
        var state = PointerState()
        #expect(state.scroll(delta: 2, precise: false) == InputEvents.scroll(notches: 2))
        #expect(state.scroll(delta: -3, precise: false) == InputEvents.scroll(notches: -3), "negative scrolls down")
        #expect(state.scroll(delta: 0.6, precise: false).isEmpty)
        #expect(state.scroll(delta: 0.6, precise: false) == InputEvents.scroll(notches: 1), "0.6 and 0.6 make one and leave 0.2")
    }

    @Test
    func aTrackpadSendsOneNotchPerSixteenPointsAccumulatedAcrossEvents() {
        var state = PointerState()
        var notches: Int32 = 0
        for _ in 0..<100 { notches += state.scroll(delta: 3, precise: true).first?.value ?? 0 }
        #expect(notches == 18, "300 points are 18 notches and 12 points left over")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func aDeltaThatIsNotANumberSendsNothingAndDoesNotSpoilTheNext(delta: Double) {
        var state = PointerState()
        #expect(state.scroll(delta: delta, precise: false).isEmpty)
        #expect(state.scroll(delta: 1, precise: false) == InputEvents.scroll(notches: 1))
    }

    @Test
    func anAbsurdDeltaIsBoundedAndDoesNotTrap() {
        var state = PointerState()
        #expect(state.scroll(delta: 1e300, precise: false).first?.value == 1_000_000_000)
        #expect(state.scroll(delta: -1e300, precise: true).first?.value != nil)
    }
}
