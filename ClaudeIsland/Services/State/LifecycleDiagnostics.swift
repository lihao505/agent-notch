//
//  LifecycleDiagnostics.swift
//  Agent Notch
//
//  Privacy-minimized values for explaining lifecycle decisions. Raw session
//  identities exist only in the short-lived assembly input, never the report.
//

import Foundation

nonisolated enum DiagnosticsHealth: String, Codable, Equatable, Sendable {
    case healthy
    case attention
    case unavailable
}

nonisolated enum InterruptWatcherHealth: String, Codable, Equatable, Sendable {
    case waitingForFile
    case watching
    case recovering
    case stopped
}

nonisolated struct DiagnosticsSessionInput: Sendable {
    let sessionId: String
    let source: AgentSource
    let phase: LifecyclePhaseKind
    let hasProcess: Bool
    let waitingForPermission: Bool
    let lastActivity: Date
}

nonisolated struct DiagnosticsDecisionInput: Sendable {
    let sessionId: String
    let trace: LifecycleTraceEntry
}

nonisolated struct DiagnosticsWatcherInput: Sendable {
    let sessionId: String
    let state: InterruptWatcherHealth
    let retryCount: Int
    let lastOpenedAt: Date?
    let lastEventAt: Date?
    let lastRetryAt: Date?
}

nonisolated struct DiagnosticsBridgeInput: Sendable {
    let isRunning: Bool
    let socketExists: Bool
    let ownsSocket: Bool
    let pendingPermissionSessionIds: [String]
    let lastEventAt: Date?
}

nonisolated struct SessionDiagnosticsSummary: Codable, Equatable, Sendable {
    let label: String
    let source: String
    let phase: LifecyclePhaseKindValue
    let hasProcess: Bool
    let waitingForPermission: Bool
    let lastActivityAgeMs: Int
}

/// A separate Codable value keeps the reducer's phase enum free of report
/// concerns, and prevents a PermissionContext from entering the export.
nonisolated enum LifecyclePhaseKindValue: String, Codable, Equatable, Sendable {
    case idle, processing, waitingForInput, waitingForApproval, compacting, ended

    init(_ phase: LifecyclePhaseKind) {
        switch phase {
        case .idle: self = .idle
        case .processing: self = .processing
        case .waitingForInput: self = .waitingForInput
        case .waitingForApproval: self = .waitingForApproval
        case .compacting: self = .compacting
        case .ended: self = .ended
        }
    }
}

nonisolated struct BridgeDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let isRunning: Bool
    let socketExists: Bool
    let ownsSocket: Bool
    let pendingPermissionCount: Int
    let pendingBySession: [String: Int]
    let lastEventAgeMs: Int?
}

nonisolated struct InterruptWatcherDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let label: String
    let state: InterruptWatcherHealth
    let retryCount: Int
    let lastOpenedAgeMs: Int?
    let lastEventAgeMs: Int?
    let lastRetryAgeMs: Int?
}

nonisolated struct LifecycleDecisionDiagnostics: Codable, Equatable, Sendable {
    let label: String
    let origin: String
    let evidence: String
    let reason: String
    let accepted: Bool
    let didMutate: Bool
    let previousPhase: LifecyclePhaseKindValue?
    let nextPhase: LifecyclePhaseKindValue?
    let observedAgeMs: Int
    let receivedAgeMs: Int
    let deliveryLatencyMs: Int
}

nonisolated struct LifecycleDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let macOSMajorVersion: Int
    let health: DiagnosticsHealth
    let sessions: [SessionDiagnosticsSummary]
    let bridge: BridgeDiagnosticsSnapshot
    let watchers: [InterruptWatcherDiagnosticsSnapshot]
    let decisions: [LifecycleDecisionDiagnostics]
}

