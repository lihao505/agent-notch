//
//  Modified by lihao505 for Agent Notch, 2026.
//  LifecycleReducer.swift
//  ClaudeIsland
//
//  Pure lifecycle arbitration shared by native agent observations. The first
//  production caller is Codex; Claude and CodeBuddy can migrate incrementally
//  without changing the reducer contract.
//

import Foundation

nonisolated enum LifecycleObservationOrigin: String, Equatable, Sendable {
    case codexDiscovery
    case codexPolling
}

nonisolated enum LifecycleEvidence: Equatable, Sendable {
    case active(turnStartedAt: Date?, lastEvidenceAt: Date?)
    case completed(Date?)
    case missing
    case unknown

    init(codexLifecycle: CodexTaskLifecycle) {
        switch codexLifecycle {
        case .active(let turnStartedAt, let lastEvidenceAt):
            self = .active(
                turnStartedAt: turnStartedAt,
                lastEvidenceAt: lastEvidenceAt
            )
        case .completed(let completedAt):
            self = .completed(completedAt)
        case .missing:
            self = .missing
        case .unknown:
            self = .unknown
        }
    }
}

nonisolated struct SessionLifecycleObservation: Equatable, Sendable {
    let sessionId: String
    let cwd: String
    let source: AgentSource
    let origin: LifecycleObservationOrigin
    let evidence: LifecycleEvidence
    /// The timestamp attached to the native source, such as rollout mtime.
    let observedAt: Date
    /// The time Agent Notch performed arbitration.
    let receivedAt: Date
}

/// Only the lifecycle-owned portion of SessionState. Keeping the reducer free
/// of chat/tool/UI data makes every arbitration rule deterministic and cheap to
/// exercise with an exhaustive transition matrix.
nonisolated struct SessionLifecycleSnapshot: Equatable, Sendable {
    var source: AgentSource
    var phase: SessionPhase
    var lastActivity: Date
    var createdAt: Date
    var lastHookEventAt: Date?
    var turnStartedAt: Date?
    var completedAt: Date?

    init(
        source: AgentSource,
        phase: SessionPhase,
        lastActivity: Date,
        createdAt: Date,
        lastHookEventAt: Date? = nil,
        turnStartedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.source = source
        self.phase = phase
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.lastHookEventAt = lastHookEventAt
        self.turnStartedAt = turnStartedAt
        self.completedAt = completedAt
    }

    init(session: SessionState) {
        self.init(
            source: session.source,
            phase: session.phase,
            lastActivity: session.lastActivity,
            createdAt: session.createdAt,
            lastHookEventAt: session.lastHookEventAt,
            turnStartedAt: session.lastCodexTurnStartedAt,
            completedAt: session.completedAt
        )
    }

    func applying(to session: inout SessionState) {
        session.source = source
        session.phase = phase
        session.lastActivity = lastActivity
        session.createdAt = createdAt
        session.lastHookEventAt = lastHookEventAt
        session.lastCodexTurnStartedAt = turnStartedAt
        session.completedAt = completedAt
    }
}

nonisolated enum LifecycleTransitionReason: String, Equatable, Sendable {
    case discoveredActiveTurn
    case activeTurnAdvanced
    case newerTurnStarted
    case nativeCompletion
    case staleActiveTimedOut
    case unknownActiveTimedOut
    case sourceMissingBeyondGrace
    case creationNotAllowed
    case staleDiscovery
    case activeWithoutNewGeneration
    case completionOlderThanHook
    case completionOlderThanTurn
    case interactionHasPriority
    case missingWithinGrace
    case unknownWithinGrace
    case sessionNotFound
    case alreadyCurrent
}

nonisolated enum LifecycleTransitionMutation: Equatable, Sendable {
    case create(SessionLifecycleSnapshot)
    case update(SessionLifecycleSnapshot)
    case remove
    case none
}

nonisolated struct LifecycleTransition: Equatable, Sendable {
    let mutation: LifecycleTransitionMutation
    let reason: LifecycleTransitionReason

    var didMutate: Bool {
        switch mutation {
        case .create, .update, .remove:
            return true
        case .none:
            return false
        }
    }

    var nextSnapshot: SessionLifecycleSnapshot? {
        switch mutation {
        case .create(let snapshot), .update(let snapshot):
            return snapshot
        case .remove, .none:
            return nil
        }
    }
}

/// Privacy-minimized evidence explaining why a visible status changed or why
/// an observation was ignored. SessionStore retains a bounded in-memory ring;
/// no transcript text, tool input, or filesystem path is included.
nonisolated struct LifecycleTraceEntry: Equatable, Sendable {
    let observedAt: Date
    let receivedAt: Date
    let origin: LifecycleObservationOrigin
    let evidence: LifecycleEvidence
    let reason: LifecycleTransitionReason
    let didMutate: Bool
    let previousPhase: SessionPhase?
    let nextPhase: SessionPhase?

    init(
        observation: SessionLifecycleObservation,
        previous: SessionLifecycleSnapshot?,
        transition: LifecycleTransition
    ) {
        observedAt = observation.observedAt
        receivedAt = observation.receivedAt
        origin = observation.origin
        evidence = observation.evidence
        reason = transition.reason
        didMutate = transition.didMutate
        previousPhase = previous?.phase
        switch transition.mutation {
        case .create(let snapshot), .update(let snapshot):
            nextPhase = snapshot.phase
        case .remove:
            nextPhase = nil
        case .none:
            nextPhase = previous?.phase
        }
    }
}

