/// What a key does to its state: the value of an `EV_KEY` event.
package enum KeyAction: Int32, Sendable {
    case release = 0
    case press = 1
    /// The guest repeats a held key by itself (the layouts advertise `EV_REP`), so the host sends none of these.
    case autorepeat = 2
}

/// The events of one input from the host, each list a whole frame: it ends with `EV_SYN` / `SYN_REPORT`, which the guest's input
/// core waits for before it delivers anything. Queue a list whole (`InputEventQueue.enqueue`) so a full queue drops it whole.
package enum InputEvents {  // @dw:accept:this referenced-only-by-tests -- the app links it later
    /// A key pressed, released or repeated; `linuxKey` is a `KEY_*` code (`VirtioKeyMap`).
    package static func key(_ linuxKey: UInt16, _ action: KeyAction) -> [InputEvent] {
        [InputEvent(type: InputEventType.key, code: linuxKey, value: action.rawValue), .report]
    }

    /// A pointer button pressed or released.
    package static func button(_ button: PointerButton, pressed: Bool) -> [InputEvent] {
        key(button.rawValue, pressed ? .press : .release)
    }

    /// The pointer at `x`, `y` in a view of `viewWidth` × `viewHeight`, measured from the view's top left corner, y growing
    /// downwards, in any unit (points or pixels, as long as all four agree). The guest's display has its origin at its top left
    /// too, so a caller whose view has its origin at the bottom left (AppKit's default) passes `viewHeight - y`.
    ///
    /// The position is scaled to `range` (`VirtioInputStaticConfig.tabletRange`) and clamped to it: a point outside the view lands
    /// on its edge, NaN and an extent that is not a positive number land at the range's start, infinities on an edge.
    package static func pointer(
        x: Double, y: Double, viewWidth: Double, viewHeight: Double, range: ClosedRange<Int32>
    ) -> [InputEvent] {
        [
            InputEvent(type: InputEventType.abs, code: InputCode.absX, value: scaled(x, extent: viewWidth, to: range)),
            InputEvent(type: InputEventType.abs, code: InputCode.absY, value: scaled(y, extent: viewHeight, to: range)),
            .report,
        ]
    }

    /// The vertical wheel turned by `notches` (positive scrolls up, away from the user); nothing for 0.
    package static func scroll(notches: Int32) -> [InputEvent] {
        notches == 0 ? [] : [InputEvent(type: InputEventType.rel, code: InputCode.relWheel, value: notches), .report]
    }

    private static func scaled(_ value: Double, extent: Double, to range: ClosedRange<Int32>) -> Int32 {
        let ratio = extent > 0 ? value / extent : 0
        let fraction = ratio.isNaN ? 0 : min(max(ratio, 0), 1)
        let low = Double(range.lowerBound)
        // `fraction` is in 0...1, so the sum is in the range and the conversion cannot trap.
        return Int32(low + (fraction * (Double(range.upperBound) - low)).rounded())
    }
}
