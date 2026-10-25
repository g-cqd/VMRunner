import AppKit
import VirtioInput

/// The keys of a Mac keyboard as the guest's virtio keyboard sees them: what a key press, a release or a change of the
/// modifiers sends, and which keys the guest holds down, so that none stays down when the window loses the keyboard.
struct KeyboardState {
    /// The modifier keys by the flag that says one of them is down, with the virtual key code of each (left, then right).
    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, keyCodes: [UInt16])] = [
        (.shift, [0x38, 0x3C]), (.control, [0x3B, 0x3E]), (.option, [0x3A, 0x3D]), (.command, [0x37, 0x36]), (.function, [0x3F]),
    ]
    private static let capsLockKeyCode: UInt16 = 0x39

    /// The Linux keys the guest holds down, as far as this state has sent them.
    private var held: Set<UInt16> = []

    /// A key went down. A key the table does not map, and the repeat of a held key (the guest repeats by itself), send nothing.
    mutating func press(keyCode: UInt16, isRepeat: Bool) -> [InputEvent] {
        guard !isRepeat, let key = VirtioKeyMap.linuxKey(forMacKeyCode: keyCode) else { return [] }
        held.insert(key)
        return InputEvents.key(key, .press)
    }

    /// A key went up. Only a key this state sent down is released: a key pressed before the window had the keyboard, or one
    /// taken by a menu shortcut, has nothing to release.
    mutating func release(keyCode: UInt16) -> [InputEvent] {
        guard let key = VirtioKeyMap.linuxKey(forMacKeyCode: keyCode), held.remove(key) != nil else { return [] }
        return InputEvents.key(key, .release)
    }

    /// A modifier key changed; `keyCode` says which, `flags` the modifiers now. A flag that is clear means none of its keys is
    /// down (every one held is released); a flag that is set means this key went down, or went up while the other key of its
    /// pair still holds the flag. Caps lock reports once for each change of its state, which the guest's own caps lock toggles
    /// on a tap.
    mutating func modifiersChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [InputEvent] {
        guard let key = VirtioKeyMap.linuxKey(forMacKeyCode: keyCode) else { return [] }
        if keyCode == Self.capsLockKeyCode { return InputEvents.key(key, .press) + InputEvents.key(key, .release) }
        guard let modifier = Self.modifierKeys.first(where: { $0.keyCodes.contains(keyCode) }) else { return [] }
        if flags.contains(modifier.flag) {
            return held.contains(key) ? release(keyCode: keyCode) : press(keyCode: keyCode, isRepeat: false)
        }
        return modifier.keyCodes.flatMap { release(keyCode: $0) }
    }

    /// A key-up for every key held, for a window that lost the keyboard: it would never see the keys come up.
    mutating func releaseAll() -> [InputEvent] {
        let keys = held.sorted()
        held = []
        return keys.flatMap { InputEvents.key($0, .release) }
    }
}

/// The pointer as the guest's virtio tablet sees it: where it is, which buttons are down, and the wheel.
struct PointerState {
    /// How many points of a trackpad's scroll make one notch of the wheel; a mouse wheel reports lines, one notch each. The
    /// real run shows whether the guest scrolls too fast or too slowly with these.
    static let pointsPerNotch = 16.0

    private var held: Set<PointerButton> = []
    /// The part of a notch scrolled and not yet sent.
    private var carry = 0.0

    /// The pointer at `point` of a view of `view` points, origin at the bottom left as AppKit's, over a picture that occupies
    /// `picture` (origin at the top left, `ScreenPlacement.pictureRect`). A point outside the picture lands on its nearest edge.
    /// Nothing is sent while there is no picture.
    static func position(of point: CGPoint, picture: CGRect, in view: CGSize) -> [InputEvent] {
        guard picture != .zero else { return [] }
        return InputEvents.pointer(
            x: point.x - picture.minX, y: view.height - point.y - picture.minY, viewWidth: picture.width, viewHeight: picture.height,
            range: VirtioInputStaticConfig.tabletRange)
    }

    /// The tablet's button for a mouse button of the window: the left and right ones, and the third (`buttonNumber` 2) as the
    /// middle one. The others have no button on the tablet.
    static func button(_ button: GuestMouseButton, number: Int) -> PointerButton? {
        switch button {
        case .left: .left
        case .right: .right
        case .other: number == 2 ? .middle : nil
        }
    }

    mutating func press(_ button: PointerButton) -> [InputEvent] {
        held.insert(button)
        return InputEvents.button(button, pressed: true)
    }

    /// Only a button this state sent down is released.
    mutating func release(_ button: PointerButton) -> [InputEvent] {
        guard held.remove(button) != nil else { return [] }
        return InputEvents.button(button, pressed: false)
    }

    /// The wheel turned by `delta` (a scroll's vertical delta, positive scrolling up): the whole notches it adds up to, with the
    /// rest carried to the next. Something that is not a number sends nothing.
    mutating func scroll(delta: Double, precise: Bool) -> [InputEvent] {
        guard delta.isFinite else { return [] }
        carry += precise ? delta / Self.pointsPerNotch : delta
        let notches = carry.rounded(.towardZero)
        carry -= notches
        // A wheel does not turn by a billion notches: the clamp only keeps the conversion from trapping.
        return InputEvents.scroll(notches: Int32(min(max(notches, -1e9), 1e9)))
    }

    /// A release for every button held, for a window that lost the pointer.
    mutating func releaseAll() -> [InputEvent] {
        let buttons = held.sorted { $0.rawValue < $1.rawValue }
        held = []
        carry = 0
        return buttons.flatMap { InputEvents.button($0, pressed: false) }
    }
}
