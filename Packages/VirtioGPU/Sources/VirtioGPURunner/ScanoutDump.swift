import Foundation
import ImageIO
import UniformTypeIdentifiers
import VirtioGPURunnerCore

/// Writes the newest scanout picture to `scanout.png` in the scratch directory, at most once a second and once at the end,
/// so a run can be checked without a window. Each write goes to a private temporary file that is then renamed over the
/// last one, so a reader never sees half a file.
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
        let temporary = path + ".partial"
        guard let image = ScanoutPicture.cgImage(update),
            let destination = CGImageDestinationCreateWithURL(
                URL(filePath: temporary) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            log("could not make a picture of the \(update.width) x \(update.height) scanout")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            log("could not write \(temporary)")
            return
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(filePath: path), withItemAt: URL(filePath: temporary))
            } else {
                try FileManager.default.moveItem(atPath: temporary, toPath: path)
            }
        } catch {
            log("could not put \(path) in place: \(error.localizedDescription)")
            return
        }
        written += 1
        if written == 1 { log("first scanout picture written to \(path): \(update.width) x \(update.height)") }
    }
}
