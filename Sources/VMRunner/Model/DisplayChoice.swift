/// What the "Resolution" picker selects. It is derived from, and writes back to, the machine's settings, so the
/// rules live in one testable place instead of in the view.
enum DisplayChoice: Hashable {
    /// Size the guest display to the window when the machine starts.
    case matchWindow
    /// A fixed pixel size from `DisplayPreset.all`.
    case preset(DisplayPreset)
    /// A fixed pixel size typed in by the user.
    case custom
}

extension VMConfig {
    var displayChoice: DisplayChoice {
        get {
            if fitsWindowAtStart { return .matchWindow }
            if usesCustomDisplaySize { return .custom }
            let match = DisplayPreset.all.first { $0.width == displayWidth && $0.height == displayHeight }
            return match.map(DisplayChoice.preset) ?? .custom
        }
        set {
            fitsWindowAtStart = newValue == .matchWindow
            usesCustomDisplaySize = newValue == .custom
            if case .preset(let preset) = newValue {
                displayWidth = preset.width
                displayHeight = preset.height
            }
        }
    }
}
