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

    private func toolHook(_ event: String, tool name: String, id: String, at time: Date) -> SessionEvent {
        .hookReceived(HookEvent(
            sessionId: sessionID, cwd: cwd, event: event, status: "processing",
            observedAt: time.timeIntervalSince1970, source: "claude",
            pid: nil, tty: nil, tool: name, toolInput: nil, toolUseId: id,
            notificationType: nil, message: nil
        ))
    }

    func testFailedSubagentContainerStopsTrackingWithoutCapturingLaterParentTool() async throws {
        for name in ["Task", "Agent"] {
            for completion in ["PostToolUse", "PostToolUseFailure"] {
                let store = try store()
                let start = Date().addingTimeInterval(-60)
                await store.process(hook("UserPromptSubmit", at: start))
                await store.process(toolHook("PreToolUse", tool: name, id: "child", at: start.addingTimeInterval(1)))
                await store.process(toolHook(completion, tool: name, id: "child", at: start.addingTimeInterval(2)))
                await store.process(toolHook("PreToolUse", tool: "Read", id: "parent-read", at: start.addingTimeInterval(3)))
                let session = await store.session(for: sessionID)
                XCTAssertEqual(status("child", in: session), completion == "PostToolUse" ? .success : .error)
                XCTAssertFalse(try XCTUnwrap(session).subagentState.hasActiveSubagent)
                XCTAssertEqual(status("parent-read", in: session), .running,
                               "The next parent tool must retain its own top-level row")
                XCTAssertEqual(session?.phase, .processing)
                XCTAssertNil(session?.completedAt)
            }
        }
    }

    func testFailedInnerToolUpdatesNestedStatusAndKeepsContainerActive() async throws {
        for completion in ["PostToolUse", "PostToolUseFailure"] {
            let store = try store()
            let start = Date().addingTimeInterval(-60)
            await store.process(hook("UserPromptSubmit", at: start))
            await store.process(toolHook("PreToolUse", tool: "Agent", id: "child", at: start.addingTimeInterval(1)))
            await store.process(toolHook("PreToolUse", tool: "Read", id: "inner-read", at: start.addingTimeInterval(2)))
            await store.process(toolHook(completion, tool: "Read", id: "inner-read", at: start.addingTimeInterval(3)))
            let stored = await store.session(for: sessionID)
            let session = try XCTUnwrap(stored)
            let context = try XCTUnwrap(session.subagentState.activeTasks["child"])
            XCTAssertEqual(context.subagentTools.first?.status, completion == "PostToolUse" ? .success : .error)
            let parent = try XCTUnwrap(session.chatItems.first(where: { $0.id == "child" }))
            guard case .toolCall(let tool) = parent.type else { return XCTFail("Missing Agent row") }
            XCTAssertEqual(tool.subagentTools.first?.status, completion == "PostToolUse" ? .success : .error)
            XCTAssertEqual(tool.status, .running)
            XCTAssertEqual(session.phase, .processing)
            XCTAssertNil(session.completedAt)
        }
    }

    func testFailedContainerDoesNotStopAnotherActiveSubagent() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(toolHook("PreToolUse", tool: "Agent", id: "survivor", at: start.addingTimeInterval(1)))
        await store.process(toolHook("PreToolUse", tool: "Task", id: "failed", at: start.addingTimeInterval(2)))
        await store.process(toolHook("PostToolUseFailure", tool: "Task", id: "failed", at: start.addingTimeInterval(3)))
        await store.process(toolHook("PreToolUse", tool: "Read", id: "survivor-read", at: start.addingTimeInterval(4)))
        let stored = await store.session(for: sessionID)
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(Set(session.subagentState.activeTasks.keys), ["survivor"])
        XCTAssertEqual(session.subagentState.activeTasks["survivor"]?.subagentTools.map(\.id), ["survivor-read"])
        XCTAssertEqual(status("failed", in: session), .error)
        XCTAssertEqual(status("survivor", in: session), .running)
        XCTAssertEqual(session.phase, .processing)
    }

    private func nestedStatuses(in session: SessionState?, parentID: String = "child") throws -> [String: ToolStatus] {
        let parent = try XCTUnwrap(session?.chatItems.first(where: { $0.id == parentID }))
        guard case .toolCall(let tool) = parent.type else {
            XCTFail("Missing container tool")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: tool.subagentTools.map { ($0.id, $0.status) })
    }

    func testTerminalTurnClosesNestedRunningToolsAndPreservesKnownResults() async throws {
        for interrupts in [false, true] {
            let store = try store()
            let start = Date().addingTimeInterval(-60)
            await store.process(hook("UserPromptSubmit", at: start))
            await store.process(toolHook("PreToolUse", tool: "Agent", id: "child", at: start.addingTimeInterval(1)))
            for (offset, id) in ["done", "failed", "dangling"].enumerated() {
                await store.process(toolHook("PreToolUse", tool: "Read", id: id, at: start.addingTimeInterval(Double(offset + 2))))
            }
            await store.process(toolHook("PostToolUse", tool: "Read", id: "done", at: start.addingTimeInterval(5)))
            await store.process(toolHook("PostToolUseFailure", tool: "Read", id: "failed", at: start.addingTimeInterval(6)))
            if interrupts {
                await store.process(.interruptDetected(sessionId: sessionID, observedAt: start.addingTimeInterval(7)))
            } else {
                await store.process(hook("Stop", at: start.addingTimeInterval(7)))
            }
            let session = await store.session(for: sessionID)
            XCTAssertEqual(try nestedStatuses(in: session), ["done": .success, "failed": .error, "dangling": .interrupted])
            XCTAssertEqual(session?.phase, interrupts ? .idle : .waitingForInput)
            XCTAssertFalse(try XCTUnwrap(session).subagentState.hasActiveSubagent)
        }
    }

    func testTerminalTurnClosesNestedPlaceholderEvenWhenParentAlreadySucceeded() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(toolHook("PreToolUse", tool: "Agent", id: "child", at: start.addingTimeInterval(1)))
        await store.process(toolHook("PreToolUse", tool: "Read", id: "missing-result", at: start.addingTimeInterval(2)))
        await store.process(toolHook("PostToolUse", tool: "Agent", id: "child", at: start.addingTimeInterval(3)))
        await store.process(hook("Stop", at: start.addingTimeInterval(4)))
        let session = await store.session(for: sessionID)
        XCTAssertEqual(status("child", in: session), .success)
        XCTAssertEqual(try nestedStatuses(in: session)["missing-result"], .interrupted)
    }

    func testLateSubagentFileCannotRestoreRunningToolsAcrossTerminalBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notch-nested-file-\(UUID().uuidString)")
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let directory = root.appendingPathComponent(projectDir).appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let start = Date().addingTimeInterval(-60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [[String: Any]] = [
            ["timestamp": formatter.string(from: start.addingTimeInterval(2)), "message": ["content": [
                ["type": "tool_use", "id": "file-done", "name": "Read", "input": [:]],
                ["type": "tool_use", "id": "file-dangling", "name": "Read", "input": [:]]
            ]]],
            ["message": ["content": [["type": "tool_result", "tool_use_id": "file-done", "content": "fixture result"]]]]
        ]
        let data = try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0A)
        }
        try data.write(to: directory.appendingPathComponent("agent-file-fixture.jsonl"))
        let parser = ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root)
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                 conversationParser: parser, processTreeProvider: { _ in [:] })
        let result = ToolResultData.task(TaskResult(agentId: "file-fixture", status: "running", content: "",
                                                  prompt: nil, totalDurationMs: nil, totalTokens: nil, totalToolUseCount: nil))
        let info = ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                                    lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        let update = SessionEvent.fileUpdated(FileUpdatePayload(
            sessionId: sessionID, cwd: cwd, messages: [], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: ["child": result],
            conversationInfoSnapshot: info
        ))
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(toolHook("PreToolUse", tool: "Agent", id: "child", at: start.addingTimeInterval(1)))
        await store.process(update)
        let active = await store.session(for: sessionID)
        XCTAssertEqual(try nestedStatuses(in: active), ["file-done": .success, "file-dangling": .running])
        await store.process(hook("Stop", at: start.addingTimeInterval(3)))
        await store.process(update)
        let stopped = await store.session(for: sessionID)
        XCTAssertEqual(try nestedStatuses(in: stopped), ["file-done": .success, "file-dangling": .interrupted])
        XCTAssertEqual(stopped?.phase, .waitingForInput)
        // A genuine next turn may run its own tools, but loading the old
        // parent's file must not undo that parent's terminal placeholder.
        await store.process(hook("UserPromptSubmit", at: start.addingTimeInterval(4)))
        await store.process(toolHook("PreToolUse", tool: "Read", id: "next-tool", at: start.addingTimeInterval(5)))
        await store.process(update)
        let resumed = await store.session(for: sessionID)
        XCTAssertEqual(try nestedStatuses(in: resumed)["file-dangling"], .interrupted)
        XCTAssertEqual(status("next-tool", in: resumed), .running)
        XCTAssertEqual(resumed?.phase, .processing)

        var refreshedData = data
        refreshedData.append(try JSONSerialization.data(withJSONObject: [
            "timestamp": formatter.string(from: start.addingTimeInterval(6)),
            "message": ["content": [["type": "tool_use", "id": "current-inner", "name": "Read", "input": [:]]]]
        ]))
        refreshedData.append(0x0A)
        try refreshedData.write(to: directory.appendingPathComponent("agent-file-fixture.jsonl"))
        await store.process(toolHook("PreToolUse", tool: "Agent", id: "fresh-child", at: start.addingTimeInterval(6)))
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: sessionID, cwd: cwd, messages: [], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: ["child": result, "fresh-child": result],
            conversationInfoSnapshot: info
        )))
        let current = await store.session(for: sessionID)
        XCTAssertEqual(try nestedStatuses(in: current)["current-inner"], .interrupted,
                       "A later file row is not permission to reopen a closed container")
        XCTAssertEqual(try nestedStatuses(in: current, parentID: "fresh-child"),
                       ["file-done": .success, "file-dangling": .interrupted, "current-inner": .running],
                       "An active container must keep its post-boundary tools running")
        XCTAssertEqual(status("fresh-child", in: current), .running)
        XCTAssertEqual(current?.phase, .processing)
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
