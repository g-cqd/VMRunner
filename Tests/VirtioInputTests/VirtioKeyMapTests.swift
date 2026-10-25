import Testing

@testable import VirtioInput

/// The table from the Mac's virtual key codes to Linux key codes.
struct VirtioKeyMapTests {
    struct Pair: Sendable {
        let mac: UInt16
        let linux: UInt16
    }

    /// One key or more from each group of the table, written out from the two header files.
    static let samples = [
        Pair(mac: 0x00, linux: 30), Pair(mac: 0x01, linux: 31), Pair(mac: 0x06, linux: 44), Pair(mac: 0x0C, linux: 16),
        Pair(mac: 0x12, linux: 2), Pair(mac: 0x1D, linux: 11), Pair(mac: 0x16, linux: 7), Pair(mac: 0x17, linux: 6),
        Pair(mac: 0x0A, linux: 86), Pair(mac: 0x18, linux: 13), Pair(mac: 0x24, linux: 28), Pair(mac: 0x30, linux: 15),
        Pair(mac: 0x31, linux: 57), Pair(mac: 0x32, linux: 41), Pair(mac: 0x33, linux: 14), Pair(mac: 0x35, linux: 1),
        Pair(mac: 0x37, linux: 125), Pair(mac: 0x36, linux: 126), Pair(mac: 0x38, linux: 42), Pair(mac: 0x3C, linux: 54),
        Pair(mac: 0x3A, linux: 56), Pair(mac: 0x3D, linux: 100), Pair(mac: 0x3B, linux: 29), Pair(mac: 0x3E, linux: 97),
        Pair(mac: 0x39, linux: 58), Pair(mac: 0x3F, linux: 464), Pair(mac: 0x7A, linux: 59), Pair(mac: 0x6F, linux: 88),
        Pair(mac: 0x69, linux: 183), Pair(mac: 0x5A, linux: 190), Pair(mac: 0x52, linux: 82), Pair(mac: 0x5C, linux: 73),
        Pair(mac: 0x4C, linux: 96), Pair(mac: 0x47, linux: 69), Pair(mac: 0x51, linux: 117), Pair(mac: 0x73, linux: 102),
        Pair(mac: 0x77, linux: 107), Pair(mac: 0x74, linux: 104), Pair(mac: 0x79, linux: 109), Pair(mac: 0x75, linux: 111),
        Pair(mac: 0x72, linux: 110), Pair(mac: 0x6E, linux: 127), Pair(mac: 0x7B, linux: 105), Pair(mac: 0x7C, linux: 106),
        Pair(mac: 0x7D, linux: 108), Pair(mac: 0x7E, linux: 103), Pair(mac: 0x48, linux: 115), Pair(mac: 0x49, linux: 114),
        Pair(mac: 0x4A, linux: 113),
    ]

    @Test(arguments: samples)
    func aMacKeyCodeMapsToItsLinuxKey(pair: Pair) {
        #expect(VirtioKeyMap.linuxKey(forMacKeyCode: pair.mac) == pair.linux)
    }

    /// The codes `Events.h` leaves out between the mapped ones, its JIS keys, and codes that are not keys at all.
    @Test(arguments: [0x34, 0x42, 0x44, 0x46, 0x4D, 0x5D, 0x5E, 0x5F, 0x66, 0x68, 0x6C, 0x70, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF] as [UInt16])
    func aCodeTheTableDoesNotMapIsNil(code: UInt16) {
        #expect(VirtioKeyMap.linuxKey(forMacKeyCode: code) == nil)
    }

    @Test
    func theTableHasOneHundredAndFifteenKeysAndAllOfThemAreBelowTheKeyboardRange() {
        let mapped = (0...UInt16.max).filter { VirtioKeyMap.linuxKey(forMacKeyCode: $0) != nil }
        #expect(mapped.count == 115)
        #expect(mapped.allSatisfy { $0 < 0x80 })
    }

    @Test
    func noTwoMacKeysShareALinuxKey() {
        let linux = (0...UInt16(0x7F)).compactMap { VirtioKeyMap.linuxKey(forMacKeyCode: $0) }
        #expect(Set(linux).count == linux.count)
        #expect(VirtioKeyMap.linuxKeys == linux.sorted())
    }

    @Test
    func everyLinuxKeyFitsTheKeyBitmapOfTheGuest() {
        #expect(VirtioKeyMap.linuxKeys.allSatisfy { Int($0) < LinuxInputProbe.keyCount && $0 > 0 })
    }
}
