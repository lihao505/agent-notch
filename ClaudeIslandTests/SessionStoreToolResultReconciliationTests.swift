// Modified by lihao505 for Agent Notch, 2026.
// Late result reconciliation uses isolated roots, never live agent files.
import Foundation
import XCTest
@testable import Agent_Notch

final class SessionStoreToolResultReconciliationTests: XCTestCase {
    private let id = "tool-result-fixture"
    private let cwd = "/tmp/agent-notch-tool-result-fixture"

    private func store() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-tool-results-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                            conversationParser: ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root),
                            processTreeProvider: { _ in [:] })
    }

    private func hook(_ event: String, at time: Date, toolID: String? = nil) -> SessionEvent {
        .hookReceived(HookEvent(
            sessionId: id, cwd: cwd, event: event,
            status: event == "Stop" ? "waiting_for_input" :
                (event == "PermissionRequest" ? "waiting_for_approval" : "processing"),
            observedAt: time.timeIntervalSince1970, source: "claude", pid: nil, tty: nil,
            tool: toolID == nil ? nil : "Read", toolInput: nil, toolUseId: toolID,
            notificationType: nil, message: nil
        ))
    }

    private func message(_ toolID: String, at time: Date) -> ChatMessage {
        ChatMessage(id: "row-\(toolID)", role: .assistant, timestamp: time,
                    content: [.toolUse(ToolUseBlock(id: toolID, name: "Read", input: ["file_path": "fixture"]))])
    }

    private func result(_ text: String, at time: Date, error: Bool = false) -> ConversationParser.ToolResult {
        ConversationParser.ToolResult(content: text, stdout: nil, stderr: nil, isError: error, observedAt: time)
    }

    private func file(_ messages: [ChatMessage] = [], toolID: String,
                      result: ConversationParser.ToolResult, incremental: Bool = true,
                      structured: ToolResultData? = nil) -> SessionEvent {
        .fileUpdated(FileUpdatePayload(sessionId: id, cwd: cwd, messages: messages, isIncremental: incremental,
                                      completedToolIds: [toolID], toolResults: [toolID: result],
                                      structuredResults: structured.map { [toolID: $0] } ?? [:]))
    }

    private func history(_ messages: [ChatMessage], toolID: String? = nil,
                         result: ConversationParser.ToolResult? = nil) -> SessionEvent {
        .historyLoaded(sessionId: id, messages: messages, completedTools: toolID.map { [$0] } ?? [],
                       toolResults: toolID.flatMap { key in result.map { [key: $0] } } ?? [:],
                       structuredResults: [:], conversationInfo: ConversationInfo(
                        summary: nil, lastMessage: nil, lastMessageRole: nil,
                        lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil))
    }

    private func tool(_ toolID: String, in state: SessionState?) -> ToolCallItem? {
        guard let item = state?.chatItems.first(where: { $0.id == toolID }),
              case .toolCall(let tool) = item.type else { return nil }
        return tool
    }

    func testResultOnlyIncrementAfterStopCorrectsPlaceholderWithoutResuming() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(history([message("old", at: start.addingTimeInterval(1))]))
        await store.process(hook("Stop", at: start.addingTimeInterval(3)))
        let before = await store.session(for: id)
        XCTAssertEqual(tool("old", in: before)?.status, .interrupted)
        await store.process(file(toolID: "old", result: result("actual output", at: start.addingTimeInterval(2))))
        let after = await store.session(for: id)
        XCTAssertEqual(tool("old", in: after)?.status, .success)
        XCTAssertEqual(tool("old", in: after)?.result, "actual output")
        XCTAssertEqual(after?.phase, .waitingForInput)
        XCTAssertEqual(after?.completedAt, before?.completedAt)
        XCTAssertEqual(after?.toolTracker.terminalBoundaryAt, before?.toolTracker.terminalBoundaryAt)
        XCTAssertTrue(after?.toolTracker.inProgress.isEmpty == true)
    }

    func testPreviousTurnResultKeepsNewTurnToolAndPhaseActive() async throws {
        for incremental in [true, false] {
            let store = try store()
            let start = Date().addingTimeInterval(-60)
            await store.process(hook("UserPromptSubmit", at: start))
            await store.process(history([message("old", at: start.addingTimeInterval(1))]))
            await store.process(hook("Stop", at: start.addingTimeInterval(3)))
            await store.process(hook("UserPromptSubmit", at: start.addingTimeInterval(4)))
            // Refreshing old tool inputs must not erase its provisional closure.
            await store.process(.fileUpdated(FileUpdatePayload(
                sessionId: id, cwd: cwd,
                messages: [message("old", at: start.addingTimeInterval(1)), message("new", at: start.addingTimeInterval(5))],
                isIncremental: incremental, completedToolIds: [], toolResults: [:], structuredResults: [:])))
            await store.process(file(toolID: "old", result: result("failed read", at: start.addingTimeInterval(2), error: true)))
            let state = await store.session(for: id)
            XCTAssertEqual(tool("old", in: state)?.status, .error)
            XCTAssertEqual(tool("old", in: state)?.result, "failed read")
            XCTAssertEqual(tool("new", in: state)?.status, .running)
            XCTAssertEqual(state?.phase, .processing)
            XCTAssertNil(state?.completedAt)
        }
    }

    func testFullHistoryRefreshEnrichesExistingCompletedTool() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("PreToolUse", at: start, toolID: "finished"))
        await store.process(hook("PostToolUse", at: start.addingTimeInterval(1), toolID: "finished"))
        await store.process(history([message("finished", at: start)], toolID: "finished",
                                    result: result("native text", at: start.addingTimeInterval(1))))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("finished", in: state)?.status, .success)
        XCTAssertEqual(tool("finished", in: state)?.result, "native text")
        XCTAssertEqual(state?.chatItems.count, 1)
    }

    func testFirstCompletedHistoryUsesErrorAndActualInterruptionStatuses() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(history([message("failed", at: start)], toolID: "failed",
                                    result: result("file missing", at: start.addingTimeInterval(1), error: true)))
        await store.process(history([message("cancelled", at: start)], toolID: "cancelled",
                                    result: result("Interrupted by user", at: start.addingTimeInterval(1), error: true)))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("failed", in: state)?.status, .error)
        XCTAssertEqual(tool("failed", in: state)?.result, "file missing")
        XCTAssertEqual(tool("cancelled", in: state)?.status, .interrupted)
        XCTAssertNil(tool("cancelled", in: state)?.result)
    }

    func testDirectLateResultCorrectsProvisionalInterruptAndRetainsStructure() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(history([message("closed", at: start.addingTimeInterval(1))]))
        await store.process(.interruptDetected(sessionId: id, observedAt: start.addingTimeInterval(3)))
        let structured = ToolResultData.generic(GenericResult(rawContent: "details", rawData: nil))
        await store.process(.toolCompleted(sessionId: id, toolUseId: "closed", result: ToolCompletionResult(
            status: .success, result: "output", structuredResult: structured, observedAt: start.addingTimeInterval(2))))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("closed", in: state)?.status, .success)
        XCTAssertEqual(tool("closed", in: state)?.structuredResult, structured)
        XCTAssertEqual(state?.phase, .idle)
        XCTAssertNil(state?.completedAt)
    }

    func testHookCompletionCanReceiveMissingDetailsButConflictsDoNotReplaceFacts() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("PreToolUse", at: start, toolID: "finished"))
        await store.process(hook("PostToolUse", at: start.addingTimeInterval(1), toolID: "finished"))
        let structured = ToolResultData.generic(GenericResult(rawContent: "first detail", rawData: nil))
        await store.process(file(toolID: "finished", result: result("first", at: start.addingTimeInterval(1))))
        await store.process(file(toolID: "finished", result: result("duplicate", at: start.addingTimeInterval(2)), structured: structured))
        await store.process(file(toolID: "finished", result: result("contradictory failure", at: start.addingTimeInterval(3), error: true)))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("finished", in: state)?.status, .success)
        XCTAssertEqual(tool("finished", in: state)?.result, "first")
        XCTAssertEqual(tool("finished", in: state)?.structuredResult, structured)
    }

    func testObservedInterruptionIsNotOverwrittenByConflictingSuccess() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(history([message("cancelled", at: start)], toolID: "cancelled",
                                    result: result("Interrupted by user", at: start.addingTimeInterval(1), error: true)))
        await store.process(file(toolID: "cancelled", result: result("conflicting success", at: start.addingTimeInterval(2))))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("cancelled", in: state)?.status, .interrupted)
        XCTAssertNil(tool("cancelled", in: state)?.result)
    }

    func testUntimestampedHistoryResultCannotConsumePendingApproval() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("PermissionRequest", at: start, toolID: "pending"))
        await store.process(history([message("pending", at: start)], toolID: "pending",
                                    result: ConversationParser.ToolResult(content: "old", stdout: nil, stderr: nil, isError: false)))
        let state = await store.session(for: id)
        XCTAssertEqual(state?.activePermission?.toolUseId, "pending")
        XCTAssertEqual(tool("pending", in: state)?.status, .waitingForApproval)
        XCTAssertNil(tool("pending", in: state)?.result)
    }

    func testCompletionWithoutMatchingHistoryDoesNotCreateToolOrPhase() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("UserPromptSubmit", at: start))
        await store.process(hook("Stop", at: start.addingTimeInterval(3)))
        await store.process(file(toolID: "unknown", result: result("late", at: start.addingTimeInterval(2))))
        let state = await store.session(for: id)
        XCTAssertTrue(state?.chatItems.isEmpty == true)
        XCTAssertEqual(state?.phase, .waitingForInput)
    }

    func testLateExactHookCorrectsProvisionalClosureWithoutResumingTurn() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("PreToolUse", at: start, toolID: "closed"))
        await store.process(hook("Stop", at: start.addingTimeInterval(3)))
        let before = await store.session(for: id)
        await store.process(hook("PostToolUseFailure", at: start.addingTimeInterval(2), toolID: "closed"))
        let state = await store.session(for: id)
        XCTAssertEqual(tool("closed", in: state)?.status, .error)
        XCTAssertEqual(state?.phase, .waitingForInput)
        XCTAssertEqual(state?.completedAt, before?.completedAt)
    }

    func testTranscriptCompletionClosesExactMissingHookTrackerOnly() async throws {
        let store = try store()
        let start = Date().addingTimeInterval(-60)
        await store.process(hook("PreToolUse", at: start, toolID: "finished"))
        await store.process(hook("PreToolUse", at: start.addingTimeInterval(1), toolID: "other"))
        let before = await store.session(for: id)
        XCTAssertNotNil(before?.toolTracker.inProgress["finished"])
        await store.process(file(toolID: "finished", result: result("done", at: start.addingTimeInterval(2))))
        let state = await store.session(for: id)
        XCTAssertNil(state?.toolTracker.inProgress["finished"])
        XCTAssertNotNil(state?.toolTracker.inProgress["other"])
        XCTAssertEqual(tool("finished", in: state)?.status, .success)
        XCTAssertEqual(tool("other", in: state)?.status, .running)
        XCTAssertNil(state?.completedAt)
    }

    func testFullHistoryAndResultOnlyIncrementRespectApprovalTimestampAndParallelFIFO() async throws {
        for fullHistory in [false, true] {
            for fresh in [false, true] {
                let store = try store()
                let start = Date().addingTimeInterval(-60)
                await store.process(hook("PermissionRequest", at: start, toolID: "first"))
                await store.process(hook("PermissionRequest", at: start.addingTimeInterval(1), toolID: "second"))
                let completion = result("exact result", at: start.addingTimeInterval(fresh ? 2 : -1))
                if fullHistory {
                    await store.process(history([message("first", at: start)], toolID: "first", result: completion))
                } else {
                    await store.process(file(toolID: "first", result: completion))
                }
                let state = await store.session(for: id)
                XCTAssertEqual(state?.pendingInteractions.toolUseIds, fresh ? ["second"] : ["first", "second"])
                XCTAssertEqual(state?.activePermission?.toolUseId, fresh ? "second" : "first")
                XCTAssertEqual(tool("first", in: state)?.status, fresh ? .success : .waitingForApproval)
                XCTAssertEqual(tool("first", in: state)?.result, fresh ? "exact result" : nil)
                XCTAssertEqual(tool("second", in: state)?.status, .waitingForApproval)
                XCTAssertNil(tool("second", in: state)?.result)
                XCTAssertNil(state?.completedAt)
            }
        }
    }
}
