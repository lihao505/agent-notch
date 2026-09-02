import XCTest
@testable import Agent_Notch

final class SessionStoreLifecycleTests: XCTestCase {
    private func hook(
        sessionId: String,
        event: String,
        status: String,
        observedAt: Date,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/agent-notch-state-tests",
            event: event,
            status: status,
            observedAt: observedAt.timeIntervalSince1970,
            source: "codex",
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    func testOrderedLifecycleApprovalCompletionAndResume() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "state-sequence-\(UUID().uuidString)"
        let now = Date()

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: now.addingTimeInterval(-5)
        )))
        var storedSession = await store.session(for: sessionId)
        var session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: now.addingTimeInterval(-4),
            tool: "Bash",
            toolUseId: "tool-1"
        )))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.activePermission?.toolUseId, "tool-1")

        await store.process(.permissionApproved(
            sessionId: sessionId,
            toolUseId: "tool-1"
        ))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)

        let completionAt = now.addingTimeInterval(-2)
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            observedAt: completionAt
        )))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .waitingForInput)
        XCTAssertEqual(
            try XCTUnwrap(session.completedAt).timeIntervalSince1970,
            completionAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        // A delayed tool-start from the completed turn must not revive it.
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            observedAt: now.addingTimeInterval(-3),
            tool: "Read",
            toolUseId: "stale-tool"
        )))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .waitingForInput)
        XCTAssertEqual(
            try XCTUnwrap(session.completedAt).timeIntervalSince1970,
            completionAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        // A genuinely newer prompt starts a new lifecycle generation.
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: now
        )))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertNil(session.completedAt)
    }

    func testDuplicateStopIsIdempotent() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "duplicate-stop-\(UUID().uuidString)"
        let observedAt = Date()
        let stop = hook(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            observedAt: observedAt
        )

        await store.process(.hookReceived(stop))
        await store.process(.hookReceived(stop))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .waitingForInput)
        XCTAssertEqual(
            try XCTUnwrap(session.completedAt).timeIntervalSince1970,
            observedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
