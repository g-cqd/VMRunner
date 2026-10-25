/// What the guest sees of the device before any event: its virtio identity, its queues, the size of its configuration space and
/// the feature bit it needs (virtio specification 1.2, section 5.8).
package enum InputWire {
    /// The virtio device ID of an input device.
    package static let deviceID: UInt16 = 18
    /// PCI class 0x09, input device controller.
    package static let pciClassID: UInt8 = 0x09
    /// PCI subclass 0x80, "other input controller": the guest binds by the virtio device ID, not by this.
    package static let pciSubclassID: UInt8 = 0x80
    /// The event queue (device to driver) and the status queue (driver to device).
    package static let queueCount: UInt16 = 2
    package static let eventQueue: UInt16 = 0
    package static let statusQueue: UInt16 = 1
    /// `VIRTIO_F_VERSION_1` is feature bit 32: bit 0 of the upper 32-bit half of the feature set. The Linux driver refuses a device
    /// without it.
    package static let versionOneFeatureSubset1: UInt32 = 1
    /// One event on either queue: type, code and value.
    package static let eventSize = 8
    /// `struct virtio_input_config`: select, subsel, size and five reserved bytes, then a union of 128 bytes.
    package static let configSize = 136  // @dw:accept:this referenced-only-by-tests -- the tests pin the size of the layouts
}

/// The event types the library produces. The codes are those of the Linux input subsystem, which the guest's driver passes on
/// unchanged.
package enum InputEventType {
    package static let syn: UInt16 = 0x00
    package static let key: UInt16 = 0x01
    package static let rel: UInt16 = 0x02
    package static let abs: UInt16 = 0x03
}

/// The event codes the library names, from `input-event-codes.h`.
package enum InputCode {
    /// `ABS_X` and `ABS_Y`: the pointer's position, from the top left of the guest's display.
    package static let absX: UInt16 = 0x00
    package static let absY: UInt16 = 0x01
    /// `REL_WHEEL`: the vertical scroll wheel, in notches, positive away from the user.
    package static let relWheel: UInt16 = 0x08
}

/// The buttons of the pointer, by their `BTN_*` code.
package enum PointerButton: UInt16, CaseIterable, Sendable {
    case left = 0x110
    case right = 0x111
    case middle = 0x112
}

/// One input event as the queues carry it: a little-endian 16-bit type, a 16-bit code and a signed 32-bit value (`struct
/// virtio_input_event`).
package struct InputEvent: Equatable, Sendable {
    /// `EV_SYN` with this code closes a frame: the guest's input core delivers the events before it as one.
    package static let report = Self(type: InputEventType.syn, code: 0, value: 0)

    package var type: UInt16
    package var code: UInt16
    package var value: Int32

    package init(type: UInt16, code: UInt16, value: Int32) {
        self.type = type
        self.code = code
        self.value = value
    }

    /// The event in the 8 bytes a buffer of the event queue takes.
    package var bytes: [UInt8] {
        let word = UInt32(bitPattern: value)
        return [
            UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: type >> 8),
            UInt8(truncatingIfNeeded: code), UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
            UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24),
        ]
    }

    /// Decodes exactly 8 bytes; any other length is not an event.
    package init?(bytes: [UInt8]) {
        guard bytes.count == InputWire.eventSize else { return nil }
        type = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        code = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        var word: UInt32 = 0
        for index in (4..<8).reversed() { word = word << 8 | UInt32(bytes[index]) }
        value = Int32(bitPattern: word)
    }

    /// Whether this event closes a frame.
    var endsFrame: Bool { type == InputEventType.syn && code == 0 }
}
