import Foundation

/// Passive, heuristic detection of a VPN or tunnel running inside the guest, from the packets the user-mode stack
/// forwards. Pure and deterministic: time is passed in (monotonic seconds), nothing is read from the system.
///
/// ## How it decides
/// Each recognized packet shape (see ``GuestVPNSignature``) adds evidence keyed by signature, direction and peer. A
/// kind's score is that of its best peer: the sum of its evidence weights (each repeat counts up to a cap) plus a
/// corroboration bonus when that peer showed two different shapes of the kind (a signature, or the same signature in
/// the other direction) with combined weight of at least 4, for example a WireGuard initiation answered by a
/// response, or an IKE request and its reply. Peers are scored separately so scattered noise never adds up.
///
/// A kind is *suspected* when its score reaches ``Configuration/enterScore`` **and** at least
/// ``Configuration/minimumObservations`` packets matched, so one packet never changes the state. Once suspected it is
/// held while any evidence remains (score at least ``Configuration/exitScore``); evidence expires after
/// ``Configuration/evidenceLifetime`` seconds without a repeat, so the state returns to `.none` only after a quiet
/// period, and confidence falls only as evidence expires. A different kind replaces the current one only if it scores
/// ``Configuration/switchMargin`` points higher.
///
/// ## What it does not do
/// It sees headers, not meaning; see ``GuestVPNState`` for the long list of tunnels that are invisible to it (TLS-based
/// VPNs, obfuscated protocols, Tor). It has **no generic "high-volume UDP to one peer" rule**: QUIC, WebRTC, games,
/// and torrent traffic have exactly that profile, and the payload entropy test that would separate them from a VPN also
/// matches QUIC, so any such rule would false-positive on ordinary browsing. A sustained two-way stream of nothing
/// but WireGuard-shaped keepalives and data packets can reach `medium` by chance; only handshake shapes reach `high`.
///
/// DNS names are never matched against a built-in provider list; ``Configuration/hintDomains`` is empty by default and
/// a hint alone never exceeds `low` confidence.
struct GuestVPNDetector: Sendable {
    struct Configuration: Sendable {
        /// Minimum score to start suspecting a kind.
        var enterScore = 4
        /// Score from which confidence is `medium`.
        var mediumScore = 6
        /// Score from which confidence is `high`.
        var highScore = 8
        /// A suspected kind is held while its score stays at or above this (hysteresis).
        var exitScore = 1
        /// Minimum number of matching packets before any kind is suspected.
        var minimumObservations = 2
        /// Seconds without a repeat after which a piece of evidence is forgotten.
        var evidenceLifetime: TimeInterval = 300
        /// How many points a challenger must lead by to replace the current kind.
        var switchMargin = 2
        /// DNS names that hint at a VPN provider. Empty by default: the detector ships no provider list.
        var hintDomains: [DomainRule] = []
    }

    private struct EvidenceKey: Hashable, Sendable {
        let signature: GuestVPNSignature
        let peer: IPAddress?
        let direction: GuestPacketObservation.Direction
    }

    private struct Pick {
        let kind: GuestVPNKind
        let confidence: GuestVPNConfidence
        let score: Int
    }

    private struct Tally {
        var score = 0
        var observations = 0
    }

    private struct Current: Sendable {
        var kind: GuestVPNKind
        var confidence: GuestVPNConfidence
        var since: TimeInterval
    }

    private static let maxEvidenceEntries = 64
    private static let maxReportedEvidence = 8

    private let configuration: Configuration
    private var evidence: [EvidenceKey: GuestVPNEvidence] = [:]
    private var current: Current?
    private var lastPrune = -TimeInterval.infinity

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The current verdict, including the latest evidence. Updating evidence does not by itself count as a change.
    var state: GuestVPNState {
        guard let current else { return .none }
        return .suspected(
            kind: current.kind, confidence: current.confidence, since: current.since, evidence: reportedEvidence(for: current.kind))
    }

    /// Feeds one packet.
    /// - Returns: the new state when the suspected kind or its confidence changed, or when it became or stopped being
    ///   suspected; `nil` otherwise. Repeats of the same evidence never return a value.
    mutating func observe(_ packet: GuestPacketObservation, at now: TimeInterval) -> GuestVPNState? {
        var changed = pruneIfDue(at: now)
        guard let match = GuestVPNMatcher.match(packet) else { return changed }
        if match.needsAnchor, !hasAnchor(for: match.signature.kind, peer: packet.peer) { return changed }
        if record(match.signature, peer: packet.peer, direction: packet.direction, detail: nil, at: now), let new = reevaluate(at: now) {
            changed = new
        }
        return changed
    }

    /// Feeds a name the guest resolved. Only names matching ``Configuration/hintDomains`` have any effect.
    /// - Returns: as for ``observe(_:at:)``.
    mutating func observeDNSQuery(name: String, at now: TimeInterval) -> GuestVPNState? {
        var changed = pruneIfDue(at: now)
        guard !configuration.hintDomains.isEmpty else { return changed }
        var normalized = name.lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard configuration.hintDomains.contains(where: { $0.matches(normalized) }) else { return changed }
        if record(.dnsHint, peer: nil, direction: .fromGuest, detail: normalized, at: now), let new = reevaluate(at: now) { changed = new }
        return changed
    }

    /// Lets time pass: forgets expired evidence and re-evaluates.
    /// - Returns: the new state if it changed.
    mutating func tick(at now: TimeInterval) -> GuestVPNState? {
        prune(at: now)
    }

