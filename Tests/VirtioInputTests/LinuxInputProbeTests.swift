import Testing

@testable import VirtioInput

/// The model of the Linux driver's probe, against configuration spaces made by hand and at random. A test of a layout that
/// passes through a wrong model proves nothing, so the model's own rules are pinned here, each from the driver's source.
struct LinuxInputProbeTests {
    /// A configuration space of `size` with these union bytes from the start of the union.
    private static func space(size: UInt8, union: [UInt8] = []) -> [UInt8] {
        [0, 0, size, 0, 0, 0, 0, 0] + union + Array(repeating: 0, count: max(0, 128 - union.count))
    }

    @Test
    func aSizeOfZeroRegistersNothingButTheSyncEventsAndABusOfTheVirtualKind() throws {
        let device = try LinuxInputProbe.run(Self.space(size: 0, union: [0xFF, 0xFF, 0xFF])).get()
        #expect(device.eventTypes == [0])
        #expect(device.keys.isEmpty && device.absoluteAxes.isEmpty && device.properties.isEmpty && device.nameBytes.isEmpty)
        #expect(device.ids.bustype == 6)
    }

    @Test
    func theIdsAreReadOnlyFromASizeOfEight() throws {
        let union: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let read = try LinuxInputProbe.run(Self.space(size: 8, union: union)).get()
        let skipped = try LinuxInputProbe.run(Self.space(size: 7, union: union)).get()
        #expect(read.ids == LinuxInputProbe.Ids(bustype: 0x0201, vendor: 0x0403, product: 0x0605, version: 0x0807))
        #expect(skipped.ids == LinuxInputProbe.Ids(bustype: 6, vendor: 0, product: 0, version: 0))
    }

    @Test
    func aBitmapIsClippedToTheSizeInBytesAndToTheTypesBitCount() throws {
        let one = try LinuxInputProbe.run(Self.space(size: 1, union: Array(repeating: 0xFF, count: 128))).get()
        #expect(one.relativeAxes == Set(0..<8) && one.leds == Set(0..<8), "one byte holds eight bits")
        #expect(one.properties == Set(0..<8) && one.sounds == Set(0..<4) && one.miscellaneous == Set(0..<8))
        let wide = try LinuxInputProbe.run(Self.space(size: 128, union: Array(repeating: 0xFF, count: 128))).get()
        #expect(wide.keys == Set(1..<LinuxInputProbe.keyCount), "KEY_RESERVED is cleared when the device is registered")
        #expect(wide.relativeAxes.count == LinuxInputProbe.relCount && wide.absoluteAxes.count == LinuxInputProbe.absCount)
    }

    @Test
    func theNameIsAtMostSixtyFourBytesAndReadsAsAStringUpToTheFirstZero() throws {
        let long = try LinuxInputProbe.run(Self.space(size: 200, union: Array(repeating: 0x41, count: 128))).get()
        #expect(long.nameBytes.count == 64 && long.serialBytes == long.nameBytes)
        let short = try LinuxInputProbe.run(Self.space(size: 9, union: [0x41, 0x42, 0, 0x43, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])).get()
        #expect(short.nameBytes.count == 9 && short.name == [0x41, 0x42])
    }

    @Test
    func anAbsoluteDeviceWithNoAxisIsRefused() {
        #expect(LinuxInputProbe.run(Self.space(size: 8)).failure == .absoluteWithoutAxes, "the axes are bits of the union: all zero")
        #expect(LinuxInputProbe.run(Self.space(size: 1, union: [0x01])).failure == nil)
        #expect(LinuxInputProbe.run(Self.space(size: 0)).failure == nil, "with a size of zero the device is not absolute")
    }

    struct SlotCase: Sendable {
        let maximum: [UInt8]
        let refusedAs: UInt32?
    }

    /// Bit 47 is `ABS_MT_SLOT`, bit 7 of byte 5; its slot count is the maximum (the word of bytes 4 to 7) plus one.
    static let slotCases = [
        SlotCase(maximum: [0xFF, 0xFF, 0xFF, 0xFF], refusedAs: nil),
        SlotCase(maximum: [0x00, 0x80, 0x00, 0x00], refusedAs: 0x8001),
        SlotCase(maximum: [0xFE, 0xFF, 0xFF, 0xFF], refusedAs: 0xFFFF_FFFF),
        SlotCase(maximum: [0xFF, 0xFF, 0xFF, 0x7F], refusedAs: 0x8000_0000),
        SlotCase(maximum: [0xFF, 0x7F, 0x00, 0x00], refusedAs: nil),
    ]

    @Test(arguments: slotCases)
    func theMultitouchSlotCountMustBeNoneOrAtMostAThousandAndTwentyFour(slot: SlotCase) {
        let result = LinuxInputProbe.run(Self.space(size: 8, union: [0x01, 0, 0, 0] + slot.maximum))
        #expect(result.failure == slot.refusedAs.map { LinuxInputProbe.Failure.multitouchSlots($0) })
    }

    @Test
    func randomConfigurationSpacesNeverTrapTheModelAndItsResultsAreConsistent() {
        var generator = XorShiftGenerator(seed: 0x1_0003)
        for round in 0..<5000 {
            var bytes = (0..<InputWire.configSize).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // A third of them sparse, so that spaces with few bits (and the failures) are common.
            if round.isMultiple(of: 3) { bytes = bytes.map { $0 & UInt8.random(in: 0...255, using: &generator) } }
            if round.isMultiple(of: 5) { bytes[2] = UInt8.random(in: 0...12, using: &generator) }
            switch LinuxInputProbe.run(bytes) {
            case .success(let device):
                #expect(device.keys.allSatisfy { $0 > 0 && $0 < LinuxInputProbe.keyCount })
                #expect(device.relativeAxes.allSatisfy { $0 < LinuxInputProbe.relCount })
                #expect(device.absoluteAxes.allSatisfy { $0 < LinuxInputProbe.absCount })
                #expect(device.eventTypes.contains(LinuxInputProbe.evAbs) == !device.absoluteAxes.isEmpty)
                #expect(device.eventTypes.contains(LinuxInputProbe.evKey) == (bytes[2] != 0) && device.nameBytes.count <= 64)
            case .failure(let failure):
                #expect(bytes[2] != 0)
                if case .multitouchSlots(let slots) = failure { #expect(slots > 1024) }
            }
        }
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
