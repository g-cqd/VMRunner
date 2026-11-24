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
        /// The guest's default size, because the stored size is not a size a screen can have.
        case defaultSize = "default size, stored size invalid"
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
    ///
    /// A stored size (the fixed size, or the remembered one) that is outside what the editor offers is not a screen: zero, a
    /// negative number, a few pixels or an absurd number comes from a damaged or hand-edited configuration. It is not used; the
    /// start falls back to the window, and without a usable window to the guest's default size.
    static func decide(for config: VMConfig, window: CGSize?, restoring: Bool) -> Decision {
        // The Windows bootstrap advertises one tested mode. Never resize the underlying GOP behind its RAM mapping.
        if config.guest == .windows {
            return Decision(
                width: 1920, height: 1200, source: .fixedSize, cap: .notApplicable,
                rememberedSizeIgnored: config.lastDisplayWidth != nil || config.lastDisplayHeight != nil)
        }
        var remembered: (width: Int, height: Int)?
        if let width = config.lastDisplayWidth, let height = config.lastDisplayHeight, isValid(width: width, height: height) {
            remembered = (width, height)
        }
        if restoring, let remembered {
            return Decision(
                width: remembered.width, height: remembered.height, source: .savedState, cap: .notApplicable,
                rememberedSizeIgnored: false)
        }
        let configuredIsValid = isValid(width: config.displayWidth, height: config.displayHeight)
        let capped = config.guest == .linux && (config.fitsWindowAtStart || config.automaticallyReconfiguresDisplay || !configuredIsValid)
        func decision(_ size: (width: Int, height: Int), _ source: Source, requested: Double) -> Decision {
            let cap: Cap = !capped ? .notApplicable : (requested > Double(legibleWidth) ? .reduced : .withinCap)
            return Decision(width: size.width, height: size.height, source: source, cap: cap, rememberedSizeIgnored: remembered != nil)
        }
        if config.fitsWindowAtStart || !configuredIsValid, let window, window.width >= usableWindow.width,
            window.height >= usableWindow.height
        {
            let width = window.width * config.displayScale
            let size = fitted(width, window.height * config.displayScale, capped: capped)
            return decision(size, .window, requested: width)
        }
        let source: Source = !configuredIsValid ? .defaultSize : (config.fitsWindowAtStart ? .configuredSizeWithoutWindow : .fixedSize)
        let width = configuredIsValid ? config.displayWidth : defaultSize(for: config.guest).width
        let height = configuredIsValid ? config.displayHeight : defaultSize(for: config.guest).height
        if capped, width > legibleWidth {
            return decision(fitted(Double(width), Double(height), capped: true), source, requested: Double(width))
        }
        return decision((width, height), source, requested: Double(width))
    }

    private static func isValid(width: Int, height: Int) -> Bool {
        EditorLimits.displayWidth.contains(width) && EditorLimits.displayHeight.contains(height)
    }

    /// What `VMConfig.new` gives a guest.
    private static func defaultSize(for guest: GuestOS) -> (width: Int, height: Int) {
        switch guest {
        case .macOS, .windows: (1920, 1200)
        case .linux: (1280, 800)
        }
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
