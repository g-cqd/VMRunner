import Testing

@testable import VMRunner

/// Every state against every event. The legal moves are written out; everything else must change nothing.
struct MachineStateTests {
    // MARK: The table

    /// A legal move: enough to name the case when it fails.
    private struct Row: Sendable, CustomTestStringConvertible {
        let from: MachineState
        let event: MachineEvent
        let to: MachineState
        let effects: [MachineEffect]

        init(_ from: MachineState, _ event: MachineEvent, _ to: MachineState, _ effects: [MachineEffect]) {
            self.from = from
            self.event = event
            self.to = to
            self.effects = effects
        }

        var testDescription: String { "\(from) + \(event) -> \(to) \(effects)" }
    }

    private static let preparing = MachineState.starting(.preparing(allowsRestore: true))
    private static let preparingCold = MachineState.starting(.preparing(allowsRestore: false))
    private static let restoring = MachineState.starting(.restoring)
    private static let booting = MachineState.starting(.booting)
    private static let starting: [MachineState] = [preparing, preparingCold, restoring, booting]
    /// States in which the guest is up and no framework call is in flight.
    private static let running: [MachineState] = [.running, .shuttingDown]
    /// States in which the machine exists and is not being force stopped.
    private static let live: [MachineState] = [restoring, booting, .running, .shuttingDown, .pausing, .paused, .resuming, .suspending]

    private static let legal: [Row] = {
        var moves: [Row] = [
            Row(.stopped, .startRequested, preparing, [.prepare]),
            Row(preparing, .prepared(canRestore: true), restoring, [.restoreState]),
            Row(preparing, .prepared(canRestore: false), booting, [.discardSavedState, .bootMachine]),
            Row(preparingCold, .prepared(canRestore: true), booting, [.discardSavedState, .bootMachine]),
            Row(preparingCold, .prepared(canRestore: false), booting, [.discardSavedState, .bootMachine]),
            Row(restoring, .restoreSucceeded, .running, [.armRuntimeLimit]),
            Row(restoring, .restoreFailed(reason: "r"), preparingCold, [.discardSavedState, .fallBackToColdBoot(reason: "r")]),
            Row(booting, .bootSucceeded, .running, [.recordFirstBoot, .showNotice, .armRuntimeLimit]),
            Row(.pausing, .pauseSucceeded, .paused, []),
            Row(.pausing, .pauseFailed("m"), .running, [.report("m")]),
            Row(.paused, .resumeRequested, .resuming, [.resumeMachine]),
            Row(.resuming, .resumeSucceeded, .running, []),
            Row(.resuming, .resumeFailed("m"), .paused, [.report("m")]),
            Row(.shuttingDown, .shutdownFailed("m"), .running, [.report("m")]),
            Row(.running, .runtimeLimitReached, .shuttingDown, [.requestGuestStop]),
            Row(.suspending, .suspendSucceeded, .stopped, [.release]),
            Row(.suspending, .suspendFailed("m", paused: true), .paused, [.report("Couldn't suspend: m")]),
            Row(.suspending, .suspendFailed("m", paused: false), .running, [.report("Couldn't suspend: m")]),
            Row(.stopping, .stopCompleted(failure: nil), .stopped, [.release]),
            Row(.stopping, .stopCompleted(failure: "m"), .stopped, [.release, .report("m")]),
            Row(.stopping, .suspendSucceeded, .stopped, [.release]),
            Row(.stopping, .startFailed("m"), .stopped, [.release]),
            Row(.stopping, .restoreFailed(reason: "r"), .stopped, [.release]),
            Row(.stopped, .quit, .stopped, []),
            Row(.suspending, .quit, .stopped, [.discardSavedState, .release]),
            Row(.suspending, .guestStopped, .stopped, [.discardSavedState, .release]),
            Row(.suspending, .stoppedWithError("e"), .stopped, [.discardSavedState, .release, .report("The virtual machine stopped: e")]),
            Row(.stopping, .stoppedWithError("e"), .stopped, [.release]),
            // Asking again while the guest has not answered, and pausing or suspending a guest that ignores the request.
            Row(.running, .shutdownRequested, .shuttingDown, [.requestGuestStop]),
            Row(.shuttingDown, .shutdownRequested, .shuttingDown, [.requestGuestStop]),
            Row(.running, .suspendRequested(supported: true), .suspending, [.suspendMachine(pauseFirst: true)]),
            Row(.shuttingDown, .suspendRequested(supported: true), .suspending, [.suspendMachine(pauseFirst: true)]),
            Row(.paused, .suspendRequested(supported: true), .suspending, [.suspendMachine(pauseFirst: false)]),
            Row(preparing, .forceStopRequested, .stopped, [.release]),
            Row(preparingCold, .forceStopRequested, .stopped, [.release]),
            Row(preparing, .quit, .stopped, [.release]),
            Row(preparingCold, .quit, .stopped, [.release]),
            Row(.stopping, .forceStopRequested, .stopped, [.release]),
        ]
        for state in running { moves.append(Row(state, .pauseRequested, .pausing, [.pauseMachine])) }
        for state in starting { moves.append(Row(state, .startFailed("m"), .stopped, [.release, .report("m")])) }
        // The machine is let go once, whatever it was doing; an error from the guest is reported unless the user pulled the plug.
        for state in live where state != .suspending {
            moves.append(Row(state, .guestStopped, .stopped, [.release]))
            moves.append(Row(state, .stoppedWithError("e"), .stopped, [.release, .report("The virtual machine stopped: e")]))
            moves.append(Row(state, .quit, .stopped, [.release]))
        }
        moves.append(Row(.stopping, .guestStopped, .stopped, [.release]))
        moves.append(Row(.stopping, .quit, .stopped, [.release]))
        // A force stop takes every live state to stopping, and is followed by the stop.
        for state in live { moves.append(Row(state, .forceStopRequested, .stopping, [.stopMachine])) }
        // Whatever the machine was waiting for, the stop goes ahead once it finishes: the machine is still there.
        for event in [
            MachineEvent.bootSucceeded, .restoreSucceeded, .pauseSucceeded, .pauseFailed("m"), .resumeSucceeded, .resumeFailed("m"),
            .suspendFailed("m", paused: true), .suspendFailed("m", paused: false),
        ] {
            moves.append(Row(.stopping, event, .stopping, [.stopMachine]))
        }
        return moves
    }()

