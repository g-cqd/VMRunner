import Testing

@testable import VirtioGPU

/// How the host tells the guest that the display changed: by writing the configuration space.
struct DisplayChangeTests {
    @Test
    func theGuestIsToldByClearingTheEventAndThenSettingIt() {
        let spaces = GPUConfigSpace.displayChange
        #expect(spaces.map(\.eventsRead) == [0, GPUWire.eventDisplay])
        #expect(spaces.allSatisfy { $0.eventsClear == 0 && $0.scanoutCount == 1 && $0.capsetCount == 0 })
    }

    @Test
    func eachWriteDiffersFromTheOneBeforeItWhateverNumberOfResizesCameBefore() {
        let first = GPUConfigSpace.displayChange[0].bytes
        let second = GPUConfigSpace.displayChange[1].bytes
        #expect(first != second)
        // The device starts with the event clear, so only the setting of the first resize can reach the guest as a change.
        let start = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0).bytes
        #expect(start == first)
        var written = [start]
        for _ in 1...4 { written += [first, second] }
        #expect(zip(written.dropFirst(), written).filter { $0 == $1 }.count == 1, "only the cleared write after the start repeats")
    }

    @Test
    func theEventIsTheFirstFieldAndTheOtherThreeAreTheOnesTheGuestAlreadyRead() {
        #expect(GPUConfigSpace.displayChange[1].bytes == [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(GPUConfigSpace.displayChange[0].bytes == [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }
}
