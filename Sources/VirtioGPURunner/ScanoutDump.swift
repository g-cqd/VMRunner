import Foundation
import ImageIO
import UniformTypeIdentifiers
import VirtioGPU

/// Writes the newest scanout picture to `scanout.png` in the scratch directory, at most once a second and once at the end,
/// so a run can be checked without a window. Each write goes to a temporary file created with mode 0600 (`PrivateFile`) that is
/// then renamed over the last one, so a reader never sees half a file and the file is never readable by others.
@MainActor
final class ScanoutDump: ScanoutSink {
    private let path: String
    private var throttle = FrameThrottle(intervalMilliseconds: 1000)
    private var written = 0
    private let log: (String) -> Void

    init(path: String, log: @escaping (String) -> Void) {
        self.path = path
        self.log = log
    }

    func show(_ update: ScanoutUpdate, atMilliseconds now: UInt64) {
        if let frame = throttle.offer(update, atMilliseconds: now) { write(frame) }
    }

    func tick(atMilliseconds now: UInt64) {
        if let frame = throttle.tick(atMilliseconds: now) { write(frame) }
    }

    func finish() {
        if let frame = throttle.drain() { write(frame) }
        log("scanout pictures written: \(written)")
    }

    private func write(_ update: ScanoutUpdate) {
        guard let image = ScanoutPicture.cgImage(update), let png = Self.png(of: image) else {
            log("could not make a picture of the \(update.width) x \(update.height) scanout")
            return
        }
        do {
            try PrivateFile.replace(path, with: png)
        } catch {
            log("could not put \(path) in place: \(error.localizedDescription)")
            return
        }
        written += 1
        if written == 1 { log("first scanout picture written to \(path): \(update.width) x \(update.height)") }
    }

    /// The picture as PNG bytes, encoded in memory so that the only file the runner makes for it is the private one.
    private static func png(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
