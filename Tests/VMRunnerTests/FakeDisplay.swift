import CoreGraphics

@testable import VMRunner

/// A graphics display that records what it is asked for. It can refuse, and it can ignore a request the way a guest does that
/// has no driver yet: it then reports no end of the reconfiguration, as the framework does.
@MainActor
final class FakeDisplay: ResizableDisplay {
    struct Refused: Error {}

    var sizeInPixels: CGSize
    var requests: [CGSize] = []
    var refusals = 0
    var followsRequests = true
    /// The guest answers a request, so the framework reports the end of the reconfiguration.
    var answers = true
    private var observers: [Observation] = []

    final class Observation {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }

    /// How many times a follower asked to observe.
    var observerCount: Int { observers.count }

    init(sizeInPixels: CGSize = CGSize(width: 1280, height: 782)) { self.sizeInPixels = sizeInPixels }

    func reconfigure(sizeInPixels size: CGSize) throws {
        requests.append(size)
        if refusals > 0 {
            refusals -= 1
            throw Refused()
        }
        if followsRequests { sizeInPixels = size }
        if answers { endReconfiguration() }
    }

    func observeReconfigurationEnd(_ handler: @escaping @MainActor () -> Void) -> AnyObject {
        let observation = Observation(handler)
        observers.append(observation)
        return observation
    }

    /// The framework reports that frames arrived at the size last requested.
    func endReconfiguration() {
        for observer in observers { observer.handler() }
    }
}