nonisolated enum LifecycleDiagnosticsAssembler {
    static func build(
        at now: Date,
        appVersion: String,
        macOSMajorVersion: Int,
        sessions: [DiagnosticsSessionInput],
        decisions: [DiagnosticsDecisionInput],
        bridge: DiagnosticsBridgeInput,
        watchers: [DiagnosticsWatcherInput]
    ) -> LifecycleDiagnosticsSnapshot {
        let sortedSessions = sessions.sorted {
            if $0.source.rawValue != $1.source.rawValue {
                return $0.source.rawValue < $1.source.rawValue
            }
            if $0.lastActivity != $1.lastActivity {
                return $0.lastActivity > $1.lastActivity
            }
            return $0.sessionId < $1.sessionId
        }
        var seenActiveIds = Set<String>()
        let orderedSessions = sortedSessions.filter { seenActiveIds.insert($0.sessionId).inserted }
        let activeIds = orderedSessions.map(\.sessionId)
        let historicalIds = Set(decisions.map(\.sessionId) +
            watchers.map(\.sessionId) + bridge.pendingPermissionSessionIds)
            .subtracting(activeIds)
            .sorted()
        let labels = Dictionary(uniqueKeysWithValues:
            (activeIds + historicalIds).enumerated().map { index, id in
                (id, "S\(index + 1)")
            }
        )

        let safeSessions = orderedSessions.compactMap { session -> SessionDiagnosticsSummary? in
            guard let label = labels[session.sessionId] else { return nil }
            return SessionDiagnosticsSummary(
                label: label,
                source: session.source.rawValue,
                phase: LifecyclePhaseKindValue(session.phase),
                hasProcess: session.hasProcess,
                waitingForPermission: session.waitingForPermission,
                lastActivityAgeMs: ageMs(since: session.lastActivity, at: now)
            )
        }

        var pendingBySession: [String: Int] = [:]
        for sessionId in bridge.pendingPermissionSessionIds {
            if let label = labels[sessionId] {
                pendingBySession[label, default: 0] += 1
            }
        }
        let safeBridge = BridgeDiagnosticsSnapshot(
            isRunning: bridge.isRunning,
            socketExists: bridge.socketExists,
            ownsSocket: bridge.ownsSocket,
            pendingPermissionCount: bridge.pendingPermissionSessionIds.count,
            pendingBySession: pendingBySession,
            lastEventAgeMs: bridge.lastEventAt.map { ageMs(since: $0, at: now) }
        )

        let labelOrder = Dictionary(uniqueKeysWithValues:
            (activeIds + historicalIds).enumerated().map { ($0.element, $0.offset) }
        )
        let safeWatchers = watchers.sorted {
            labelOrder[$0.sessionId, default: .max] < labelOrder[$1.sessionId, default: .max]
        }.compactMap { watcher -> InterruptWatcherDiagnosticsSnapshot? in
            guard let label = labels[watcher.sessionId] else { return nil }
            return InterruptWatcherDiagnosticsSnapshot(
                label: label,
                state: watcher.state,
                retryCount: max(0, watcher.retryCount),
                lastOpenedAgeMs: watcher.lastOpenedAt.map { ageMs(since: $0, at: now) },
                lastEventAgeMs: watcher.lastEventAt.map { ageMs(since: $0, at: now) },
                lastRetryAgeMs: watcher.lastRetryAt.map { ageMs(since: $0, at: now) }
            )
        }

        var safeDecisions = decisions.compactMap { input -> LifecycleDecisionDiagnostics? in
            guard let label = labels[input.sessionId] else { return nil }
            let trace = input.trace
            return LifecycleDecisionDiagnostics(
                label: label,
                origin: trace.origin.rawValue,
                evidence: evidenceKind(trace.evidence),
                reason: trace.reason.rawValue,
                accepted: trace.accepted,
                didMutate: trace.didMutate,
                previousPhase: trace.previousPhase.map(LifecyclePhaseKindValue.init),
                nextPhase: trace.nextPhase.map(LifecyclePhaseKindValue.init),
                observedAgeMs: ageMs(since: trace.observedAt, at: now),
                receivedAgeMs: ageMs(since: trace.receivedAt, at: now),
                deliveryLatencyMs: ageMs(since: trace.observedAt, at: trace.receivedAt)
            )
        }
        safeDecisions.sort { lhs, rhs in
            if lhs.receivedAgeMs != rhs.receivedAgeMs {
                return lhs.receivedAgeMs < rhs.receivedAgeMs
            }
            if lhs.observedAgeMs != rhs.observedAgeMs {
                return lhs.observedAgeMs < rhs.observedAgeMs
            }
            if lhs.label != rhs.label { return lhs.label < rhs.label }
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            if lhs.evidence != rhs.evidence { return lhs.evidence < rhs.evidence }
            if lhs.reason != rhs.reason { return lhs.reason < rhs.reason }
            if lhs.accepted != rhs.accepted { return lhs.accepted && !rhs.accepted }
            if lhs.didMutate != rhs.didMutate { return lhs.didMutate && !rhs.didMutate }
            if lhs.previousPhase != rhs.previousPhase {
                return (lhs.previousPhase?.rawValue ?? "") < (rhs.previousPhase?.rawValue ?? "")
            }
            return (lhs.nextPhase?.rawValue ?? "") < (rhs.nextPhase?.rawValue ?? "")
        }

        let health: DiagnosticsHealth
        if !bridge.isRunning || !bridge.socketExists || !bridge.ownsSocket {
            health = .unavailable
        } else if safeWatchers.contains(where: { $0.state == .recovering || $0.state == .waitingForFile }) {
            health = .attention
        } else {
            health = .healthy
        }

        return LifecycleDiagnosticsSnapshot(
            schemaVersion: 1,
            appVersion: appVersion,
            macOSMajorVersion: max(0, macOSMajorVersion),
            health: health,
            sessions: safeSessions,
            bridge: safeBridge,
            watchers: safeWatchers,
            decisions: Array(safeDecisions.prefix(100))
        )
    }

    private static func ageMs(since date: Date, at now: Date) -> Int {
        let milliseconds = max(0, now.timeIntervalSince(date) * 1_000)
        guard milliseconds.isFinite else { return 0 }
        return Int(min(milliseconds, Double(Int.max)))
    }

    private static func evidenceKind(_ evidence: LifecycleEvidence) -> String {
        switch evidence {
        case .active: return "active"
        case .completed: return "completed"
        case .missing: return "missing"
        case .unknown: return "unknown"
        case .hook(let signal): return "hook.\(signal.rawValue)"
        case .interactionResolution(let signal): return "interaction.\(signal.rawValue)"
        case .interrupt: return "interrupt"
        case .processExited: return "processExited"
        }
    }
}

nonisolated enum DiagnosticsReportFormatter {
    static func json(_ snapshot: LifecycleDiagnosticsSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string + "\n"
    }
}
