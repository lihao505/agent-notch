// Modified by lihao505 for Agent Notch, 2026.
// Isolated clear boundaries and delayed store results; no live agent files.
import Foundation
import XCTest
@testable import Agent_Notch

private actor HistoryReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var started = false

    func pause() async {
        started = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

final class ConversationClearGenerationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let id = "clear-generation-fixture"
        var cwd: String { root.path }
        var file: URL {
            root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ".", with: "-"))
                .appendingPathComponent("\(id).jsonl")
        }
        var parser: ConversationParser {
            ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-notch-clear-generation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try Data().write(to: file)
        }

        func append(_ texts: [String], role: String = "user", escapeSlashes: Bool = false) throws {
            var data = Data()
            for text in texts {
                let content: Any = role == "assistant" ? [["type": "text", "text": text]] : text
                data.append(try JSONSerialization.data(withJSONObject: [
                    "type": role, "uuid": UUID().uuidString,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "message": ["role": role, "content": content]
                ], options: escapeSlashes ? [] : [.withoutEscapingSlashes]))
                data.append(0x0A)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    private let clear = "<command-name>/clear</command-name>"

    func testInitialBatchContainsOnlyMessagesAfterLatestClear() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.append(["old", clear, "middle", clear, "current"])
        let result = await fixture.parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertEqual(result.newMessages.map(\.textContent), ["current"])
        XCTAssertEqual(result.allMessages.map(\.textContent), ["current"])
        XCTAssertTrue(result.clearDetected)
    }

    func testIncrementalBatchDropsRowsBeforeClearAndConsumesFlagOnce() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parser = fixture.parser
        try fixture.append(["initial"])
        _ = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        try fixture.append(["old-in-this-batch", clear, "current"])
        let result = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertEqual(result.newMessages.map(\.textContent), ["current"])
        XCTAssertTrue(result.clearDetected)
        let unchanged = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertFalse(unchanged.clearDetected)
        XCTAssertTrue(unchanged.newMessages.isEmpty)
    }

    func testUnconsumedClearSurvivesAnotherAppendRead() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parser = fixture.parser
        try fixture.append(["initial"])
        _ = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        try fixture.append([clear])
        _ = await parser.parseFullConversation(sessionId: fixture.id, cwd: fixture.cwd)
        try fixture.append(["current"])
        let result = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertTrue(result.clearDetected)
        XCTAssertEqual(result.allMessages.map(\.textContent), ["current"])
    }

    func testEscapedJSONSlashStillIdentifiesUserClear() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.append(["old", clear, "current"], escapeSlashes: true)
        let result = await fixture.parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertEqual(result.allMessages.map(\.textContent), ["current"])
        XCTAssertEqual(result.newMessages.map(\.textContent), ["current"])
        XCTAssertTrue(result.clearDetected)
    }

    func testAssistantQuotingCommandTagCannotClearConversation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.append(["keep"])
        try fixture.append([clear], role: "assistant")
        let result = await fixture.parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertEqual(result.allMessages.map(\.textContent), ["keep", clear])
        XCTAssertFalse(result.clearDetected)
    }

    func testHistorySnapshotMetadataUsesPostClearConversation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.append(["old", clear, "current"])
        let snapshot = await fixture.parser.parseHistorySnapshot(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertEqual(snapshot.messages.map(\.textContent), ["current"])
        XCTAssertEqual(snapshot.conversationInfo.firstUserMessage, "current")
        XCTAssertEqual(snapshot.conversationInfo.lastMessage, "current")
        XCTAssertTrue(snapshot.clearDetected)
    }

    private func hook(_ fixture: Fixture, at date: Date) -> SessionEvent {
        .hookReceived(HookEvent(
            sessionId: fixture.id, cwd: fixture.cwd, event: "UserPromptSubmit", status: "processing",
            observedAt: date.timeIntervalSince1970, source: "claude", pid: nil, tty: nil,
            tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil, message: nil
        ))
    }

    private func message(_ text: String) -> ChatMessage {
        ChatMessage(id: text, role: .user, timestamp: Date().addingTimeInterval(-60), content: [.text(text)])
    }

    private func history(_ fixture: Fixture, text: String, generation: UUID) -> SessionEvent {
        .historyLoaded(
            sessionId: fixture.id, messages: [message(text)], completedTools: [], toolResults: [:],
            structuredResults: [:], conversationInfo: ConversationInfo(
                summary: text, lastMessage: text, lastMessageRole: "user", lastToolName: nil,
                firstUserMessage: text, lastUserMessageDate: nil
            ), expectedGeneration: generation
        )
    }

    func testPreClearHistoryCannotOverwriteCurrentHistoryOrMetadata() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                 conversationParser: fixture.parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        let oldSession = await store.session(for: fixture.id)
        let old = try XCTUnwrap(oldSession?.historyGeneration)
        await store.process(.clearDetected(sessionId: fixture.id))
        let currentSession = await store.session(for: fixture.id)
        let current = try XCTUnwrap(currentSession?.historyGeneration)
        await store.process(history(fixture, text: "current", generation: current))
        await store.process(history(fixture, text: "old", generation: old))
        let session = await store.session(for: fixture.id)
        XCTAssertNotEqual(old, current)
        XCTAssertEqual(session?.chatItems.map(\.id), ["current-text-0"])
        XCTAssertEqual(session?.conversationInfo.summary, "current")
    }

    func testPreClearIncrementalResultCannotMutateCurrentHistory() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                 conversationParser: fixture.parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        let oldSession = await store.session(for: fixture.id)
        let old = try XCTUnwrap(oldSession?.historyGeneration)
        await store.process(.clearDetected(sessionId: fixture.id))
        let currentSession = await store.session(for: fixture.id)
        let current = try XCTUnwrap(currentSession?.historyGeneration)
        await store.process(history(fixture, text: "current", generation: current))
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: fixture.id, cwd: fixture.cwd, messages: [message("old")], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: [:], expectedGeneration: old
        )))
        let session = await store.session(for: fixture.id)
        XCTAssertEqual(session?.chatItems.map(\.id), ["current-text-0"])
        XCTAssertEqual(session?.conversationInfo.summary, "current")
    }

    func testRemovedAndRecreatedSessionRejectsPreviousHistoryResult() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                 conversationParser: fixture.parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        let oldSession = await store.session(for: fixture.id)
        let old = try XCTUnwrap(oldSession?.historyGeneration)
        await store.process(.sessionEnded(sessionId: fixture.id))
        await store.process(hook(fixture, at: Date().addingTimeInterval(-5)))
        await store.process(history(fixture, text: "removed-incarnation", generation: old))
        let session = await store.session(for: fixture.id)
        XCTAssertTrue(session?.chatItems.isEmpty == true)
        XCTAssertNil(session?.conversationInfo.summary)
    }

    func testProductionHistoryLoadRemovesRecentPreClearText() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                 conversationParser: fixture.parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        let initial = await store.session(for: fixture.id)
        let generation = try XCTUnwrap(initial?.historyGeneration)
        await store.process(.historyLoaded(
            sessionId: fixture.id,
            messages: [ChatMessage(id: "recent-old", role: .user, timestamp: Date(), content: [.text("old")])],
            completedTools: [], toolResults: [:], structuredResults: [:],
            conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                                               lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil),
            expectedGeneration: generation
        ))
        try fixture.append(["old", clear, "current"])
        await store.process(.loadHistory(sessionId: fixture.id, cwd: fixture.cwd))
        let session = await store.session(for: fixture.id)
        let text = session?.chatItems.compactMap { item -> String? in
            if case .user(let text) = item.type { return text }
            return nil
        }
        XCTAssertEqual(text, ["current"])
        XCTAssertFalse(session?.needsClearReconciliation ?? true)
        XCTAssertFalse(session?.needsFullHistorySync ?? true)
    }

    func testFirstSyncRecoversAlreadyConsumedParserCursor() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parser = fixture.parser
        try fixture.append(["current"])
        _ = await parser.parseIncremental(sessionId: fixture.id, cwd: fixture.cwd)
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: true, conversationParser: parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        let deadline = Date().addingTimeInterval(3)
        var session: SessionState?
        while Date() < deadline {
            session = await store.session(for: fixture.id)
            if session?.needsFullHistorySync == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.process(.sessionEnded(sessionId: fixture.id))
        let text = session?.chatItems.compactMap { item -> String? in
            if case .user(let text) = item.type { return text }
            return nil
        }
        XCTAssertEqual(text, ["current"])
        XCTAssertFalse(session?.needsFullHistorySync ?? true)
    }

    func testSuspendedProductionLoadAndSyncCannotCrossClearBoundary() async throws {
        for fullSync in [false, true] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.append(["old"])
            let parser = fixture.parser
            let gate = HistoryReadGate()
            let store = SessionStore(
                persistenceEnabled: false, fileSyncEnabled: false, conversationParser: parser,
                historySnapshotProvider: { id, cwd in
                    let snapshot = await parser.parseHistorySnapshot(sessionId: id, cwd: cwd)
                    await gate.pause()
                    return snapshot
                }
            )
            await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
            let load = Task<UUID?, Never> {
                if fullSync {
                    await store.process(.syncHistory(sessionId: fixture.id, cwd: fixture.cwd))
                    return nil
                }
                return await store.loadHistoryResult(sessionId: fixture.id, cwd: fixture.cwd)
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let didSuspend = await gate.started
            await store.process(.clearDetected(sessionId: fixture.id))
            let current = await store.session(for: fixture.id)
            if let generation = current?.historyGeneration {
                await store.process(history(fixture, text: "current", generation: generation))
            }
            await gate.open()
            let loadedGeneration = await load.value
            if !fullSync { XCTAssertNil(loadedGeneration, "Discarded history is not a successful load") }
            let session = await store.session(for: fixture.id)
            XCTAssertTrue(didSuspend, "Exercise the actual suspension boundary")
            XCTAssertEqual(session?.chatItems.map(\.id), ["current-text-0"])
            XCTAssertEqual(session?.conversationInfo.summary, "current")
        }
    }

    @MainActor
    func testHistoryManagerDoesNotReuseLoadedCacheAfterClear() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parser = fixture.parser
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false, conversationParser: parser)
        let manager = ChatHistoryManager(sessionStore: store, conversationParser: parser)
        await store.process(hook(fixture, at: Date().addingTimeInterval(-10)))
        try fixture.append(["old"])
        let first = await manager.loadFromFile(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertTrue(first)
        try fixture.append([clear, "current"])
        await store.process(.clearDetected(sessionId: fixture.id))
        // Detecting a source clear may rotate again during this load. Report
        // the committed generation as loaded, not a false loading failure.
        let second = await manager.loadFromFile(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertTrue(second)
        let currentLoad = await manager.loadFromFile(sessionId: fixture.id, cwd: fixture.cwd)
        XCTAssertTrue(currentLoad)
        let session = await store.session(for: fixture.id)
        let text = session?.chatItems.compactMap { item -> String? in
            if case .user(let text) = item.type { return text }
            return nil
        }
        XCTAssertEqual(text, ["current"])
        XCTAssertTrue(manager.isLoaded(sessionId: fixture.id))
    }

    @MainActor
    func testManagerFullSyncStillRefreshesExistingHookToolInput() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parser = fixture.parser
        let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false, conversationParser: parser)
        let manager = ChatHistoryManager(sessionStore: store, conversationParser: parser)
        await store.process(.hookReceived(HookEvent(
            sessionId: fixture.id, cwd: fixture.cwd, event: "PreToolUse", status: "running_tool",
            observedAt: Date().addingTimeInterval(-1).timeIntervalSince1970, source: "claude",
            pid: nil, tty: nil, tool: "Read", toolInput: ["file_path": AnyCodable("old")],
            toolUseId: "tool", notificationType: nil, message: nil
        )))
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "tool-row",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "tool", "name": "Read", "input": ["file_path": "new"]]
            ]]
        ])
        data.append(0x0A)
        try data.write(to: fixture.file)
        await manager.syncFromFile(sessionId: fixture.id, cwd: fixture.cwd)
        let session = await store.session(for: fixture.id)
        guard let item = session?.chatItems.first(where: { $0.id == "tool" }),
              case .toolCall(let tool) = item.type else { return XCTFail("Expected existing hook tool") }
        XCTAssertEqual(tool.input["file_path"], "new")
        XCTAssertEqual(tool.status, .running)
        XCTAssertEqual(session?.chatItems.count, 1)
    }

}
