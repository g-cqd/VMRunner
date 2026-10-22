import Foundation

/// The framebuffer a guest's display starts with: the one number the firmware sees.
///
/// UEFI and GRUB draw fixed-size glyphs, so the size they start on decides whether their text can be read. Everything
/// that decides it is here, as a pure function, so tests can call it with realistic windows and settings.
enum StartDisplay {
    /// Widest framebuffer a Linux guest is started with. UEFI and GRUB draw fixed-size glyphs, so on a large window a
    /// framebuffer that matches it pixel for pixel makes their text tiny. A capped one with the window's aspect ratio is
    /// scaled up by the view instead; the guest OS then follows the window.
    static let legibleWidth = 1280

    /// Framebuffer size in pixels for this boot.
    ///
    /// With `fitsWindowAtStart` the guest gets the window's aspect ratio at `displayScale` pixels per point, capped for
    /// Linux at `legibleWidth` so firmware text stays readable. A suspended machine keeps the size it was suspended with,
    /// because saved state only restores into an identical configuration.
    static func size(for config: VMConfig, window: CGSize?, restoring: Bool) -> (width: Int, height: Int) {
        if restoring, let width = config.lastDisplayWidth, let height = config.lastDisplayHeight { return (width, height) }
        guard config.fitsWindowAtStart, let window, window.width >= 320, window.height >= 200 else {
            return (config.displayWidth, config.displayHeight)
        }
        var width = window.width * config.displayScale
        var height = window.height * config.displayScale
        if config.guest == .linux, width > Double(legibleWidth) {
            height *= Double(legibleWidth) / width
            width = Double(legibleWidth)
        }
        return (even(width, EditorLimits.displayWidth), even(height, EditorLimits.displayHeight))
    }

    /// Clamp as a Double first: `Int(value)` traps for a value that is NaN or past `Int.max`.
    private static func even(_ value: Double, _ range: ClosedRange<Int>) -> Int {
        let bounded = min(max(value.isNaN ? 0 : value, Double(range.lowerBound)), Double(range.upperBound))
        return min(max(Int(bounded) & ~1, range.lowerBound), range.upperBound)
    }
}
