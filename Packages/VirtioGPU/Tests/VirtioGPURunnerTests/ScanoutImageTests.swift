import Testing

@testable import VirtioGPURunnerCore

struct ScanoutImageTests {
    /// One pixel whose bytes in memory are 0x10, 0x20, 0x30, 0x40, in each format, as red, green, blue.
    @Test(arguments: [
        (GPUPixelFormat.b8g8r8a8, [0x30, 0x20, 0x10] as [UInt8]),
        (.b8g8r8x8, [0x30, 0x20, 0x10]),
        (.a8r8g8b8, [0x20, 0x30, 0x40]),
        (.x8r8g8b8, [0x20, 0x30, 0x40]),
        (.r8g8b8a8, [0x10, 0x20, 0x30]),
        (.r8g8b8x8, [0x10, 0x20, 0x30]),
        (.a8b8g8r8, [0x40, 0x30, 0x20]),
        (.x8b8g8r8, [0x40, 0x30, 0x20]),
    ])
    func everyFormatGivesRedGreenBlueAndAnOpaquePad(format: GPUPixelFormat, rgb: [UInt8]) {
        let update = ScanoutUpdate(width: 1, height: 1, format: format, pixels: [0x10, 0x20, 0x30, 0x40])
        #expect(ScanoutImage.rgbx(update) == rgb + [255])
    }

    @Test
    func everyPixelOfEveryRowIsConverted() {
        let pixels: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0, 13, 14, 15, 0, 16, 17, 18, 0]
        let update = ScanoutUpdate(width: 3, height: 2, format: .b8g8r8x8, pixels: pixels)
        #expect(
            ScanoutImage.rgbx(update) == [3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255, 15, 14, 13, 255, 18, 17, 16, 255])
    }

    @Test
    func pixelsOfTheWrongLengthGiveNoImage() {
        #expect(ScanoutImage.rgbx(ScanoutUpdate(width: 2, height: 1, format: .r8g8b8x8, pixels: [1, 2, 3, 4])) == nil)
        #expect(ScanoutImage.rgbx(ScanoutUpdate(width: 0, height: 0, format: .r8g8b8x8, pixels: []))?.isEmpty == true)
    }

    private func frame(_ marker: UInt8) -> ScanoutUpdate {
        ScanoutUpdate(width: 1, height: 1, format: .r8g8b8x8, pixels: [marker, 0, 0, 0])
    }

    @Test
    func theThrottleShowsTheFirstFrameAtOnceAndKeepsTheNewestOneUntilTheIntervalPassed() {
        var throttle = FrameThrottle(intervalMilliseconds: 1000)
        #expect(throttle.offer(frame(1), atMilliseconds: 0) == frame(1))
        #expect(throttle.offer(frame(2), atMilliseconds: 400) == nil)
        #expect(throttle.offer(frame(3), atMilliseconds: 800) == nil)
        #expect(throttle.tick(atMilliseconds: 999) == nil)
        #expect(throttle.tick(atMilliseconds: 1000) == frame(3), "the newest kept frame, once the interval passed")
        #expect(throttle.tick(atMilliseconds: 5000) == nil, "nothing is kept any more")
        #expect(throttle.drain() == nil)
    }

    @Test
    func theKeptFrameIsHandedOutAtTheEnd() {
        var throttle = FrameThrottle(intervalMilliseconds: 1000)
        _ = throttle.offer(frame(1), atMilliseconds: 10)
        _ = throttle.offer(frame(2), atMilliseconds: 20)
        #expect(throttle.drain() == frame(2))
        #expect(throttle.drain() == nil)
    }
}
