import os

/// Logs each kind of trouble the first time it happens and never again, so that a guest cannot make the log grow.
struct TroubleLog<Trouble: Hashable> {
    private let logger: Logger
    private var seen: Set<Trouble> = []

    init(_ logger: Logger) {
        self.logger = logger
    }

    mutating func notice(_ trouble: Trouble, _ message: String) {
        guard seen.insert(trouble).inserted else { return }
        logger.notice("\(message, privacy: .public)")
    }
}
