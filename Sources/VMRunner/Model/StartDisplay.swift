import Foundation

/// The framebuffer a guest's display starts with: the one number the firmware sees.
///
/// UEFI and GRUB draw fixed-size glyphs, so the size they start on decides whether their text can be read. Everything
/// that decides it is here, as a pure function, so tests can call it with realistic windows and settings.
enum StartDisplay {
    /// Widest framebuffer a Linux guest is started with. A framebuffer that matches a large window pixel for pixel makes
    /// firmware and boot loader text tiny; a capped one with the window's aspect ratio is scaled up by the view instead.
    /// Once Linux runs, the display follows the window.
    static let legibleWidth = 1280

    /// Smallest window, in points, that is trusted to be a real layout rather than a pane that has not been laid out yet.
    private static let usableWindow = CGSize(width: 320, height: 200)

    /// Where a start size came from.
    enum Source: String, Equatable {
        /// The size remembered from the cold boot that the saved state was taken on.
        case savedState = "saved state"
        /// The window, at `displayScale` pixels per point.
        case window
        /// The configured size, because "Match window" is off.
        case fixedSize = "fixed size"
        /// The configured size, because there is no usable window yet.
        case configuredSizeWithoutWindow = "configured size, no usable window"
    }

    /// What the width cap did to a start size.
    enum Cap: String, Equatable {
        /// The guest is not capped: macOS, a saved state, or a fixed size the guest keeps for the whole run.
        case notApplicable = "does not apply"
        /// The cap is in force and the size was already within it.
        case withinCap = "in force, not needed"
        /// The cap is in force and reduced the size.
        case reduced = "applied"
    }

    /// A start size and the rule that decided it, for the log. Words and numbers only.
    struct Decision: Equatable {
        var width: Int
        var height: Int
        var source: Source
        var cap: Cap
        /// A remembered size exists and was not used, because this is a cold start.
        var rememberedSizeIgnored: Bool

        var size: (width: Int, height: Int) { (width, height) }

        /// The rule in words, for the log: `source window, width cap applied, remembered size ignored`.
        var rule: String {
            let remembered = source == .savedState ? "used" : (rememberedSizeIgnored ? "ignored" : "none")
            return "source \(source.rawValue), width cap \(cap.rawValue), remembered size \(remembered)"
        }
    }

    /// Framebuffer size in pixels for this boot.
    ///
    /// - A restored machine keeps the size it was suspended with, because saved state only restores into an identical
    ///   configuration. This is the one case where the cap does not apply: the firmware has already run, and the remembered
    ///   size is the start size of the run that was saved (never a size the guest later followed the window to).
    /// - Otherwise the size comes from the window (`fitsWindowAtStart`, at `displayScale` pixels per point) or from the fixed
    ///   size, and a Linux guest's width is capped at `legibleWidth` with the aspect ratio kept and both sides even.
    ///   The remembered size plays no part, whatever it is.
    /// - The one exception is a fixed size that the user chose together with switching "resize with window" off: that size is
    ///   what the guest keeps for the whole run, so it is not replaced by a smaller one.
    ///
    /// macOS follows its configured density and is never capped.
    static func size(for config: VMConfig, window: CGSize?, restoring: Bool) -> (width: Int, height: Int) {
        decide(for: config, window: window, restoring: restoring).size
    }

    /// `size(for:window:restoring:)` with the rule that decided it.
    static func decide(for config: VMConfig, window: CGSize?, restoring: Bool) -> Decision {
        let remembered = config.lastDisplayWidth != nil && config.lastDisplayHeight != nil
        if restoring, let width = config.lastDisplayWidth, let height = config.lastDisplayHeight {
            return Decision(width: width, height: height, source: .savedState, cap: .notApplicable, rememberedSizeIgnored: false)
        }
        let capped = config.guest == .linux && (config.fitsWindowAtStart || config.automaticallyReconfiguresDisplay)
        func decision(_ size: (width: Int, height: Int), _ source: Source, requested: Double) -> Decision {
            let cap: Cap = !capped ? .notApplicable : (requested > Double(legibleWidth) ? .reduced : .withinCap)
            return Decision(width: size.width, height: size.height, source: source, cap: cap, rememberedSizeIgnored: remembered)
        }
        if config.fitsWindowAtStart, let window, window.width >= usableWindow.width, window.height >= usableWindow.height {
            let width = window.width * config.displayScale
            let size = fitted(width, window.height * config.displayScale, capped: capped)
            return decision(size, .window, requested: width)
        }
        let source: Source = config.fitsWindowAtStart ? .configuredSizeWithoutWindow : .fixedSize
        if capped, config.displayWidth > legibleWidth {
            let size = fitted(Double(config.displayWidth), Double(config.displayHeight), capped: true)
            return decision(size, source, requested: Double(config.displayWidth))
        }
        return decision((config.displayWidth, config.displayHeight), source, requested: Double(config.displayWidth))
    }

    private static func fitted(_ width: Double, _ height: Double, capped: Bool) -> (width: Int, height: Int) {
        var width = width
        var height = height
        if capped, width > Double(legibleWidth) {
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
