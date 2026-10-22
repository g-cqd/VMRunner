import AppKit
import Foundation
import os

extension StartDisplay.Decision {
    /// Always logged (a notice, so it is kept): the number the firmware sees and the rule that chose it. Sizes, flags and rule
    /// names only.
    func log(config: VMConfig, window: CGSize?, restoring: Bool) {
        let window = window.map(DisplayDiagnostics.text) ?? "unknown size"
        let hostScale = NSScreen.main.map { "\($0.backingScaleFactor)" } ?? "unknown"
        Log.display.notice(
            """
            Starting display \(width)×\(height) px for a window of \(window, privacy: .public) pt; \
            host screen scale \(hostScale, privacy: .public), guest pixels per point \(config.displayScale); \
            \(rule, privacy: .public); match window \(config.fitsWindowAtStart), \
            follows window \(config.automaticallyReconfiguresDisplay), restoring \(restoring)
            """)
    }
}
