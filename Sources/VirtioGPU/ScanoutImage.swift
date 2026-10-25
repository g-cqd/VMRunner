/// The scanout's pixels as the host shows them: four bytes per pixel, red, green, blue, then a padding byte of 255, rows
/// packed. A scanout has no meaningful alpha, so the guest's alpha or padding byte is never shown.
package enum ScanoutImage {
    /// Where red, green and blue sit in one pixel, counted in bytes from its first.
    package struct ChannelOffsets: Equatable, Sendable {
        package let red: Int
        package let green: Int
        package let blue: Int
    }

    /// Where red, green and blue sit in one pixel of `format`. A virtio format names its bytes in memory order:
    /// `b8g8r8x8` is blue, green, red, padding.
    package static func channelOffsets(_ format: GPUPixelFormat) -> ChannelOffsets {
        switch format {
        case .b8g8r8a8, .b8g8r8x8: ChannelOffsets(red: 2, green: 1, blue: 0)
        case .a8r8g8b8, .x8r8g8b8: ChannelOffsets(red: 1, green: 2, blue: 3)
        case .r8g8b8a8, .r8g8b8x8: ChannelOffsets(red: 0, green: 1, blue: 2)
        case .a8b8g8r8, .x8b8g8r8: ChannelOffsets(red: 3, green: 2, blue: 1)
        }
    }

    /// `update`'s pixels in red, green, blue, padding order. The store guarantees `width × height × 4` bytes; anything shorter
    /// gives no image rather than a partial one.
    package static func rgbx(_ update: ScanoutUpdate) -> [UInt8]? {
        let count = Int(update.width) * Int(update.height) * GPUPixelFormat.bytesPerPixel
        guard update.pixels.count == count else { return nil }
        let offsets = channelOffsets(update.format)
        var out = [UInt8](repeating: 255, count: count)
        var index = 0
        while index < count {
            out[index] = update.pixels[index + offsets.red]
            out[index + 1] = update.pixels[index + offsets.green]
            out[index + 2] = update.pixels[index + offsets.blue]
            index += GPUPixelFormat.bytesPerPixel
        }
        return out
    }
}

/// Shows at most one frame per `interval` milliseconds: a frame offered sooner is kept and shown by a later tick, and the
/// last one kept is handed out at the end, so the newest picture is never lost and the host's work stays bounded.
package struct FrameThrottle: Sendable {
    package let interval: UInt64
    private var lastShownAt: UInt64?
    private var pending: ScanoutUpdate?

    package init(intervalMilliseconds: UInt64) {
        interval = intervalMilliseconds
    }

    /// The frame to show now, or `nil` when it was kept for later.
    package mutating func offer(_ update: ScanoutUpdate, atMilliseconds now: UInt64) -> ScanoutUpdate? {
        pending = update
        return tick(atMilliseconds: now)
    }

    /// The kept frame, when the interval since the last one shown has passed.
    package mutating func tick(atMilliseconds now: UInt64) -> ScanoutUpdate? {
        guard let frame = pending else { return nil }
        if let last = lastShownAt, now < last + interval { return nil }
        lastShownAt = now
        pending = nil
        return frame
    }

    /// The kept frame, whatever the time: at the end of the run.
    package mutating func drain() -> ScanoutUpdate? {
        defer { pending = nil }
        return pending
    }
}
