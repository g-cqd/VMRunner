import Foundation
import NetPolicy
import NetStack
import VMHelperCore

/// The user-mode stack of a `filtered` network while the machine runs: it starts the stack, reports what the stack does as
/// events, applies the policy again on command, and stops the stack when the machine ends.
@MainActor
final class FilteredNetwork {
    /// How often the counters are reported when they changed.
    static let statisticsInterval = Duration.seconds(5)

    private let stack: UserNetStack
    private let emitter: Emitter
    private let policyPath: String?
    private var flowReader: Task<Void, Never>?
    private var vpnReader: Task<Void, Never>?
    private var statisticsTicker: Task<Void, Never>?
    private var lastStatistics: UserNetStats?

    init(stack: UserNetStack, emitter: Emitter, policyPath: String?) {
        self.stack = stack
        self.emitter = emitter
        self.policyPath = policyPath
    }

    func start() {
        stack.start()
        let events = stack.flowEvents
        let emitter = emitter
        flowReader = Task.detached {
            for await event in events {
                emitter.emit(.flow, message: event.eventLine, check: event.outcomeWord)
            }
        }
        let verdicts = stack.vpnChanges
        vpnReader = Task.detached {
            for await state in verdicts { emitter.emit(.vpn, message: state.eventLine) }
        }
        statisticsTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statisticsInterval)
                self?.reportStatistics(onlyWhenChanged: true)
            }
        }
    }

    func apply(_ command: HelperCommand) {
        switch command {
        case .statistics:
            reportStatistics(onlyWhenChanged: false)
        case .reloadPolicy(let terminating):
            do {
                let policy = try PolicyFile.load(policyPath)
                stack.updatePolicy(policy, existingFlows: terminating ? .terminate : .keep)
                emitter.emit(.policy, message: policyPath ?? "the default policy", check: "applied")
            } catch let failure as HelperFailure {
                reject(failure.message)
            } catch {
                reject("\(error)")
            }
        }
    }

    /// Reports a command the helper could not carry out.
    func reject(_ reason: String) {
        emitter.emit(.policy, message: reason, check: "rejected")
    }

    /// Stops the stack, lets the flow events it ended with be reported, then reports the counters one last time.
    func stop() async {
        statisticsTicker?.cancel()
        await stack.stop()
        await flowReader?.value
        await vpnReader?.value
        reportStatistics(onlyWhenChanged: false)
    }

    private func reportStatistics(onlyWhenChanged: Bool) {
        let current = stack.stats
        if onlyWhenChanged, current == lastStatistics { return }
        lastStatistics = current
        emitter.emit(.statistics, message: current.summaryLine)
    }
}
