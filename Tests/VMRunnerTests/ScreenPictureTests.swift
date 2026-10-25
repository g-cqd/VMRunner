import CoreGraphics
import Foundation
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// A guest's pixels as an image: every format the device accepts must come out with the colors the guest wrote.
struct ScreenPictureTests {
    /// Two pixels, one colored (10, 20, 30) and one (200, 100, 50), their fourth byte `fourth`, in the byte order of `format`.
    private func picture(_ format: GPUPixelFormat, fourth: UInt8) -> ScanoutUpdate {
        let offsets = ScanoutImage.channelOffsets(format)
        var pixels = [UInt8](repeating: fourth, count: 8)
        for (index, color) in [[10, 20, 30], [200, 100, 50]].enumerated() {
            pixels[index * 4 + offsets.red] = UInt8(color[0])
            pixels[index * 4 + offsets.green] = UInt8(color[1])
            pixels[index * 4 + offsets.blue] = UInt8(color[2])
        }
        return ScanoutUpdate(width: 2, height: 1, format: format, pixels: pixels)
    }

    /// The red, green, blue and alpha bytes of the pixel at `x` when `image` is drawn into an sRGB bitmap with premultiplied alpha
    /// (the image is read by drawing, as the screen does; the bitmap is the framework's, so no pointer is needed).
    private func channels(of image: CGImage, at x: Int) throws -> [Int] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // Unsafe only through the type of `data`, which is nil here: the framework allocates the bitmap.
        let context = unsafe CGContext(
            data: nil, width: image.width, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        try #require(context != nil)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
        let bytes = try #require(context?.makeImage()?.dataProvider?.data as Data?)
        return bytes[(bytes.startIndex + x * 4)..<(bytes.startIndex + x * 4 + 4)].map { Int($0) }
    }

    @Test(arguments: GPUPixelFormat.allCases, [0, 128, 255] as [UInt8])
    func aScanoutKeepsTheGuestsColorsWhateverItsFormatAndFourthByte(format: GPUPixelFormat, fourth: UInt8) throws {
        let image = try #require(ScreenPicture.cgImage(picture(format, fourth: fourth)))
        #expect(image.width == 2 && image.height == 1)
        #expect(try channels(of: image, at: 0) == [10, 20, 30, 255], "\(format), fourth byte \(fourth)")
        #expect(try channels(of: image, at: 1) == [200, 100, 50, 255], "\(format), fourth byte \(fourth)")
    }

    @Test(arguments: [GPUPixelFormat.b8g8r8a8, .a8r8g8b8, .r8g8b8a8, .a8b8g8r8])
    func aCursorInAFormatWithAlphaIsDrawnWithItAsPremultiplied(format: GPUPixelFormat) throws {
        // Half transparent red, premultiplied: red 64 at alpha 128.
        let offsets = ScanoutImage.channelOffsets(format)
        var pixels = [UInt8](repeating: 0, count: 4)
        pixels[offsets.red] = 64
        let alphaIndex = (0..<4).first { $0 != offsets.red && $0 != offsets.green && $0 != offsets.blue } ?? 0
        pixels[alphaIndex] = 128
        let update = ScanoutUpdate(width: 1, height: 1, format: format, pixels: pixels)

        let cursor = try channels(of: try #require(ScreenPicture.cgImage(update, alpha: true)), at: 0)
        #expect(abs(cursor[3] - 128) <= 1 && abs(cursor[0] - 64) <= 1 && cursor[1] == 0 && cursor[2] == 0, "\(format): \(cursor)")
        let opaque = try channels(of: try #require(ScreenPicture.cgImage(update)), at: 0)
        #expect(opaque == [64, 0, 0, 255], "a scanout ignores the alpha byte: \(format)")
    }

    @Test(arguments: [GPUPixelFormat.b8g8r8x8, .x8r8g8b8, .r8g8b8x8, .x8b8g8r8])
    func aCursorInAFormatWithoutAlphaIsOpaque(format: GPUPixelFormat) throws {
        let image = try #require(ScreenPicture.cgImage(picture(format, fourth: 0), alpha: true))
        #expect(try channels(of: image, at: 0) == [10, 20, 30, 255], "\(format)")
    }

    @Test
    func anEmptyPictureOrOneWithTheWrongNumberOfBytesGivesNoImage() {
        struct Case {
            let width: UInt32
            let height: UInt32
            let bytes: Int
        }
        let cases =
            [Case(width: 0, height: 4, bytes: 0), Case(width: 4, height: 0, bytes: 0)]
            + [0, 15, 17].map {
                Case(width: 2, height: 2, bytes: $0)
            }
        for item in cases {
            let pixels = [UInt8](repeating: 0, count: item.bytes)
            let update = ScanoutUpdate(width: item.width, height: item.height, format: .b8g8r8x8, pixels: pixels)
            #expect(ScreenPicture.cgImage(update) == nil, "\(item.width) x \(item.height) with \(item.bytes) bytes")
        }
    }
}
