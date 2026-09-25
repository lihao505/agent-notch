//
//  Modified by lihao505 for Agent Notch, 2026.
//  LifecycleReducer.swift
//  ClaudeIsland
//
//  Pure lifecycle arbitration shared by native discovery, hooks, transcripts,
//  local interaction callbacks, interrupts, bridge restore, and process exit.
//

import Foundation

nonisolated enum LifecycleObservationOrigin: String, Equatable, Sendable {
    case codexDiscovery
    case codexPolling
    case hook
    case localInteraction
    case transcript
    case bridgeSnapshot
    case interruptWatcher
    case processMonitor
}

/// Redacted hook intent retained by the decision trace. The concrete target
/// phase travels separately so permission inputs never enter the trace ring.
nonisolated enum HookLifecycleSignal: String, Equatable, Sendable {
    case active
    case interaction
    case compacting
    case completed
    case ended
    case removed
}

/// Privacy-safe queue reconciliation signal. The permission context, tool
/// result, and response payload remain in SessionStore and never enter the
/// lifecycle decision trace.
nonisolated enum InteractionResolutionSignal: String, Equatable, Sendable {
    case approved
    case denied
    case deliveryFailed
    case hookCompleted
    case transcriptCompleted
    case queueReconciled
}

nonisolated enum LifecycleEvidence: Equatable, Sendable {
    case active(turnStartedAt: Date?, lastEvidenceAt: Date?)
    case completed(Date?)
    case missing
    case unknown
    case hook(HookLifecycleSignal)
    case interactionResolution(InteractionResolutionSignal)
    case interrupt
    case processExited

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
    /// Used only during arbitration. LifecycleTraceEntry deliberately stores a
    /// redacted phase kind rather than this potentially sensitive value.
    let requestedPhase: SessionPhase?
    /// The timestamp attached to the native source, such as rollout mtime.
    let observedAt: Date
    /// The time Agent Notch performed arbitration.
    let receivedAt: Date

    init(
        sessionId: String,
        cwd: String,
        source: AgentSource,
        origin: LifecycleObservationOrigin,
        evidence: LifecycleEvidence,
        requestedPhase: SessionPhase? = nil,
        observedAt: Date,
        receivedAt: Date
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.source = source
        self.origin = origin
        self.evidence = evidence
        self.requestedPhase = requestedPhase
        self.observedAt = observedAt
        self.receivedAt = receivedAt
    }
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
    case activeOlderThanHook
    case activeWithoutNewGeneration
    case completionOlderThanHook
    case completionOlderThanTurn
    case interactionHasPriority
    case missingWithinGrace
    case unknownWithinGrace
    case sessionNotFound
    case alreadyCurrent
    case hookPhaseAdvanced
    case hookCompletion
    case hookSessionEnded
    case hookSessionRemoved
    case hookOlderThanBoundary
    case invalidHookPhase
    case interactionResolved
    case localFailurePreservedNewerActivity
    case interactionOlderThanCompletion
    case interactionOlderThanBoundary
    case invalidInteractionPhase
    case interruptAccepted
    case interruptOlderThanBoundary
    case processExitAccepted
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

    /// Rejected observations must not update tool tracking, topology, or the
    /// interaction queue. Accepted duplicates remain safe to consume because
    /// those secondary operations are idempotent by tool-use identity.
    var acceptsObservation: Bool {
        switch reason {
        case .creationNotAllowed,
             .staleDiscovery,
             .activeOlderThanHook,
             .activeWithoutNewGeneration,
             .completionOlderThanHook,
             .completionOlderThanTurn,
             .sessionNotFound,
             .hookOlderThanBoundary,
             .invalidHookPhase,
             .interactionOlderThanCompletion,
             .interactionOlderThanBoundary,
             .invalidInteractionPhase,
             .interruptOlderThanBoundary:
            return false
        default:
            return true
        }
    }
}

