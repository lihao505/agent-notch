// Modified by lihao505 for Agent Notch, 2026.
// Delayed transcript events use isolated parser roots and no live hooks.
import Foundation
import XCTest
@testable import Agent_Notch

final class SessionStoreTerminalToolTests: XCTestCase {
    private let sessionID = "terminal-tool-fixture"
    private let cwd = "/tmp/agent-notch-terminal-tool-fixture"

    private func store() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-terminal-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SessionStore(
            persistenceEnabled: false, fileSyncEnabled: false,
            conversationParser: ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root),
            processTreeProvider: { _ in [:] }
        )
    }

    private func hook(_ event: String, at time: Date, pid: Int? = nil) -> SessionEvent {
        .hookReceived(HookEvent(
            sessionId: sessionID, cwd: cwd, event: event,
            status: event == "Stop" ? "waiting_for_input" : "processing",
            observedAt: time.timeIntervalSince1970, source: "claude",
            pid: pid, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
            notificationType: nil, message: nil
        ))
    }

    private func tool(_ id: String, at time: Date) -> ChatMessage {
        ChatMessage(id: "row-\(id)", role: .assistant, timestamp: time,
                    content: [.toolUse(ToolUseBlock(id: id, name: "Read", input: [:]))])
    }

    private func history(_ messages: [ChatMessage], completed: Set<String> = []) -> SessionEvent {
        .historyLoaded(
            sessionId: sessionID, messages: messages, completedTools: completed,
            toolResults: [:], structuredResults: [:],
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        )
    }

    private func status(_ id: String, in session: SessionState?) -> ToolStatus? {
        guard let item = session?.chatItems.first(where: { $0.id == id }),
              case .toolCall(let tool) = item.type else { return nil }
        return tool.status
    }

    func testLateHistoryCannotCreateRunningToolAfterStop() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(history([tool("missed-hook", at: start.addingTimeInterval(1))]))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(status("missed-hook", in: session), .interrupted)
        XCTAssertNotNil(session?.completedAt)
        XCTAssertEqual(session?.chatItems.count, 1, "Keep the historical row without a live spinner")
    }

    func testLateIncrementalToolCannotResumeInterruptedWork() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(.interruptDetected(sessionId: sessionID, observedAt: start.addingTimeInterval(2)))
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: sessionID, cwd: cwd,
            messages: [tool("interrupted-tool", at: start.addingTimeInterval(1))],
            isIncremental: true, completedToolIds: [], toolResults: [:], structuredResults: [:]
        )))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(status("interrupted-tool", in: session), .interrupted)
        XCTAssertNil(session?.completedAt, "Interrupt is not successful completion")
    }

    func testPreviousTurnToolStaysClosedWhileNewTurnToolRuns() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(hook("UserPromptSubmit", at: start.addingTimeInterval(3)))
        await store.process(history([
            tool("old-tool", at: start.addingTimeInterval(1)),
            tool("new-tool", at: start.addingTimeInterval(4))
        ]))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.completedAt)
        XCTAssertEqual(status("old-tool", in: session), .interrupted)
        XCTAssertEqual(status("new-tool", in: session), .running)
    }

    func testToolTimestampAloneCannotLeaveSpinnerOnCompletedSession() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(history([tool("unconfirmed-turn", at: start.addingTimeInterval(2.5))]))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(status("unconfirmed-turn", in: session), .interrupted)
        let boundary = try XCTUnwrap(session?.toolTracker.terminalBoundaryAt)
        XCTAssertEqual(boundary.timeIntervalSince1970, start.addingTimeInterval(2).timeIntervalSince1970,
                       accuracy: 0.001, "Do not extend the terminal boundary to receipt time")
    }

    func testCompletedResultKeepsSuccessAcrossTerminalBoundary() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(history([tool("finished", at: start.addingTimeInterval(1))], completed: ["finished"]))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(status("finished", in: session), .success)
        XCTAssertEqual(session?.phase, .waitingForInput)
    }

    func testClearReconciliationDoesNotForgetPreviousTerminalBoundary() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(.clearDetected(sessionId: sessionID))
        await store.process(hook("UserPromptSubmit", at: start.addingTimeInterval(3)))
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: sessionID, cwd: cwd,
            messages: [tool("old-after-clear", at: start.addingTimeInterval(1)),
                       tool("new-after-clear", at: start.addingTimeInterval(4))],
            isIncremental: false, completedToolIds: [], toolResults: [:], structuredResults: [:]
        )))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(status("old-after-clear", in: session), .interrupted)
        XCTAssertEqual(status("new-after-clear", in: session), .running)
        XCTAssertEqual(session?.phase, .processing)
    }

    func testRejectedInterruptCannotAdvanceToolBoundaryIntoNewTurn() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(2)))
        await store.process(hook("UserPromptSubmit", at: start.addingTimeInterval(4)))
        await store.process(.interruptDetected(sessionId: sessionID, observedAt: start.addingTimeInterval(3)))
        await store.process(history([tool("new-current", at: start.addingTimeInterval(4.5))]))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(status("new-current", in: session), .running)
        let boundary = try XCTUnwrap(session?.toolTracker.terminalBoundaryAt)
        XCTAssertEqual(boundary.timeIntervalSince1970, start.addingTimeInterval(2).timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testActiveSessionPersistenceRetainsSubsecondTerminalBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-terminal-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("active-sessions.json")
        let parser = ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root)
        let original = SessionStore(
            persistenceEnabled: true, fileSyncEnabled: false, conversationParser: parser,
            persistenceURL: snapshot, bridgeSnapshotDirectory: root.appendingPathComponent("bridge"),
            processTreeProvider: { _ in [:] }
        )
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let terminal = base.addingTimeInterval(0.8)
        let pid = Int(Foundation.ProcessInfo.processInfo.processIdentifier)
        await original.process(hook("UserPromptSubmit", at: base.addingTimeInterval(-1), pid: pid))
        await original.process(hook("Stop", at: terminal, pid: pid))
        await original.process(hook("UserPromptSubmit", at: base.addingTimeInterval(1.1), pid: pid))
        let restored = SessionStore(
            persistenceEnabled: true, fileSyncEnabled: false, conversationParser: parser,
            statusCheckIntervalSeconds: 30, persistenceURL: snapshot,
            bridgeSnapshotDirectory: root.appendingPathComponent("bridge")
        )
        await restored.startPeriodicStatusCheck()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await restored.session(for: sessionID) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await restored.stopPeriodicStatusCheck()
        await restored.process(history([
            tool("persisted-old", at: base.addingTimeInterval(0.5)),
            tool("persisted-new", at: base.addingTimeInterval(1.2))
        ]))
        let session = await restored.session(for: sessionID)
        let boundary = try XCTUnwrap(session?.toolTracker.terminalBoundaryAt)
        XCTAssertEqual(boundary.timeIntervalSince1970, terminal.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(status("persisted-old", in: session), .interrupted)
        XCTAssertEqual(status("persisted-new", in: session), .running)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.completedAt)
    }
}
