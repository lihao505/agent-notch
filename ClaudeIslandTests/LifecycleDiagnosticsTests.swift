//
//  LifecycleDiagnosticsTests.swift
//  Agent Notch
//

import XCTest
@testable import Agent_Notch

final class LifecycleDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func trace(
        sessionId: String,
        receivedAt: Date,
        reason: LifecycleTransitionReason = .alreadyCurrent,
        requestedPhase: SessionPhase? = nil
    ) -> LifecycleTraceEntry {
        let observation = SessionLifecycleObservation(
            sessionId: sessionId,
            cwd: "/Users/private/project-secret",
            source: .codex,
            origin: .hook,
            evidence: .hook(.active),
            requestedPhase: requestedPhase,
            observedAt: receivedAt.addingTimeInterval(-0.25),
            receivedAt: receivedAt
        )
        return LifecycleTraceEntry(
            observation: observation,
            previous: nil,
            transition: LifecycleTransition(mutation: .none, reason: reason)
        )
    }

    private func snapshot(
        sessions: [DiagnosticsSessionInput] = [],
        decisions: [DiagnosticsDecisionInput] = [],
        watchers: [DiagnosticsWatcherInput] = [],
        bridge: DiagnosticsBridgeInput? = nil
    ) -> LifecycleDiagnosticsSnapshot {
        LifecycleDiagnosticsAssembler.build(
            at: now,
            appVersion: "1.2.3",
            macOSMajorVersion: 15,
            sessions: sessions,
            decisions: decisions,
            bridge: bridge ?? DiagnosticsBridgeInput(
                isRunning: true,
                socketExists: true,
                ownsSocket: true,
                pendingPermissionSessionIds: [],
                lastEventAt: nil
            ),
            watchers: watchers
        )
    }

    func testReportExcludesRawIdentityPathAndPermissionContent() throws {
        let sessionId = "raw-session-secret"
        let context = PermissionContext(
            toolUseId: "private-tool-id",
            toolName: "Bash",
            toolInput: ["command": AnyCodable("中文提示词 private-command")],
            receivedAt: now
        )
        let diagnostics = snapshot(
            sessions: [DiagnosticsSessionInput(
                sessionId: sessionId,
                source: .codex,
                phase: .waitingForApproval,
                hasProcess: true,
                waitingForPermission: true,
                lastActivity: now.addingTimeInterval(-2)
            )],
            decisions: [DiagnosticsDecisionInput(
                sessionId: sessionId,
                trace: trace(
                    sessionId: sessionId,
                    receivedAt: now.addingTimeInterval(-1),
                    reason: .hookOlderThanBoundary,
                    requestedPhase: .waitingForApproval(context)
                )
            )],
            watchers: [DiagnosticsWatcherInput(
                sessionId: sessionId,
                state: .watching,
                retryCount: 0,
                lastOpenedAt: now.addingTimeInterval(-3),
                lastEventAt: nil,
                lastRetryAt: nil
            )],
            bridge: DiagnosticsBridgeInput(
                isRunning: true,
                socketExists: true,
                ownsSocket: true,
                pendingPermissionSessionIds: [sessionId],
                lastEventAt: now.addingTimeInterval(-1)
            )
        )
        let report = try DiagnosticsReportFormatter.json(diagnostics)

        XCTAssertEqual(diagnostics.sessions.map(\.label), ["S1"])
        XCTAssertEqual(diagnostics.bridge.pendingBySession, ["S1": 1])
        XCTAssertEqual(diagnostics.decisions.first?.evidence, "hook.active")
        XCTAssertEqual(diagnostics.decisions.first?.deliveryLatencyMs, 250)
        XCTAssertFalse(try XCTUnwrap(diagnostics.decisions.first).accepted)
        XCTAssertEqual(diagnostics.sessions.first?.lastActivityAgeMs, 2_000)
        XCTAssertEqual(report, try DiagnosticsReportFormatter.json(diagnostics))
        for secret in [sessionId, "private-tool-id", "private-command", "中文提示词", "/Users/private", "project-secret"] {
            XCTAssertFalse(report.contains(secret), "Report leaked: \(secret)")
        }
        XCTAssertFalse(report.contains("1000000"), "Report must not contain an absolute activity timestamp")
    }

    func testStableLabelsOrderingAndDuplicateSessionInput() throws {
        let older = DiagnosticsSessionInput(
            sessionId: "raw-older", source: .codex, phase: .processing,
            hasProcess: false, waitingForPermission: false,
            lastActivity: now.addingTimeInterval(-3)
        )
        let newer = DiagnosticsSessionInput(
            sessionId: "raw-newer", source: .codex, phase: .processing,
            hasProcess: true, waitingForPermission: false,
            lastActivity: now.addingTimeInterval(-1)
        )
        let first = snapshot(sessions: [older, newer, newer])
        let second = snapshot(sessions: [newer, older])

        XCTAssertEqual(first.sessions.count, 2)
        XCTAssertEqual(first.sessions.map(\.label), ["S1", "S2"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(try DiagnosticsReportFormatter.json(first), try DiagnosticsReportFormatter.json(second))
    }

    func testDecisionsAreNewestFirstAndBoundedToOneHundred() {
        let decisions = (0..<105).map { index in
            DiagnosticsDecisionInput(
                sessionId: "raw-id",
                trace: trace(sessionId: "raw-id", receivedAt: now.addingTimeInterval(-Double(index)))
            )
        }
        let diagnostics = snapshot(decisions: decisions.reversed())

        XCTAssertEqual(diagnostics.decisions.count, 100)
        XCTAssertEqual(diagnostics.decisions.first?.receivedAgeMs, 0)
        XCTAssertEqual(diagnostics.decisions.last?.receivedAgeMs, 99_000)
        XCTAssertTrue(diagnostics.decisions.allSatisfy(\.accepted))
    }

    func testSameTimeDecisionsHaveInputIndependentReportOrder() throws {
        let accepted = DiagnosticsDecisionInput(
            sessionId: "raw-id",
            trace: trace(sessionId: "raw-id", receivedAt: now, reason: .alreadyCurrent)
        )
        let rejected = DiagnosticsDecisionInput(
            sessionId: "raw-id",
            trace: trace(sessionId: "raw-id", receivedAt: now, reason: .hookOlderThanBoundary)
        )
        let forward = try DiagnosticsReportFormatter.json(snapshot(decisions: [accepted, rejected]))
        let reverse = try DiagnosticsReportFormatter.json(snapshot(decisions: [rejected, accepted]))

        XCTAssertEqual(forward, reverse)
    }

    func testHealthAggregatesBridgeAndWatcherState() {
        let watcher = DiagnosticsWatcherInput(
            sessionId: "raw-id", state: .recovering, retryCount: -1,
            lastOpenedAt: nil, lastEventAt: nil, lastRetryAt: nil
        )
        XCTAssertEqual(snapshot().health, .healthy)
        XCTAssertEqual(snapshot(watchers: [watcher]).health, .attention)
        XCTAssertEqual(snapshot(watchers: [watcher]).watchers.first?.retryCount, 0)
        XCTAssertEqual(snapshot(bridge: DiagnosticsBridgeInput(
            isRunning: false, socketExists: false, ownsSocket: false,
            pendingPermissionSessionIds: [], lastEventAt: nil
        )).health, .unavailable)
    }
}