    // MARK: Evidence

    /// Records a match. Returns whether the score could have changed (a new entry, or a repeat below the cap).
    private mutating func record(
        _ signature: GuestVPNSignature, peer: IPAddress?, direction: GuestPacketObservation.Direction, detail: String?,
        at now: TimeInterval
    ) -> Bool {
        let key = EvidenceKey(signature: signature, peer: peer, direction: direction)
        if var existing = evidence[key] {
            existing.count += 1
            existing.lastSeen = now
            existing.detail = detail ?? existing.detail
            evidence[key] = existing
            return existing.count <= signature.maxCount
        }
        if evidence.count >= Self.maxEvidenceEntries, let oldest = evidence.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            evidence[oldest] = nil
        }
        evidence[key] = GuestVPNEvidence(
            signature: signature, peer: peer, direction: direction, count: 1, firstSeen: now, lastSeen: now, detail: detail)
        return true
    }

    private func hasAnchor(for kind: GuestVPNKind, peer: IPAddress) -> Bool {
        evidence.values.contains { $0.kind == kind && $0.peer == peer && $0.signature.isAnchor }
    }

    private mutating func pruneIfDue(at now: TimeInterval) -> GuestVPNState? {
        guard now - lastPrune >= 1 else { return nil }
        return prune(at: now)
    }

    private mutating func prune(at now: TimeInterval) -> GuestVPNState? {
        lastPrune = now
        let lifetime = configuration.evidenceLifetime
        // Rebuilds the table only when something expired, so the common once-a-second call allocates nothing.
        guard evidence.values.contains(where: { now - $0.lastSeen > lifetime }) else { return nil }
        evidence = evidence.filter { now - $0.value.lastSeen <= lifetime }
        return reevaluate(at: now)
    }

    private func reportedEvidence(for kind: GuestVPNKind) -> [GuestVPNEvidence] {
        let ofKind = evidence.values.filter { $0.kind == kind }.sorted {
            ($1.weight, $0.signature.rawValue) < ($0.weight, $1.signature.rawValue)
        }
        return Array(ofKind.prefix(Self.maxReportedEvidence))
    }

    // MARK: Scoring

    /// Scores each (kind, peer) separately and keeps the best peer per kind, so scattered noise toward many different
    /// addresses never adds up to a verdict.
    private func tallies() -> [GuestVPNKind: Tally] {
        var perPeer: [PeerKind: Tally] = [:]
        var shapes: [PeerKind: Set<Shape>] = [:]
        for entry in evidence.values {
            let key = PeerKind(kind: entry.kind, peer: entry.peer)
            perPeer[key, default: Tally()].score += entry.weight
            perPeer[key, default: Tally()].observations += entry.count
            shapes[key, default: []].insert(Shape(entry.signature, entry.direction))
        }
        var result: [GuestVPNKind: Tally] = [:]
        for (key, var tally) in perPeer {
            let seen = shapes[key] ?? []
            if seen.count >= 2, seen.reduce(0, { $0 + $1.signature.weight }) >= 4 { tally.score += 2 }
            if tally.score > result[key.kind]?.score ?? -1 { result[key.kind] = tally }
        }
        return result
    }

    /// A signature seen in one direction: a request and its answer are two shapes, a retransmission is not.
    private struct Shape: Hashable {
        let signature: GuestVPNSignature
        let direction: GuestPacketObservation.Direction

        init(_ signature: GuestVPNSignature, _ direction: GuestPacketObservation.Direction) {
            self.signature = signature
            self.direction = direction
        }
    }

    private struct PeerKind: Hashable {
        let kind: GuestVPNKind
        let peer: IPAddress?
    }

    private func confidence(of kind: GuestVPNKind, _ tally: Tally) -> GuestVPNConfidence {
        if kind == .dnsHint { return .low }
        if tally.score >= configuration.highScore { return .high }
        return tally.score >= configuration.mediumScore ? .medium : .low
    }

    private func qualifies(_ kind: GuestVPNKind, _ tally: Tally) -> Bool {
        if current?.kind == kind { return tally.score >= configuration.exitScore && tally.observations >= 1 }
        return tally.score >= configuration.enterScore && tally.observations >= configuration.minimumObservations
    }

    /// Recomputes the verdict. Returns it when the kind or confidence changed (or suspicion started or ended).
    private mutating func reevaluate(at now: TimeInterval) -> GuestVPNState? {
        let scored = tallies()
        let previous = current
        var best: Pick?
        for kind in GuestVPNKind.allCases {
            guard let tally = scored[kind], qualifies(kind, tally) else { continue }
            let level = confidence(of: kind, tally)
            if best == nil || (level, tally.score) > (best?.confidence ?? .low, best?.score ?? 0) {
                best = Pick(kind: kind, confidence: level, score: tally.score)
            }
        }
        if let held = previous, let heldTally = scored[held.kind], qualifies(held.kind, heldTally), let challenger = best,
            challenger.kind != held.kind, challenger.score < heldTally.score + configuration.switchMargin
        {
            best = Pick(kind: held.kind, confidence: confidence(of: held.kind, heldTally), score: heldTally.score)
        }
        guard let chosen = best else {
            current = nil
            return previous == nil ? nil : GuestVPNState.none
        }
        let since = previous?.kind == chosen.kind ? previous?.since ?? now : now
        current = Current(kind: chosen.kind, confidence: chosen.confidence, since: since)
        return previous?.kind == chosen.kind && previous?.confidence == chosen.confidence ? nil : state
    }
}
