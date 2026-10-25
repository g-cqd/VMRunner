import ControlProtocol
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VirtioGPU

/// A PNG of the guest's screen for the control service. The longest side is at most `longestSide`; a picture whose PNG is
/// still longer than `maximumBytes` (noise does not compress) is made smaller in steps, so the answer always fits the longest
/// line a client accepts. The last step is 320 pixels on its longest side: at most 320 × 320 × 4 bytes of pixels, about 410 KB
/// as a PNG at worst, under the default `maximumBytes`.
enum ScreenshotPNG {
    /// A PNG and its size in pixels.
    struct Picture: Equatable {
        let width: Int
        let height: Int
        let data: Data
    }

    static let longestSide = 1280
    private static let steps = [1.0, 0.75, 0.5, 0.375, 0.25]

    /// The PNG of `frame`, or `nil` for a picture `ScreenPicture` cannot make an image of or one that cannot be encoded.
    static func picture(
        of frame: ScanoutUpdate, longestSide: Int = Self.longestSide, maximumBytes: Int = ControlScreenshot.maximumBytes
    ) -> Picture? {
        guard let image = ScreenPicture.cgImage(frame) else { return nil }
        for step in steps {
            let side = max(Int((Double(longestSide) * step).rounded()), 1)
            guard let scaled = scaled(image, longestSide: side), let data = png(scaled), data.count <= maximumBytes else { continue }
            return Picture(width: scaled.width, height: scaled.height, data: data)
        }
        return nil
    }

    /// `image` itself when its longest side is at most `side`, otherwise a copy drawn at that size with its proportions.
    private static func scaled(_ image: CGImage, longestSide side: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > side else { return image }
        let factor = Double(side) / Double(longest)
        let width = max(Int((Double(image.width) * factor).rounded()), 1)
        let height = max(Int((Double(image.height) * factor).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Unsafe only through the type of `data`, which is nil here: the framework allocates the bitmap.
        let context = unsafe CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