    private static let events: [MachineEvent] = [
        .startRequested, .pauseRequested, .resumeRequested, .shutdownRequested, .forceStopRequested,
        .suspendRequested(supported: true), .suspendRequested(supported: false), .quit,
        .prepared(canRestore: true), .prepared(canRestore: false), .bootSucceeded, .restoreSucceeded, .restoreFailed(reason: "r"),
        .startFailed("m"), .pauseSucceeded, .pauseFailed("m"), .resumeSucceeded, .resumeFailed("m"), .shutdownFailed("m"),
        .suspendSucceeded, .suspendFailed("m", paused: true), .suspendFailed("m", paused: false), .stopCompleted(failure: nil),
        .stopCompleted(failure: "m"), .guestStopped, .stoppedWithError("e"), .runtimeLimitReached,
    ]

    @Test(arguments: legal)
    private func aLegalEventMovesToTheExpectedStateWithTheExpectedEffects(_ row: Row) {
        #expect(row.from.transition(on: row.event) == .moved(row.to, row.effects))
    }

    @Test func noLegalMoveIsListedTwice() {
        let keys = Self.legal.map { "\($0.from)|\($0.event)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func theTableAndTheRemainderCoverEveryPairOfStateAndEvent() {
        #expect(Self.legal.count + Self.illegalPairs.count == MachineState.all.count * Self.events.count)
    }

    // MARK: Everything else changes nothing

    private struct Pair: Sendable, CustomTestStringConvertible {
        let state: MachineState
        let event: MachineEvent
        var testDescription: String { "\(state) + \(event)" }
    }

    private static let illegalPairs: [Pair] = {
        let listed = Set(legal.map { Pair(state: $0.from, event: $0.event).testDescription })
        return MachineState.all.flatMap { state in events.map { Pair(state: state, event: $0) } }
            .filter { !listed.contains($0.testDescription) }
    }()

    @Test(arguments: illegalPairs)
    private func anyOtherEventIsRefusedOrIgnoredAndMovesNothing(_ pair: Pair) {
        switch pair.state.transition(on: pair.event) {
        case .moved(let next, let effects):
            Issue.record("\(pair.testDescription) moved to \(next) with \(effects), and is not in the table")
        case .refused(let refusal):
            #expect(pair.event.isRequest, "\(pair.testDescription) refused a report: \(refusal)")
        case .ignored:
            #expect(!pair.event.isRequest, "\(pair.testDescription) ignored a request: say why it was refused")
        }
    }

    @Test func everyRefusalNamesItsReason() {
        for state in Self.starting { #expect(state.transition(on: .startRequested) == .refused(.redundant)) }
        #expect(MachineState.running.transition(on: .startRequested) == .refused(.redundant))

        #expect(MachineState.stopped.transition(on: .pauseRequested) == .refused(.notActive))
        #expect(MachineState.paused.transition(on: .pauseRequested) == .refused(.alreadyPaused))
        #expect(MachineState.pausing.transition(on: .pauseRequested) == .refused(.redundant))
        #expect(MachineState.resuming.transition(on: .pauseRequested) == .refused(.busy(.resuming)))

        #expect(MachineState.running.transition(on: .resumeRequested) == .refused(.notPaused))
        #expect(MachineState.resuming.transition(on: .resumeRequested) == .refused(.redundant))
        #expect(MachineState.pausing.transition(on: .resumeRequested) == .refused(.busy(.pausing)))

        #expect(MachineState.paused.transition(on: .shutdownRequested) == .refused(.pausedMachine))
        #expect(MachineState.stopping.transition(on: .shutdownRequested) == .refused(.busy(.stopping)))
        for state in [Self.restoring, Self.booting] { #expect(state.transition(on: .shutdownRequested) == .refused(.busy(state))) }

        #expect(MachineState.running.transition(on: .suspendRequested(supported: false)) == .refused(.unsupported))
        #expect(MachineState.suspending.transition(on: .suspendRequested(supported: true)) == .refused(.redundant))
        #expect(MachineState.pausing.transition(on: .suspendRequested(supported: true)) == .refused(.busy(.pausing)))
        for state in Self.starting + [.stopping] {
            #expect(state.transition(on: .suspendRequested(supported: true)) == .refused(.busy(state)))
        }

        #expect(MachineState.stopped.transition(on: .forceStopRequested) == .refused(.notActive))
    }

    @Test func refusalsSayWhyInPlainWordsOrNothingAtAll() {
        #expect(Refusal.redundant.message(suspendReason: nil) == nil)
        #expect(Refusal.alreadyPaused.message(suspendReason: nil) == "The machine is already paused.")
        #expect(Refusal.notPaused.message(suspendReason: nil) == "The machine isn't paused.")
        #expect(Refusal.notActive.message(suspendReason: nil) == "The machine isn't running.")
        #expect(Refusal.pausedMachine.message(suspendReason: nil)?.contains("Resume it first") == true)
        #expect(Refusal.busy(.pausing).message(suspendReason: nil) == "The machine is pausing. Try again when it has finished.")
        #expect(Refusal.unsupported.message(suspendReason: "Filtered networking can't be saved.") == "Filtered networking can't be saved.")
        #expect(Refusal.unsupported.message(suspendReason: nil) == "Suspend isn't available for this machine.")
    }

    // MARK: Properties of the whole graph

    private struct Move {
        let state: MachineState
        let event: MachineEvent
        let effects: [MachineEffect]
        let next: MachineState
    }

    private func allMoves() -> [Move] {
        MachineState.all.flatMap { state in
            Self.events.compactMap { event -> Move? in
                guard case .moved(let next, let effects) = state.transition(on: event) else { return nil }
                return Move(state: state, event: event, effects: effects, next: next)
            }
        }
    }

    @Test func onlyTheLastEffectOfAMoveWaitsForTheFramework() {
        for move in allMoves() {
            #expect(!move.effects.dropLast().contains { $0.waits }, "\(move.state) + \(move.event) waits before its last effect")
        }
    }

    @Test func preparingWaitsSoTheMainActorIsFreeWhileTheConfigurationIsBuilt() {
        #expect(MachineEffect.prepare.waits)
        #expect(MachineEffect.fallBackToColdBoot(reason: "x").waits)
    }

    @Test func aMachineIsReleasedExactlyWhenItReachesStoppedFromAnActiveState() {
        for move in allMoves() {
            let releases = move.effects.contains(.release)
            let ends = move.state.isActive && move.next == .stopped
            #expect(releases == ends, "\(move.state) + \(move.event) -> \(move.next): release \(releases)")
        }
    }

    @Test func aSuspendThatEndsAnyOtherWayThanByItsOwnOutcomeDiscardsTheImage() {
        for move in allMoves() where move.state == .suspending && move.next == .stopped {
            let byOutcome = move.event == .suspendSucceeded
            #expect(move.effects.contains(.discardSavedState) == !byOutcome, "\(move.event)")
        }
    }

    @Test func everyStateCanReachStopped() {
        var reaches: Set<MachineState> = [.stopped]
        var changed = true
        let moves = allMoves()
        while changed {
            changed = false
            for move in moves where reaches.contains(move.next) && !reaches.contains(move.state) {
                reaches.insert(move.state)
                changed = true
            }
        }
        #expect(reaches == Set(MachineState.all))
    }

    @Test func aMachineBeingStoppedOnlyEverStaysStoppingOrStops() {
        for move in allMoves() where move.state == .stopping {
            #expect(move.next == .stopping || move.next == .stopped, "\(move.event)")
        }
    }

    @Test func theInterfaceOffersExactlyWhatTheTableAllows() {
        func moves(_ state: MachineState, on event: MachineEvent) -> Bool {
            if case .moved = state.transition(on: event) { true } else { false }
        }
        for state in MachineState.all {
            #expect(state.canStart == moves(state, on: .startRequested), "\(state)")
            #expect(state.canPause == moves(state, on: .pauseRequested), "\(state)")
            #expect(state.canResume == moves(state, on: .resumeRequested), "\(state)")
            #expect(state.canShutDown == moves(state, on: .shutdownRequested), "\(state)")
            #expect(state.canForceStop == moves(state, on: .forceStopRequested), "\(state)")
            #expect(state.allowsSuspend == moves(state, on: .suspendRequested(supported: true)), "\(state)")
        }
    }

    @Test func theInterfaceSaysWhatAMachineInTheMiddleOfAStepIsDoing() {
        for state in MachineState.all {
            let transitional = state != .stopped && state != .running
            #expect((state.statusText != nil) == transitional, "\(state)")
        }
        #expect(MachineState.paused.statusText == "Paused")
        #expect(MachineState.shuttingDown.statusText == "Shutting down…")
        #expect(Self.restoring.statusText == "Resuming from suspended state…")
        #expect(MachineState.paused.showsResume && MachineState.resuming.showsResume)
        #expect(!MachineState.running.showsResume && !MachineState.pausing.showsResume)
    }

    @Test func aMachineIsBoundToTheDisplayFromTheEndOfPreparationUntilItIsReleased() {
        for state in MachineState.all {
            #expect(state.hasMachine == (state != .stopped && state != Self.preparing && state != Self.preparingCold), "\(state)")
        }
    }

    @Test func theSidebarDotFollowsTheState() {
        #expect(MachineState.stopped.indicator == .none)
        #expect(MachineState.running.indicator == .running)
        for state in [MachineState.paused, .pausing, .resuming] { #expect(state.indicator == .paused) }
        for state in [Self.booting, .shuttingDown, .suspending, .stopping] { #expect(state.indicator == .busy) }
    }

    /// A walk through random events from stopped: whatever happens, the resources held match the state.
    @Test func resourcesAreHeldExactlyWhileAMachineExists() {
        var generator = SplitMix(seed: 7)
        var state = MachineState.stopped
        var held = false
        for _ in 0..<20_000 {
            let event = Self.events[Int(generator.next() % UInt64(Self.events.count))]
            guard case .moved(let next, let effects) = state.transition(on: event) else { continue }
            for effect in effects {
                switch effect {
                case .prepare, .fallBackToColdBoot: held = true
                case .release: held = false
                default: break
                }
            }
            state = next
            #expect(held == state.isActive, "after \(event): \(state)")
        }
    }
}

/// A small seeded generator, so the walk is the same on every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
