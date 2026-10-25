@testable import VirtioInput

/// The Linux virtio input driver's probe (`drivers/virtio/virtio_input.c`, `virtinput_probe`), replayed on the bytes of a
/// configuration space: what the driver would register with the input core, or why it would fail. The host cannot see the
/// guest write `select` and `subsel`, so every read of this model sees the same `size` and the same union, whatever the driver
/// selected; that is the whole point of the model. Reads past the 136 bytes (a `size` above 128) return zeros.
struct LinuxInputProbe {
    enum Failure: Error, Equatable {
        /// `EV_ABS` is advertised but no axis bit is set, so the input core has no `absinfo` and refuses to register.
        case absoluteWithoutAxes
        /// `ABS_MT_SLOT` is advertised with a maximum that makes `input_mt_init_slots` refuse the slot count (above 1024).
        case multitouchSlots(UInt32)
    }

    struct AxisRange: Equatable {
        var minimum: Int32
        var maximum: Int32
        var fuzz: Int32
        var flat: Int32
        var resolution: Int32
    }

    struct Ids: Equatable {
        var bustype: UInt16
        var vendor: UInt16
        var product: UInt16
        var version: UInt16
    }

    // The sizes of the bitmaps in the Linux input subsystem: KEY_CNT, REL_CNT, ABS_CNT, MSC_CNT, SW_CNT, LED_CNT, SND_CNT and
    // INPUT_PROP_CNT.
    static let keyCount = 0x300
    static let relCount = 0x10
    static let absCount = 0x40
    static let mscCount = 0x08
    static let switchCount = 0x11
    static let ledCount = 0x10
    static let soundCount = 0x04
    static let propertyCount = 0x20

    static let evKey = 0x01
    static let evRel = 0x02
    static let evAbs = 0x03
    static let evMsc = 0x04
    static let evSwitch = 0x05
    static let evLed = 0x11
    static let evSound = 0x12
    static let evRepeat = 0x14
    static let absMultitouchSlot = 0x2F

    /// The bytes the driver copies as the name (`min(size, 64)` of them), and as the serial number.
    private(set) var nameBytes: [UInt8] = []
    private(set) var serialBytes: [UInt8] = []
    private(set) var ids = Ids(bustype: 0, vendor: 0, product: 0, version: 0)
    private(set) var properties: Set<Int> = []
    private(set) var eventTypes: Set<Int> = []
    private(set) var keys: Set<Int> = []
    private(set) var relativeAxes: Set<Int> = []
    private(set) var absoluteAxes: Set<Int> = []
    private(set) var miscellaneous: Set<Int> = []
    private(set) var switches: Set<Int> = []
    private(set) var leds: Set<Int> = []
    private(set) var sounds: Set<Int> = []
    private(set) var ranges: [Int: AxisRange] = [:]

    /// The name as a C string: the bytes up to the first zero.
    var name: [UInt8] { Array(nameBytes.prefix { $0 != 0 }) }

    /// The driver's view of the 136 bytes, and the result of probing them.
    static func run(_ config: [UInt8]) -> Result<Self, Failure> {
        var probe = Self()
        let space = Space(bytes: config)
        probe.nameBytes = space.union(count: min(space.size, 64))
        probe.serialBytes = probe.nameBytes
        probe.ids = space.size >= 8 ? space.ids : Ids(bustype: 6, vendor: 0, product: 0, version: 0)
        probe.properties = space.bits(count: propertyCount)
        if space.size != 0 { probe.eventTypes.insert(evRepeat) }
        probe.readBitmaps(space)
        if probe.eventTypes.contains(evAbs) {
            if let failure = probe.readAxes(space) { return .failure(failure) }
        }
        // `input_register_device`: every device reports `EV_SYN`; `KEY_RESERVED` is cleared.
        probe.eventTypes.insert(0)
        probe.keys.remove(0)
        return .success(probe)
    }

    /// One `virtinput_cfg_bits` per event type: nothing when `size` is 0, else the type is advertised, with the bits the union
    /// has among the first `count`.
    private mutating func readBitmaps(_ space: Space) {
        guard space.size != 0 else { return }
        eventTypes.formUnion([Self.evKey, Self.evRel, Self.evAbs, Self.evMsc, Self.evSwitch, Self.evLed, Self.evSound])
        keys = space.bits(count: Self.keyCount)
        relativeAxes = space.bits(count: Self.relCount)
        absoluteAxes = space.bits(count: Self.absCount)
        miscellaneous = space.bits(count: Self.mscCount)
        switches = space.bits(count: Self.switchCount)
        leds = space.bits(count: Self.ledCount)
        sounds = space.bits(count: Self.soundCount)
    }

    /// `virtinput_cfg_abs` for each axis, then the multitouch slots, then the input core's refusal of an absolute device with no
    /// axis at all.
    private mutating func readAxes(_ space: Space) -> Failure? {
        guard !absoluteAxes.isEmpty else { return .absoluteWithoutAxes }
        for axis in absoluteAxes { ranges[axis] = space.range }
        guard absoluteAxes.contains(Self.absMultitouchSlot) else { return nil }
        // `nslots = max + 1` as an `int`, passed as an `unsigned int`: 0 makes no slots, above 1024 is refused. A count from 1 to
        // 1024 cannot occur: bit 47 of the bitmap is bit 15 of the maximum, which is then 0x8000 or more, or negative.
        let slots = UInt32(bitPattern: space.range.maximum &+ 1)
        return slots > 1024 ? .multitouchSlots(slots) : nil
    }

    /// The configuration space as the driver reads it.
    private struct Space {
        let bytes: [UInt8]

        var size: Int { Int(byte(2)) }

        func byte(_ offset: Int) -> UInt8 { offset < bytes.count ? bytes[offset] : 0 }

        func union(count: Int) -> [UInt8] { (0..<count).map { byte(8 + $0) } }

        func word(at offset: Int) -> UInt32 {
            union(count: offset + 4).suffix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        /// The bits of the union below `count` and below `8 × size`.
        func bits(count: Int) -> Set<Int> {
            let limit = min(count, size * 8)
            let union = union(count: (limit + 7) / 8)
            return Set((0..<limit).filter { union[$0 / 8] >> UInt8($0 % 8) & 1 == 1 })
        }

        /// The ids: four 16-bit words from the start of the union, read when `size` is at least 8.
        var ids: Ids {
            let first = word(at: 0)
            let second = word(at: 4)
            return Ids(
                bustype: UInt16(truncatingIfNeeded: first), vendor: UInt16(truncatingIfNeeded: first >> 16),
                product: UInt16(truncatingIfNeeded: second), version: UInt16(truncatingIfNeeded: second >> 16))
        }

        /// The range every absolute axis gets: five 32-bit words from the start of the union, read with no check of `size`.
        var range: AxisRange {
            AxisRange(
                minimum: Int32(bitPattern: word(at: 0)), maximum: Int32(bitPattern: word(at: 4)),
                fuzz: Int32(bitPattern: word(at: 8)), flat: Int32(bitPattern: word(at: 12)),
                resolution: Int32(bitPattern: word(at: 16)))
        }
    }
}
