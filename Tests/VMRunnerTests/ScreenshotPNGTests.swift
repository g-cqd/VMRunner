import ControlProtocol
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// The guest's pixels as the PNG an agent reads: its colors, its size, and a length the control service can always answer.
struct ScreenshotPNGTests {
    private struct Color {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// A frame of `width` × `height` pixels, each one `color(x, y)`, in the order of `.b8g8r8x8`.
    private func frame(_ width: Int, _ height: Int, color: (Int, Int) -> Color) -> ScanoutUpdate {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let shade = color(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = shade.blue
                pixels[offset + 1] = shade.green
                pixels[offset + 2] = shade.red
            }
        }
        return ScanoutUpdate(width: UInt32(width), height: UInt32(height), format: .b8g8r8x8, pixels: pixels)
    }

    /// A frame of bytes that do not compress, from a fixed seed, so every run encodes the same picture.
    private func noise(_ width: Int, _ height: Int) -> ScanoutUpdate {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let pixels = (0..<(width * height * 4)).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        return ScanoutUpdate(width: UInt32(width), height: UInt32(height), format: .b8g8r8x8, pixels: pixels)
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The red, green and blue of the pixel at `x`, `y`, read by drawing the image into an sRGB bitmap.
    private func channels(of image: CGImage, x: Int, y: Int) throws -> [Int] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // Unsafe only through the type of `data`, which is nil here: the framework allocates the bitmap.
        let context = try #require(
            unsafe CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let drawn = try #require(context.makeImage())
        let bytes = try #require(drawn.dataProvider?.data as Data?)
        let rowBytes = drawn.bytesPerRow
        let offset = bytes.startIndex + y * rowBytes + x * 4
        return bytes[offset..<(offset + 3)].map { Int($0) }
    }

    @Test
    func aSmallFrameRoundTripsThroughAPNGWithItsColorsAndItsSize() throws {
        let colors: [[UInt8]] = [[10, 20, 30], [200, 100, 50], [0, 255, 0], [255, 0, 255]]
        let source = frame(2, 2) { x, y in
            let color = colors[y * 2 + x]
            return Color(red: color[0], green: color[1], blue: color[2])
        }
        let picture = try #require(ScreenshotPNG.picture(of: source))
        #expect(picture.width == 2 && picture.height == 2)
        #expect(Array(picture.data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG signature")
        let image = try decode(picture.data)
        #expect(image.width == 2 && image.height == 2)
        for (index, color) in colors.enumerated() {
            #expect(try channels(of: image, x: index % 2, y: index / 2) == color.map { Int($0) }, "pixel \(index)")
        }
    }

    @Test(arguments: [
        (1920, 1200, 1280, 800), (3840, 2160, 1280, 720), (800, 1600, 640, 1280), (1280, 800, 1280, 800), (640, 480, 640, 480),
    ])
    func aLargeFrameIsScaledToAtMost1280OnItsLongestSideAndASmallOneIsLeftAlone(
        width: Int, height: Int, expectedWidth: Int, expectedHeight: Int
    ) throws {
        let picture = try #require(
            ScreenshotPNG.picture(of: frame(width, height) { x, y in Color(red: UInt8(x % 251), green: UInt8(y % 241), blue: 7) }))
        #expect(picture.width == expectedWidth && picture.height == expectedHeight, "\(picture.width) x \(picture.height)")
        let image = try decode(picture.data)
        #expect(image.width == expectedWidth && image.height == expectedHeight)
    }

    @Test
    func aFrameThatDoesNotCompressIsMadeSmallerUntilItsPNGFits() throws {
        let source = noise(1280, 800)
        let picture = try #require(ScreenshotPNG.picture(of: source))
        #expect(picture.data.count <= ControlScreenshot.maximumBytes)
        #expect(picture.width < 1280, "noise at 1280 x 800 is about 3 MB as a PNG, so a smaller step was used")
        #expect(abs(Double(picture.width) / Double(picture.height) - 1.6) < 0.02, "the proportions are kept")
    }

    @Test
    func theWorstCaseFrameStillGivesAnAnswerLineUnderTheClientsLimit() throws {
        // The most pixels the bound allows (a square at the longest side) with no repetition in them.
        let picture = try #require(ScreenshotPNG.picture(of: noise(1280, 1280)))
        #expect(picture.data.count <= ControlScreenshot.maximumBytes)
        let shot = ControlScreenshot(id: UUID(), width: picture.width, height: picture.height, png: picture.data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(shot)
        #expect(line.count < ControlClient.defaultAnswerBytes)
        // The smallest step is 320 pixels on the longest side: 320 x 320 x 4 bytes of pixels, even stored uncompressed, fit.
        #expect(320 * 320 * 4 + 4_096 <= ControlScreenshot.maximumBytes)
    }

    @Test
    func anEmptyFrameOrOneWithTheWrongNumberOfBytesGivesNoPicture() {
        #expect(ScreenshotPNG.picture(of: ScanoutUpdate(width: 0, height: 0, format: .b8g8r8x8, pixels: [])) == nil)
        #expect(ScreenshotPNG.picture(of: ScanoutUpdate(width: 2, height: 2, format: .b8g8r8x8, pixels: [0, 0, 0])) == nil)
    }

    @Test
    func aBudgetNothingFitsInGivesNoPictureRatherThanATooLongOne() {
        #expect(ScreenshotPNG.picture(of: noise(64, 64), maximumBytes: 100) == nil)
    }
}
