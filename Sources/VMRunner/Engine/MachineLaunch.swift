import Foundation

/// What a start needs again if it falls back to a cold boot, and what the rest of the run needs from it.
struct MachineLaunch {
    var config: VMConfig
    let bundle: VMBundle
    weak var library: (any MachineStore)?
    var display: StartDisplay.Decision
    let windowSize: CGSize?
    let suspendAllowed: Bool
    var disposableCopyMade = false

    /// A cold boot that follows a restore which failed or could not happen starts on the display any cold start has. The
    /// remembered size is the start size of the run that was saved, and is right only for restoring it: the firmware of this
    /// boot has not run yet, and the width cap exists for it. The size it starts on is remembered for the next restore.
    @MainActor
    mutating func useColdStartDisplay() {
        guard display.source == .savedState else { return }
        display = StartDisplay.decide(for: config, window: windowSize, restoring: false)
        display.log(config: config, window: windowSize, restoring: false)
        config.lastDisplayWidth = display.width
        config.lastDisplayHeight = display.height
        library?.update(config)
    }
}
