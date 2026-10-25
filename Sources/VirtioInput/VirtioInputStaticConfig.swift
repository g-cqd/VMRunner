/// The device-specific configuration space of a virtio input device (`struct virtio_input_config`, 136 bytes), as one of two fixed
/// layouts, `keyboard` and `tablet`.
///
/// Why fixed: the Virtualization framework tells the host nothing when the guest writes `select` and `subsel`; the host can only
/// replace the whole space with `update(_:)`. So the guest reads the same `size` and the same 128-byte union whatever it selects.
/// The Linux driver (`drivers/virtio/virtio_input.c`) reads that one union as the device's name, its serial number, its ids,
/// its property bits, the bitmap of every event type it asks about (key, relative, absolute, misc, switch, LED, sound) and the
/// range of every absolute axis it finds. Each layout is one bitmap chosen so that those readings add up to a device the driver
/// accepts and userland treats as intended. The tests replay the driver's probe on the bytes (`LinuxInputProbe`). What follows
/// was derived from the driver's sources and from the sources of the guest's device manager and input library, and has not been
/// run against a guest.
///
/// Both layouts give the guest, besides what they are for:
/// - a name and a serial number that are the first bytes of the union (not text), and ids made of the first eight bytes;
/// - every event type, `EV_REP` included, so the guest repeats a held key by itself: the host must not send repeats;
/// - an `EV_LED` and an `EV_SND` it may write to the status queue, which the host decodes and ignores;
/// - a `SW_LID` and a `SW_TABLET_MODE` switch that never change, and the property bits and axes read off the same bytes.
package struct VirtioInputStaticConfig: Equatable, Sendable {
    /// The 136 bytes the guest reads.
    package let bytes: [UInt8]

    /// A keyboard: every key `VirtioKeyMap` maps, in a bitmap of 59 bytes (`KEY_FN` is bit 464).
    ///
    /// The mapped keys cover bits 1 to 63 without a gap, and bit 0 (`KEY_RESERVED`, which the guest's input core clears) is set
    /// too, so `ABS_X` and `ABS_Y`, `REL_X` and `REL_Y` and the two multitouch positions come in pairs, which the guest's input
    /// library requires. The same bytes are the other bitmaps, so the guest also believes:
    /// - absolute axes 0 to 63, among them `ABS_MT_SLOT`; its range ends at the 32-bit word of bytes 4 to 7, which is -1, so the
    ///   driver sets up no multitouch slots and the probe succeeds;
    /// - relative axes 0 to 15 (including the wheels), LEDs 0 to 15 (including caps lock and scroll lock);
    /// - property bits 0 to 31, among them `INPUT_PROP_ACCELEROMETER`: the device manager tags the device as an
    ///   accelerometer as well as a keyboard, and the input library then ignores its axes and keeps the keyboard;
    /// - the ids `0xFFFF` everywhere, and a name of 16 bytes that are not text.
    package static let keyboard: Self = {  // @dw:accept:this referenced-only-by-tests -- the app links it later
        Self(bits: [0] + VirtioKeyMap.linuxKeys.map(Int.init))
    }()

    /// An absolute pointer: `ABS_X` and `ABS_Y` over `tabletRange`, three buttons and a vertical wheel.
    ///
    /// The bitmap holds the bits of `ABS_X`, `ABS_Y` and `REL_WHEEL` (0, 1 and 8) in its first bytes, so the range starts at their
    /// 32-bit word, 259; the maximum is the next word, 0x4000 (about 3 steps per pixel across a 5K display); and the buttons are
    /// bits 272 to 274, in byte 34.
    /// The same bytes are the other bitmaps, so the guest also believes:
    /// - relative axes `REL_X`, `REL_Y` and `REL_WHEEL` (the first two never move), and no horizontal wheel: its bit, 6, is
    ///   `INPUT_PROP_ACCELEROMETER` in the property bits, which would make the device manager call the pointer an accelerometer;
    /// - the properties `INPUT_PROP_POINTER` and `INPUT_PROP_DIRECT` (the device manager still calls it a mouse: it has a mouse button);
    /// - the keys `KEY_ESC`, `KEY_7` and `KEY_C`, from bits 1, 8 and 46 (46 is the maximum's top bit), and absolute axes 0, 1, 8
    ///   and 46 with the same range and no fuzz, flat or resolution;
    /// - the ids bus `0x0103`, vendor 0, product `0x4000`, version 0, and a name of two bytes that are not text.
    package static let tablet: Self = {  // @dw:accept:this referenced-only-by-tests -- the app links it later
        let axes = [Int(InputCode.absX), Int(InputCode.absY), Int(InputCode.relWheel)]
        let buttons = PointerButton.allCases.map { Int($0.rawValue) }
        // The maximum is the second 32-bit word of the union, which is bits 32 to 63 of every bitmap.
        let maximum: UInt32 = 0x4000
        return Self(bits: axes + (0..<32).filter { maximum >> $0 & 1 == 1 }.map { 32 + $0 } + buttons)
    }()

    /// The range of `ABS_X` and `ABS_Y` of `tablet`, read back from its bytes: the guest's pointer position is a point of this
    /// range, from the top left corner of its display to the bottom right one.
    package static let tabletRange: ClosedRange<Int32> = {  // @dw:accept:this referenced-only-by-tests -- the app links it later
        let low = Int32(bitPattern: tablet.word(at: 0))
        let high = Int32(bitPattern: tablet.word(at: 4))
        return low...max(low, high)
    }()

    /// A space whose union is the bitmap with these bits set, and whose size is the bitmap's length in bytes (at most 128: higher
    /// bits are left out).
    private init(bits: [Int]) {
        let size = min((bits.max() ?? 0) / 8 + 1, 128)
        var union = [UInt8](repeating: 0, count: 128)
        for bit in bits where bit / 8 < size { union[bit / 8] |= 1 << UInt8(bit % 8) }
        bytes = [0, 0, UInt8(size), 0, 0, 0, 0, 0] + union
    }

    /// The little-endian 32-bit word at `offset` of the union.
    private func word(at offset: Int) -> UInt32 {
        let start = 8 + offset
        return bytes[start..<start + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
