import Foundation

/// What a start needs again if it falls back to a cold boot, and what the rest of the run needs from it.
struct MachineLaunch {
    var config: VMConfig
    let bundle: VMBundle
    weak var library: (any MachineStore)?
    var display: StartDisplay.Decision
    let windowSize: CGSize?
    let suspendAllowed: Bool
    /// The address the machine keeps: the one it had when the run started, or nil when it had none.
    let storedMACAddress: String?
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
        library?.update(config.persistable(storedMACAddress: storedMACAddress))
    }
}

extension VMConfig {
    /// The config a start stores. A disposable machine with a fresh identity boots with a new address for that run only, so
    /// the stored address is put back before the config is saved.
    func persistable(storedMACAddress: String?) -> VMConfig {
        guard ephemeral, freshIdentityPerStart else { return self }
        var stored = self
        stored.macAddress = storedMACAddress
        return stored
    }
}
