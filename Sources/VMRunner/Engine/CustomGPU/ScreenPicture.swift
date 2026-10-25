import CoreGraphics
import Foundation
import VirtioGPU

/// A picture of the guest's display, or of its cursor, as a `CGImage`. The image reads the guest's bytes where they are: the
/// bitmap description says where red, green, blue and the padding or alpha byte sit for each of the library's pixel formats, so
/// making one costs a copy of the bytes into the image's data and no pass over the pixels.
enum ScreenPicture {
    /// How the four bytes of a pixel, in memory order, map to a 32-bit word of color channels.
    private static func bitmapInfo(_ format: GPUPixelFormat, alpha: Bool) -> CGBitmapInfo {
        let order: CGBitmapInfo
        let alphaFirst: Bool
        let hasAlpha: Bool
        switch format {
        case .b8g8r8a8, .b8g8r8x8: (order, alphaFirst, hasAlpha) = (.byteOrder32Little, true, format == .b8g8r8a8)
        case .a8r8g8b8, .x8r8g8b8: (order, alphaFirst, hasAlpha) = (.byteOrder32Big, true, format == .a8r8g8b8)
        case .r8g8b8a8, .r8g8b8x8: (order, alphaFirst, hasAlpha) = (.byteOrder32Big, false, format == .r8g8b8a8)
        case .a8b8g8r8, .x8b8g8r8: (order, alphaFirst, hasAlpha) = (.byteOrder32Little, false, format == .a8b8g8r8)
        }
        let info: CGImageAlphaInfo
        switch (alpha && hasAlpha, alphaFirst) {
        case (true, true): info = .premultipliedFirst
        case (true, false): info = .premultipliedLast
        case (false, true): info = .noneSkipFirst
        case (false, false): info = .noneSkipLast
        }
        return order.union(CGBitmapInfo(rawValue: info.rawValue))
    }

    /// The image of `update` in the sRGB space, or `nil` for an empty picture or one whose bytes are not `width × height × 4`.
    /// A scanout has no meaningful alpha, so its fourth byte is skipped; a cursor (`alpha: true`) in a format that has an alpha
    /// byte is drawn with it, read as premultiplied, which is how the Linux display driver writes a cursor.
    static func cgImage(_ update: ScanoutUpdate, alpha: Bool = false) -> CGImage? {
        let (width, height) = (Int(update.width), Int(update.height))
        let rowBytes = width * GPUPixelFormat.bytesPerPixel
        guard width > 0, height > 0, update.pixels.count == rowBytes * height,
            let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(update.pixels) as CFData)
        else { return nil }
        let info = bitmapInfo(update.format, alpha: alpha)
        // Unsafe only through the type of `decode`, which is nil here: no pointer is passed.
        return unsafe CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
            bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
