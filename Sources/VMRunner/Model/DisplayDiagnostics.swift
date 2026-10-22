import CoreGraphics
import Foundation
import os

/// Off-by-default tracing of the display path, for a run on a real guest.
///
/// `open VMRunner.app --args --display-diagnostics` logs each step that decides what the guest screen looks like: the size
/// the guest starts with, every layout of the view, each setting written to the framework's view, each request for a new
/// size and its outcome, and the framework's own begin and end of a reconfiguration. Read it with
/// `log stream --level info --predicate 'category == "display"'`. Sizes and flags only; nothing identifies a machine or a path.
enum DisplayDiagnostics {
    nonisolated static let argument = "--display-diagnostics"

    nonisolated static func isRequested(in arguments: [String]) -> Bool { arguments.contains(argument) }

    nonisolated static let isEnabled = isRequested(in: CommandLine.arguments)

    /// Logs `message` when the launch argument is present; the message is not built otherwise.
    nonisolated static func note(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = message()
        Log.display.notice("\(line, privacy: .public)")
    }

    /// `1800×1100`, for a size in points or pixels.
    nonisolated static func text(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }
}
