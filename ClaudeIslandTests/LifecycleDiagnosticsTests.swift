//
//  LifecycleDiagnosticsTests.swift
//  Agent Notch
//

import Darwin
import XCTest
@testable import Agent_Notch

private final class WatcherDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DiagnosticsWatcherInput] = []

    func record(_ input: DiagnosticsWatcherInput) {
        lock.lock()
        values.append(input)
        lock.unlock()
    }

    func latest(_ state: InterruptWatcherHealth) -> DiagnosticsWatcherInput? {
        lock.lock()
        defer { lock.unlock() }
        return values.last(where: { $0.state == state })
    }
}

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

    func testSessionStoreExposesOnlyLifecycleDiagnosticInputs() async throws {
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false)
        let secretSessionId = "raw-store-session-secret"
        let event = HookEvent(
            sessionId: secretSessionId,
            cwd: "/Users/private/secret-project",
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: Date().timeIntervalSince1970,
            source: "codex",
            pid: 12345,
            tty: "secret-tty",
            tool: "Bash",
            toolInput: ["command": AnyCodable("secret-command")],
            toolUseId: "secret-tool-id",
            notificationType: nil,
            message: "secret-message"
        )
        await store.process(.hookReceived(event))

        let input = await store.diagnosticsInput()
        XCTAssertEqual(input.sessions.count, 1)
        XCTAssertEqual(input.sessions.first?.phase, .processing)
        XCTAssertEqual(input.sessions.first?.hasProcess, true)
        XCTAssertFalse(input.decisions.isEmpty)

        let report = try DiagnosticsReportFormatter.json(
            LifecycleDiagnosticsAssembler.build(
                at: Date(), appVersion: "1.2.3", macOSMajorVersion: 15,
                sessions: input.sessions, decisions: input.decisions,
                bridge: DiagnosticsBridgeInput(
                    isRunning: false, socketExists: false, ownsSocket: false,
                    pendingPermissionSessionIds: [], lastEventAt: nil
                ), watchers: []
            )
        )
        for secret in [secretSessionId, "secret-project", "secret-tty", "secret-command", "secret-tool-id", "secret-message", "12345"] {
            XCTAssertFalse(report.contains(secret), "Report leaked: \(secret)")
        }
    }

    func testWatcherReportsWaitingWatchingAndStoppedWithoutFilePath() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("secret-transcript.jsonl")
        let recorder = WatcherDiagnosticsRecorder()
        let watcher = JSONLInterruptWatcher(
            sessionId: "raw-watcher-session",
            fileURL: fileURL,
            onDiagnosticsChanged: { recorder.record($0) }
        )

        func waitFor(_ state: InterruptWatcherHealth) -> DiagnosticsWatcherInput? {
            for _ in 0..<500 {
                if let input = recorder.latest(state) { return input }
                usleep(10_000)
            }
            return nil
        }

        watcher.start()
        XCTAssertNotNil(waitFor(.waitingForFile))
        try Data().write(to: fileURL)
        let watching = try XCTUnwrap(waitFor(.watching))
        XCTAssertNotNil(watching.lastOpenedAt)

        watcher.stop()
        XCTAssertNotNil(waitFor(.stopped))
        let report = try DiagnosticsReportFormatter.json(snapshot(watchers: [watching]))
        XCTAssertFalse(report.contains("raw-watcher-session"))
        XCTAssertFalse(report.contains("secret-transcript.jsonl"))
        XCTAssertFalse(report.contains(folder.path))
    }

    func testWatcherOpenFailureDistinguishesLateFileFromRecovery() {
        XCTAssertEqual(
            JSONLInterruptWatcher.openFailureState(fileExists: false, hasOpenedFile: false),
            .waitingForFile
        )
        XCTAssertEqual(
            JSONLInterruptWatcher.openFailureState(fileExists: true, hasOpenedFile: false),
            .recovering
        )
        XCTAssertEqual(
            JSONLInterruptWatcher.openFailureState(fileExists: false, hasOpenedFile: true),
            .recovering
        )
    }

    @MainActor
    func testManagerCachesWatcherHealthAcrossStopAndRestart() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = InterruptWatcherManager()
        defer { manager.stopAll() }
        let sessionId = "manager-raw-id"
        let firstFile = folder.appendingPathComponent("first.jsonl")
        let secondFile = folder.appendingPathComponent("second.jsonl")

        manager.startWatching(sessionId: sessionId, fileURL: firstFile)
        XCTAssertEqual(manager.diagnosticsInputs().first?.state, .waitingForFile)
        try Data().write(to: firstFile)
        let deadline = Date().addingTimeInterval(4)
        while manager.diagnosticsInputs().first?.state != .watching && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.diagnosticsInputs().first?.state, .watching)

        manager.stopWatching(sessionId: sessionId)
        XCTAssertEqual(manager.diagnosticsInputs().first?.state, .stopped)
        manager.startWatching(sessionId: sessionId, fileURL: secondFile)
        XCTAssertEqual(manager.diagnosticsInputs().first?.state, .waitingForFile)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.diagnosticsInputs().first?.state, .waitingForFile)
    }
}
