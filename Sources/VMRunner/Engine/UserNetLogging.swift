import NetStack
import os

/// The app's logger for the user-mode network stack: lines go to the `network` category, destinations redacted.
struct AppUserNetLogger: UserNetLogger {
    func stackStarting(mtu: Int) {
        Log.network.info("user-mode network starting, mtu \(mtu, privacy: .public)")
    }

    func flowFailed(summary: String, held: Int, destination: String) {
        if held > 0 {
            Log.network.info("\(summary, privacy: .public) +\(held, privacy: .public): \(destination, privacy: .private)")
        } else {
            Log.network.info("\(summary, privacy: .public): \(destination, privacy: .private)")
        }
    }
}