nonisolated enum LifecycleReducer {
    static func reduce(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        allowCreation: Bool,
        activeStaleInterval: TimeInterval,
        missingGracePeriod: TimeInterval
    ) -> LifecycleTransition {
        switch observation.evidence {
        case .active(let turnStartedAt, let lastEvidenceAt):
            return reduceActive(
                current: current,
                observation: observation,
                turnStartedAt: turnStartedAt,
                lastEvidenceAt: lastEvidenceAt,
                allowCreation: allowCreation,
                activeStaleInterval: activeStaleInterval
            )

        case .completed(let completedAt):
            return reduceCompletion(
                current: current,
                observation: observation,
                completedAt: completedAt
            )

        case .missing:
            return reduceMissing(
                current: current,
                observation: observation,
                missingGracePeriod: missingGracePeriod
            )

        case .unknown:
            return reduceUnknown(
                current: current,
                observation: observation,
                activeStaleInterval: activeStaleInterval
            )
        }
    }

    private static func reduceActive(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        turnStartedAt: Date?,
        lastEvidenceAt: Date?,
        allowCreation: Bool,
        activeStaleInterval: TimeInterval
    ) -> LifecycleTransition {
        let evidenceAt = lastEvidenceAt ?? turnStartedAt ?? observation.observedAt

        guard var next = current else {
            guard allowCreation else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .creationNotAllowed
                )
            }
            guard observation.receivedAt.timeIntervalSince(evidenceAt) <
                    activeStaleInterval else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .staleDiscovery
                )
            }
            return LifecycleTransition(
                mutation: .create(SessionLifecycleSnapshot(
                    source: observation.source,
                    phase: .processing,
                    lastActivity: evidenceAt,
                    createdAt: turnStartedAt ?? evidenceAt,
                    turnStartedAt: turnStartedAt
                )),
                reason: .discoveredActiveTurn
            )
        }

        let interactionHasPriority = next.phase.isWaitingForApproval

        let newestEvidenceAt = max(
            evidenceAt,
            next.lastHookEventAt ?? .distantPast
        )
        if !interactionHasPriority,
           observation.receivedAt.timeIntervalSince(newestEvidenceAt) >=
            activeStaleInterval {
            if next.phase == .waitingForInput, next.completedAt != nil {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .alreadyCurrent
                )
            }
            next.phase = .waitingForInput
            next.completedAt = observation.receivedAt
            return LifecycleTransition(
                mutation: .update(next),
                reason: .staleActiveTimedOut
            )
        }

        if let completedAt = next.completedAt {
            guard let turnStartedAt, turnStartedAt > completedAt else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .activeWithoutNewGeneration
                )
            }
        }

        let previous = next
        next.source = observation.source
        next.turnStartedAt = turnStartedAt ?? next.turnStartedAt
        next.lastActivity = max(next.lastActivity, evidenceAt)
        if !interactionHasPriority, !next.phase.isActive {
            next.phase = .processing
        }
        if !interactionHasPriority {
            next.completedAt = nil
        }

        guard next != previous else {
            return LifecycleTransition(
                mutation: .none,
                reason: interactionHasPriority
                    ? .interactionHasPriority
                    : .alreadyCurrent
            )
        }
        return LifecycleTransition(
            mutation: .update(next),
            reason: interactionHasPriority
                ? .interactionHasPriority
                : previous.completedAt == nil
                    ? .activeTurnAdvanced
                    : .newerTurnStarted
        )
    }

    private static func reduceCompletion(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        completedAt: Date?
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        guard !next.phase.isWaitingForApproval else {
            return LifecycleTransition(
                mutation: .none,
                reason: .interactionHasPriority
            )
        }

        let completionEvidenceAt = completedAt ?? observation.observedAt
        if next.completedAt == nil,
           let lastHookEventAt = next.lastHookEventAt,
           lastHookEventAt > completionEvidenceAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .completionOlderThanHook
            )
        }
        if let turnStartedAt = next.turnStartedAt,
           turnStartedAt > completionEvidenceAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .completionOlderThanTurn
            )
        }
        guard next.completedAt == nil || next.phase != .waitingForInput else {
            return LifecycleTransition(
                mutation: .none,
                reason: .alreadyCurrent
            )
        }

        next.phase = .waitingForInput
        next.completedAt = completionEvidenceAt
        next.lastActivity = max(next.lastActivity, completionEvidenceAt)
        return LifecycleTransition(
            mutation: .update(next),
            reason: .nativeCompletion
        )
    }

    private static func reduceMissing(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        missingGracePeriod: TimeInterval
    ) -> LifecycleTransition {
        guard let current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        guard observation.receivedAt.timeIntervalSince(current.lastActivity) >=
                missingGracePeriod else {
            return LifecycleTransition(
                mutation: .none,
                reason: .missingWithinGrace
            )
        }
        return LifecycleTransition(
            mutation: .remove,
            reason: .sourceMissingBeyondGrace
        )
    }

    private static func reduceUnknown(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        activeStaleInterval: TimeInterval
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        guard !next.phase.isWaitingForApproval else {
            return LifecycleTransition(
                mutation: .none,
                reason: .interactionHasPriority
            )
        }
        guard next.phase.isActive,
              observation.receivedAt.timeIntervalSince(next.lastActivity) >=
                activeStaleInterval else {
            return LifecycleTransition(
                mutation: .none,
                reason: .unknownWithinGrace
            )
        }

        next.phase = .waitingForInput
        next.completedAt = observation.receivedAt
        return LifecycleTransition(
            mutation: .update(next),
            reason: .unknownActiveTimedOut
        )
    }
}