/// Phase classification safe for diagnostics. Unlike SessionPhase this never
/// retains a PermissionContext or its tool input.
nonisolated enum LifecyclePhaseKind: String, Equatable, Sendable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval
    case compacting
    case ended

    init(_ phase: SessionPhase) {
        switch phase {
        case .idle:
            self = .idle
        case .processing:
            self = .processing
        case .waitingForInput:
            self = .waitingForInput
        case .waitingForApproval:
            self = .waitingForApproval
        case .compacting:
            self = .compacting
        case .ended:
            self = .ended
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
    let previousPhase: LifecyclePhaseKind?
    let nextPhase: LifecyclePhaseKind?

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
        previousPhase = previous.map { LifecyclePhaseKind($0.phase) }
        switch transition.mutation {
        case .create(let snapshot), .update(let snapshot):
            nextPhase = LifecyclePhaseKind(snapshot.phase)
        case .remove:
            nextPhase = nil
        case .none:
            nextPhase = previous.map { LifecyclePhaseKind($0.phase) }
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

        case .hook(let signal):
            return reduceHook(
                current: current,
                observation: observation,
                signal: signal
            )

        case .interactionResolution(let signal):
            return reduceInteractionResolution(
                current: current,
                observation: observation,
                signal: signal
            )

        case .interrupt:
            return reduceInterrupt(
                current: current,
                observation: observation
            )

        case .processExited:
            return reduceProcessExit(
                current: current,
                observation: observation
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

        if let lastHookEventAt = next.lastHookEventAt,
           evidenceAt <= lastHookEventAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .activeOlderThanHook
            )
        }

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
        if let turnStartedAt {
            next.turnStartedAt = max(
                next.turnStartedAt ?? .distantPast,
                turnStartedAt
            )
        }
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

    /// Hook delivery and native rollout polling share the same ordering
    /// boundaries but have different authority. A fresh Stop is allowed to
    /// close an outstanding interaction; passive Codex polling is not. Ties
    /// favor completion so a delayed tool-start cannot revive the same turn.
    private static func reduceHook(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        signal: HookLifecycleSignal
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }

        let observedAt = observation.observedAt
        if let lastHookEventAt = next.lastHookEventAt,
           observedAt < lastHookEventAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .hookOlderThanBoundary
            )
        }

        switch signal {
        case .active, .interaction, .compacting:
            if let completedAt = next.completedAt,
               observedAt <= completedAt {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .activeWithoutNewGeneration
                )
            }

            guard let requestedPhase = observation.requestedPhase else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .invalidHookPhase
                )
            }

            let previous = next
            let interactionHasPriority = next.phase.isWaitingForApproval &&
                signal != .interaction
            next.source = observation.source
            next.lastActivity = max(next.lastActivity, observedAt)
            next.lastHookEventAt = max(
                next.lastHookEventAt ?? .distantPast,
                observedAt
            )
            next.completedAt = nil

            if !interactionHasPriority {
                // A fresh hook is an authoritative resume boundary even if a
                // persisted session had previously reached the terminal phase.
                if signal == .interaction ||
                   next.phase == .ended ||
                   next.phase.canTransition(to: requestedPhase) {
                    next.phase = requestedPhase
                } else {
                    return LifecycleTransition(
                        mutation: .none,
                        reason: .invalidHookPhase
                    )
                }
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
                    : .hookPhaseAdvanced
            )

        case .completed:
            if let turnStartedAt = next.turnStartedAt,
               turnStartedAt > observedAt {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .completionOlderThanTurn
                )
            }

            let previous = next
            next.source = observation.source
            next.phase = .waitingForInput
            next.lastActivity = max(next.lastActivity, observedAt)
            next.lastHookEventAt = max(
                next.lastHookEventAt ?? .distantPast,
                observedAt
            )
            next.completedAt = max(
                next.completedAt ?? .distantPast,
                observedAt
            )
            guard next != previous else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .alreadyCurrent
                )
            }
            return LifecycleTransition(
                mutation: .update(next),
                reason: .hookCompletion
            )

        case .ended, .removed:
            let latestBoundary = max(
                next.completedAt ?? .distantPast,
                next.turnStartedAt ?? .distantPast
            )
            guard observedAt >= latestBoundary else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .hookOlderThanBoundary
                )
            }
            if signal == .removed {
                return LifecycleTransition(
                    mutation: .remove,
                    reason: .hookSessionRemoved
                )
            }

            let previous = next
            next.source = observation.source
            next.phase = .ended
            next.lastActivity = max(next.lastActivity, observedAt)
            next.lastHookEventAt = max(
                next.lastHookEventAt ?? .distantPast,
                observedAt
            )
            next.completedAt = max(
                next.completedAt ?? .distantPast,
                observedAt
            )
            guard next != previous else {
                return LifecycleTransition(
                    mutation: .none,
                    reason: .alreadyCurrent
                )
            }
            return LifecycleTransition(
                mutation: .update(next),
                reason: .hookSessionEnded
            )
        }
    }

    /// An exact queue item may be resolved locally, by a hook, or by a timed
    /// transcript row. None may erase a newer completion; a late local socket
    /// failure also cannot idle work that resumed in the meantime.
    private static func reduceInteractionResolution(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        signal: InteractionResolutionSignal
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        guard let requestedPhase = observation.requestedPhase,
              requestedPhase == .processing ||
                requestedPhase == .idle ||
                requestedPhase.isWaitingForApproval else {
            return LifecycleTransition(
                mutation: .none,
                reason: .invalidInteractionPhase
            )
        }

        let resolvedAt = observation.observedAt
        if let completedAt = next.completedAt, resolvedAt <= completedAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .interactionOlderThanCompletion
            )
        }

        if signal == .hookCompleted || signal == .transcriptCompleted,
           let lastHookEventAt = next.lastHookEventAt,
           resolvedAt < lastHookEventAt {
            return LifecycleTransition(
                mutation: .none,
                reason: .interactionOlderThanBoundary
            )
        }

        let previous = next
        let newerHookExists = (next.lastHookEventAt ?? .distantPast) > resolvedAt
        let preservesNewerActivity = signal == .deliveryFailed &&
            requestedPhase == .idle &&
            newerHookExists

        next.source = observation.source
        next.phase = preservesNewerActivity ? .processing : requestedPhase
        next.lastActivity = max(next.lastActivity, resolvedAt)
        next.lastHookEventAt = max(
            next.lastHookEventAt ?? .distantPast,
            resolvedAt
        )
        next.completedAt = nil

        guard next != previous else {
            return LifecycleTransition(
                mutation: .none,
                reason: .alreadyCurrent
            )
        }
        return LifecycleTransition(
            mutation: .update(next),
            reason: preservesNewerActivity
                ? .localFailurePreservedNewerActivity
                : .interactionResolved
        )
    }

    /// Interrupt rows can be delivered after a newer hook because both file
    /// and socket sources are asynchronous. Only an interrupt at or beyond the
    /// latest lifecycle boundary may tear down the visible running state.
    private static func reduceInterrupt(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        let latestBoundary = max(
            max(
                next.lastHookEventAt ?? .distantPast,
                next.completedAt ?? .distantPast
            ),
            next.turnStartedAt ?? .distantPast
        )
        guard observation.observedAt > latestBoundary else {
            return LifecycleTransition(
                mutation: .none,
                reason: .interruptOlderThanBoundary
            )
        }

        let previous = next
        next.phase = .idle
        next.lastActivity = max(next.lastActivity, observation.observedAt)
        next.lastHookEventAt = max(
            next.lastHookEventAt ?? .distantPast,
            observation.observedAt
        )
        next.completedAt = nil
        guard next != previous else {
            return LifecycleTransition(
                mutation: .none,
                reason: .alreadyCurrent
            )
        }
        return LifecycleTransition(
            mutation: .update(next),
            reason: .interruptAccepted
        )
    }

    /// SessionStore validates the exact PID before sending this observation,
    /// so a matching local process exit is an authoritative terminal boundary.
    private static func reduceProcessExit(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation
    ) -> LifecycleTransition {
        guard var next = current else {
            return LifecycleTransition(
                mutation: .none,
                reason: .sessionNotFound
            )
        }
        let previous = next
        next.phase = .ended
        next.lastActivity = max(next.lastActivity, observation.observedAt)
        next.lastHookEventAt = max(
            next.lastHookEventAt ?? .distantPast,
            observation.observedAt
        )
        next.completedAt = max(
            next.completedAt ?? .distantPast,
            observation.observedAt
        )
        guard next != previous else {
            return LifecycleTransition(
                mutation: .none,
                reason: .alreadyCurrent
            )
        }
        return LifecycleTransition(
            mutation: .update(next),
            reason: .processExitAccepted
        )
    }
}
