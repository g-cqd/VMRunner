import Testing

@testable import VirtioInput

/// The event on the wire and the lists the encoder builds from the host's input.
struct InputEventTests {
    private static let report = InputEvent(type: 0, code: 0, value: 0)

    @Test
    func anEventIsEightLittleEndianBytes() {
        #expect(InputEvent(type: 1, code: 30, value: 1).bytes == [1, 0, 30, 0, 1, 0, 0, 0])
        #expect(InputEvent(type: 0x0302, code: 0x0504, value: 0x0908_0706).bytes == [2, 3, 4, 5, 6, 7, 8, 9])
        #expect(InputEvent(type: 2, code: 8, value: -2).bytes == [2, 0, 8, 0, 0xFE, 0xFF, 0xFF, 0xFF])
        #expect(InputEvent.report == Self.report)
    }

    @Test
    func theWireConstantsAreThoseOfTheSpecification() {
        #expect(InputWire.deviceID == 18, "PCI device 0x1052 is 0x1040 + 18")
        #expect(InputWire.queueCount == 2 && InputWire.eventQueue == 0 && InputWire.statusQueue == 1)
        #expect(InputWire.versionOneFeatureSubset1 == 1 && InputWire.eventSize == 8 && InputWire.configSize == 136)
        #expect(PointerButton.allCases.map(\.rawValue) == [0x110, 0x111, 0x112])
    }

    @Test
    func randomEventsSurviveEncodingThenDecoding() {
        var generator = XorShiftGenerator(seed: 0x1_0001)
        for _ in 0..<2000 {
            let event = InputEvent(
                type: .random(in: 0...UInt16.max, using: &generator), code: .random(in: 0...UInt16.max, using: &generator),
                value: .random(in: Int32.min...Int32.max, using: &generator))
            #expect(InputEvent(bytes: event.bytes) == event)
        }
    }

    @Test(arguments: [0, 1, 4, 7, 9, 16, 4096])
    func onlyEightBytesAreAnEvent(count: Int) {
        #expect(InputEvent(bytes: Array(repeating: 0xAB, count: count)) == nil)
    }

    @Test
    func aKeyIsOneEventAndAReport() {
        #expect(InputEvents.key(30, .press) == [InputEvent(type: 1, code: 30, value: 1), Self.report])
        #expect(InputEvents.key(30, .release) == [InputEvent(type: 1, code: 30, value: 0), Self.report])
        #expect(InputEvents.key(464, .autorepeat) == [InputEvent(type: 1, code: 464, value: 2), Self.report])
    }

    @Test
    func aButtonIsAKeyEventOfItsCode() {
        #expect(InputEvents.button(.left, pressed: true) == [InputEvent(type: 1, code: 0x110, value: 1), Self.report])
        #expect(InputEvents.button(.right, pressed: false) == [InputEvent(type: 1, code: 0x111, value: 0), Self.report])
        #expect(InputEvents.button(.middle, pressed: true) == [InputEvent(type: 1, code: 0x112, value: 1), Self.report])
    }

    @Test
    func theWheelIsOneRelativeEventAndNothingForZero() {
        #expect(InputEvents.scroll(notches: 3) == [InputEvent(type: 2, code: 8, value: 3), Self.report])
        #expect(InputEvents.scroll(notches: -1) == [InputEvent(type: 2, code: 8, value: -1), Self.report])
        #expect(InputEvents.scroll(notches: 0).isEmpty)
    }

    struct Point: Sendable {
        let x: Double
        let y: Double
        let expectedX: Int32
        let expectedY: Int32
    }

    /// A 1000 × 500 view onto the range 259...16384 (the tablet's), the top left corner of the view being the guest's (0, 0).
    static let points = [
        Point(x: 0, y: 0, expectedX: 259, expectedY: 259),
        Point(x: 1000, y: 500, expectedX: 16384, expectedY: 16384),
        Point(x: 1000, y: 0, expectedX: 16384, expectedY: 259),
        Point(x: 0, y: 500, expectedX: 259, expectedY: 16384),
        Point(x: 500, y: 250, expectedX: 8322, expectedY: 8322),
        Point(x: -5, y: -1e300, expectedX: 259, expectedY: 259),
        Point(x: 2000, y: 1e300, expectedX: 16384, expectedY: 16384),
        Point(x: .nan, y: .nan, expectedX: 259, expectedY: 259),
        Point(x: .infinity, y: -.infinity, expectedX: 16384, expectedY: 259),
        Point(x: -.infinity, y: .infinity, expectedX: 259, expectedY: 16384),
    ]

    @Test(arguments: points)
    func aPointInTheViewIsScaledToTheRangeFromTheTopLeft(point: Point) {
        let events = InputEvents.pointer(x: point.x, y: point.y, viewWidth: 1000, viewHeight: 500, range: 259...16384)
        #expect(
            events == [
                InputEvent(type: 3, code: 0, value: point.expectedX), InputEvent(type: 3, code: 1, value: point.expectedY), Self.report,
            ])
    }

    @Test(arguments: [0, -1, -1e300, .nan, .infinity, -.infinity] as [Double])
    func aViewWithoutAPositiveExtentPutsThePointerAtTheStartOfTheRange(extent: Double) {
        let events = InputEvents.pointer(x: 10, y: 10, viewWidth: extent, viewHeight: extent, range: 259...16384)
        #expect(events.map(\.value) == [259, 259, 0])
    }

    @Test
    func anyDoubleLandsInsideAnyRange() {
        var generator = XorShiftGenerator(seed: 0x1_0002)
        for _ in 0..<20_000 {
            let bounds = (
                Int32.random(in: Int32.min...Int32.max, using: &generator), Int32.random(in: Int32.min...Int32.max, using: &generator)
            )
            let range = min(bounds.0, bounds.1)...max(bounds.0, bounds.1)
            let numbers = (0..<4).map { _ in Double(bitPattern: generator.next()) }
            let events = InputEvents.pointer(x: numbers[0], y: numbers[1], viewWidth: numbers[2], viewHeight: numbers[3], range: range)
            #expect(events.count == 3 && events.last == Self.report)
            #expect(events.dropLast().allSatisfy { range.contains($0.value) && $0.type == InputEventType.abs })
        }
    }
}
