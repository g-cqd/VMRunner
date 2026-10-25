import Testing

@testable import VirtioInput

/// The two fixed layouts of the configuration space, as the Linux driver's probe reads them.
struct StaticConfigTests {
    private static let layouts = [VirtioInputStaticConfig.keyboard, .tablet]

    private static func probe(_ layout: VirtioInputStaticConfig) throws -> LinuxInputProbe {
        try LinuxInputProbe.run(layout.bytes).get()
    }

    @Test(arguments: layouts)
    func aLayoutIsTheWholeConfigurationSpaceWithNothingSelected(layout: VirtioInputStaticConfig) {
        #expect(layout.bytes.count == InputWire.configSize)
        #expect(layout.bytes[0] == 0 && layout.bytes[1] == 0, "select and subsel")
        #expect(layout.bytes[3...7].allSatisfy { $0 == 0 }, "the reserved bytes")
        #expect(layout.bytes[2] != 0, "a size of 0 would tell the driver there is nothing to read")
    }

    @Test(arguments: layouts)
    func theDriverAcceptsALayoutAndGivesItEveryEventType(layout: VirtioInputStaticConfig) throws {
        let device = try Self.probe(layout)
        let everyType: Set<Int> = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x11, 0x12, 0x14]
        #expect(device.eventTypes == everyType)
    }

    /// The guest's input library refuses a device that has one axis of a pair and not the other.
    @Test(arguments: layouts)
    func aLayoutNeverHasOneAxisOfAPairWithoutTheOther(layout: VirtioInputStaticConfig) throws {
        let device = try Self.probe(layout)
        #expect(device.absoluteAxes.contains(0) == device.absoluteAxes.contains(1), "ABS_X and ABS_Y")
        #expect(device.relativeAxes.contains(0) == device.relativeAxes.contains(1), "REL_X and REL_Y")
        #expect(device.absoluteAxes.contains(0x35) == device.absoluteAxes.contains(0x36), "ABS_MT_POSITION_X and Y")
    }

    @Test
    func theKeyboardHasEveryMappedKeyAndNoOther() throws {
        let device = try Self.probe(.keyboard)
        #expect(device.keys == Set(VirtioKeyMap.linuxKeys.map(Int.init)))
        #expect(VirtioInputStaticConfig.keyboard.bytes[2] == 59, "KEY_FN is bit 464, byte 58")
        #expect(device.keys.contains(464) && device.keys.isSuperset(of: 1...63), "keys 1 to 63 have no gap")
    }

    @Test
    func theKeyboardsAbsoluteMaximumIsMinusOneSoTheDriverMakesNoMultitouchSlots() throws {
        let device = try Self.probe(.keyboard)
        #expect(device.absoluteAxes.contains(LinuxInputProbe.absMultitouchSlot))
        #expect(device.ranges[LinuxInputProbe.absMultitouchSlot]?.maximum == -1, "no slots: the probe succeeds")
    }

    /// What the guest also believes of the keyboard, because every bitmap is the key bitmap: the documented side effects.
    @Test
    func theKeyboardsBitmapIsAlsoItsOtherBitmaps() throws {
        let device = try Self.probe(.keyboard)
        #expect(device.absoluteAxes == Set(0..<64))
        #expect(device.relativeAxes == Set(0..<16))
        #expect(device.leds == Set(0..<16))
        #expect(device.properties == Set(0..<32))
        #expect(device.switches == Set(0..<17) && device.miscellaneous == Set(0..<8) && device.sounds == Set(0..<4))
        #expect(device.ids == LinuxInputProbe.Ids(bustype: 0xFFFF, vendor: 0xFFFF, product: 0xFFFF, version: 0xFFFF))
        #expect(device.name.count == 16 && device.nameBytes.count == 59)
    }

    @Test
    func theTabletHasTheAbsoluteAxesTheButtonsAndTheVerticalWheel() throws {
        let device = try Self.probe(.tablet)
        let range = LinuxInputProbe.AxisRange(minimum: 259, maximum: 16384, fuzz: 0, flat: 0, resolution: 0)
        #expect(VirtioInputStaticConfig.tabletRange == 259...16384)
        #expect(device.ranges[0] == range && device.ranges[1] == range)
        #expect(device.keys.isSuperset(of: [0x110, 0x111, 0x112]))
        #expect(device.relativeAxes.contains(8) && !device.relativeAxes.contains(6), "REL_WHEEL, and no REL_HWHEEL")
        #expect(!device.absoluteAxes.contains(LinuxInputProbe.absMultitouchSlot))
    }

    /// What the guest also believes of the tablet, because every bitmap is the same few bytes: the documented side effects.
    @Test
    func theTabletsBitmapIsAlsoItsOtherBitmaps() throws {
        let device = try Self.probe(.tablet)
        #expect(device.keys == [1, 8, 46, 0x110, 0x111, 0x112])
        #expect(device.absoluteAxes == [0, 1, 8, 46])
        #expect(device.relativeAxes == [0, 1, 8])
        #expect(device.properties == [0, 1, 8], "INPUT_PROP_POINTER and INPUT_PROP_DIRECT; not the accelerometer's bit 6")
        #expect(device.ids == LinuxInputProbe.Ids(bustype: 0x0103, vendor: 0, product: 0x4000, version: 0))
        #expect(device.name == [3, 1] && VirtioInputStaticConfig.tablet.bytes[2] == 35)
    }

    @Test
    func theTabletRangeIsInsideTheWholeNumbersTheGuestCanHold() {
        let range = VirtioInputStaticConfig.tabletRange
        #expect(range.lowerBound >= 0 && range.upperBound > range.lowerBound)
        #expect(range.upperBound < 0x8000, "bit 15 of the maximum would be ABS_MT_SLOT, whose slot count must stay valid")
    }
}
