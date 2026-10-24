import CoreGraphics
import Foundation
import VirtioGPURunnerCore

/// Where the scanout's pictures go: the runner's window, the PNG file, or both.
@MainActor
protocol ScanoutSink: AnyObject {
    /// A new picture of the scanout, from a flush.
    func show(_ update: ScanoutUpdate, atMilliseconds now: UInt64)
    /// Called a few times a second, so a picture kept back by the throttle is shown.
    func tick(atMilliseconds now: UInt64)
    /// The end of the run: the newest picture is shown or written whatever the time.
    func finish()
}

/// The scanout's pixels as a CGImage in the sRGB space, red, green, blue and a padding byte.
enum ScanoutPicture {
    static func cgImage(_ update: ScanoutUpdate) -> CGImage? {
        guard update.width > 0, update.height > 0, let bytes = ScanoutImage.rgbx(update),
            let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        // Unsafe only through the type of `decode`, which is nil here: no pointer is passed.
        return unsafe CGImage(
            width: Int(update.width), height: Int(update.height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(update.width) * GPUPixelFormat.bytesPerPixel, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
