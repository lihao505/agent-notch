import XCTest
@testable import Agent_Notch

final class SessionStoreLifecycleTests: XCTestCase {
    private func hook(
        sessionId: String,
        event: String,
        status: String,
        observedAt: Date,
        tool: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        notificationType: String? = nil
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
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: notificationType,
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
            toolUseId: "tool-1",
            resolvedAt: now.addingTimeInterval(-3.5)
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
        XCTAssertFalse(session.toolTracker.hasSeen("stale-tool"))
        XCTAssertFalse(session.chatItems.contains { $0.id == "stale-tool" })

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

    func testCurrentSessionEndRemovesSessionWithoutResurrection() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "session-end-\(UUID().uuidString)"
        let now = Date()

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: now.addingTimeInterval(-1)
        )))
        let activeSession = await store.session(for: sessionId)
        XCTAssertNotNil(activeSession)

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "SessionEnd",
            status: "ended",
            observedAt: now
        )))

        let removedSession = await store.session(for: sessionId)
        XCTAssertNil(removedSession)
    }

    func testStaleSessionEndCannotRemoveResumedSession() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "stale-session-end-\(UUID().uuidString)"
        let now = Date()

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: now
        )))
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "SessionEnd",
            status: "ended",
            observedAt: now.addingTimeInterval(-1)
        )))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertNil(session.completedAt)
    }

    func testInformationalNotificationDoesNotSuppressCompletion() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "neutral-notification-\(UUID().uuidString)"
        let now = Date()

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            observedAt: now.addingTimeInterval(-3)
        )))
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "Notification",
            status: "notification",
            observedAt: now.addingTimeInterval(-1),
            notificationType: "auth_success"
        )))

        var storedSession = await store.session(for: sessionId)
        var session = try XCTUnwrap(storedSession)
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
    }

    func testDeliveredApprovalRejectsOlderCompletion() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "approval-boundary-\(UUID().uuidString)"
        let now = Date()

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: now.addingTimeInterval(-3),
            tool: "Bash",
            toolUseId: "approval-tool"
        )))
        await store.process(.permissionApproved(
            sessionId: sessionId,
            toolUseId: "approval-tool",
            resolvedAt: now
        ))
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            observedAt: now.addingTimeInterval(-1)
        )))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertNil(session.completedAt)
    }

    func testAnsweredQuestionCannotBeResurrectedByOlderRequest() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "question-boundary-\(UUID().uuidString)"
        let now = Date()
        let question = hook(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "waiting_for_approval",
            observedAt: now.addingTimeInterval(-2),
            tool: "AskUserQuestion",
            toolUseId: "question-tool"
        )

        await store.process(.hookReceived(question))
        await store.process(.permissionApproved(
            sessionId: sessionId,
            toolUseId: "question-tool",
            resolvedAt: now.addingTimeInterval(-1)
        ))
        await store.process(.hookReceived(question))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertNil(session.activePermission)
    }

    func testParallelInteractionsRemainFIFOAndSurviveToolActivity() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "parallel-interactions-\(UUID().uuidString)"
        let now = Date()
        let questionInput: [String: AnyCodable] = [
            "prompt": AnyCodable("Choose a target")
        ]
        let bashInput: [String: AnyCodable] = [
            "command": AnyCodable("swift test")
        ]

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "waiting_for_approval",
            observedAt: now.addingTimeInterval(-5),
            tool: "AskUserQuestion",
            toolUseId: "question-1",
            toolInput: questionInput
        )))
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: now.addingTimeInterval(-4),
            tool: "Bash",
            toolUseId: "bash-2",
            toolInput: bashInput
        )))

        var storedSession = await store.session(for: sessionId)
        var session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.pendingInteractions.toolUseIds, [
            "question-1", "bash-2"
        ])
        XCTAssertEqual(session.activePermission?.toolUseId, "question-1")
        XCTAssertEqual(
            session.activePermission?.toolInput?["prompt"]?.value as? String,
            "Choose a target"
        )

        // A parallel tool can start while the question remains unanswered. It
        // must not hide the oldest request or change the visible phase.
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            observedAt: now.addingTimeInterval(-3),
            tool: "Read",
            toolUseId: "parallel-read"
        )))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.activePermission?.toolUseId, "question-1")

        await store.process(.permissionApproved(
            sessionId: sessionId,
            toolUseId: "question-1",
            resolvedAt: now.addingTimeInterval(-2)
        ))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.pendingInteractions.toolUseIds, ["bash-2"])
        XCTAssertEqual(session.activePermission?.toolUseId, "bash-2")
        XCTAssertEqual(
            session.activePermission?.toolInput?["command"]?.value as? String,
            "swift test"
        )

        await store.process(.toolCompleted(
            sessionId: sessionId,
            toolUseId: "bash-2",
            result: ToolCompletionResult(
                status: .success,
                result: nil,
                structuredResult: nil
            )
        ))
        storedSession = await store.session(for: sessionId)
        session = try XCTUnwrap(storedSession)
        XCTAssertTrue(session.pendingInteractions.toolUseIds.isEmpty)
        XCTAssertEqual(session.phase, .processing)
    }

    func testDirectPermissionCreatesTrackedPlaceholder() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "direct-permission-\(UUID().uuidString)"
        let observedAt = Date().addingTimeInterval(-1)

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: observedAt,
            tool: "Bash",
            toolUseId: "direct-tool",
            toolInput: ["command": AnyCodable("echo ready")]
        )))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(
            try XCTUnwrap(session.activePermission?.receivedAt)
                .timeIntervalSince1970,
            observedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        guard let item = session.chatItems.first(where: {
            $0.id == "direct-tool"
        }), case .toolCall(let tool) = item.type else {
            return XCTFail("Expected a tracked permission placeholder")
        }
        XCTAssertEqual(tool.status, .waitingForApproval)
        XCTAssertEqual(tool.input["command"], "echo ready")
    }

    func testLateApprovalCallbackCannotEraseNewerCompletion() async throws {
        let store = SessionStore(
            persistenceEnabled: false,
            fileSyncEnabled: false
        )
        let sessionId = "late-approval-\(UUID().uuidString)"
        let now = Date()
        let requestAt = now.addingTimeInterval(-3)
        let clickAt = now.addingTimeInterval(-2)
        let completionAt = now.addingTimeInterval(-1)

        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: requestAt,
            tool: "Bash",
            toolUseId: "late-tool"
        )))
        await store.process(.hookReceived(hook(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            observedAt: completionAt
        )))

        // The socket response can finish after the Stop even though the click
        // that initiated it happened first. Its callback is no longer live and
        // must not clear the newer completion boundary.
        await store.process(.permissionApproved(
            sessionId: sessionId,
            toolUseId: "late-tool",
            resolvedAt: clickAt
        ))

        let storedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .waitingForInput)
        XCTAssertEqual(
            try XCTUnwrap(session.completedAt).timeIntervalSince1970,
            completionAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertTrue(session.pendingInteractions.toolUseIds.isEmpty)
    }
}
