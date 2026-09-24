import XCTest
@testable import Agent_Notch

final class CodexNativeConversationTests: XCTestCase {
    private let timestamp = "2026-09-24T08:30:00.000Z"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func metadata(sessionId: String, cwd: String) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": sessionId, "cwd": cwd]
        ]
    }

    private func itemCompleted(
        id: String,
        type: String,
        text: String,
        phase: String? = nil
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "type": type,
            "content": [[
                "type": type == "AgentMessage" ? "Text" : "text",
                "text": text
            ]]
        ]
        if let phase {
            item["phase"] = phase
        }
        return [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "item_completed", "item": item]
        ]
    }

    private func rolloutURL(root: URL, sessionId: String) throws -> URL {
        let directory = root
            .appendingPathComponent("2026")
            .appendingPathComponent("09")
            .appendingPathComponent("24")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(
            "rollout-test-\(sessionId).jsonl"
        )
    }

    private func writeLines(
        _ lines: [Data],
        to url: URL,
        trailingNewline: Bool = true,
        options: Data.WritingOptions = []
    ) throws {
        var data = Data()
        for (index, line) in lines.enumerated() {
            data.append(line)
            if index < lines.count - 1 || trailingNewline {
                data.append(0x0A)
            }
        }
        try data.write(to: url, options: options)
    }

    func testParsesCurrentAndLegacyVisibleMessagesOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "current-schema"
        let cwd = "/tmp/current-schema"
        let url = try rolloutURL(root: root, sessionId: sessionId)

        // This row intentionally includes spaces after JSON separators. The
        // fast prefilter must not depend on compact JSONSerialization output.
        let spacedUser = Data("""
        {"timestamp": "\(timestamp)", "type": "event_msg", "payload": {"type": "item_completed", "item": {"id": "user-one", "type": "UserMessage", "content": [{"type": "text", "text": "继续"}]}}}
        """.utf8)
        let assistantWithBlocks: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "item_completed",
                "item": [
                    "id": "agent-one",
                    "type": "AgentMessage",
                    "phase": "commentary",
                    "content": [
                        ["type": "Text", "text": "第一段"],
                        ["type": "Text", "text": "第二段"]
                    ]
                ]
            ]
        ]
        let duplicateID = itemCompleted(
            id: "agent-one",
            type: "AgentMessage",
            text: "不应重复",
            phase: "commentary"
        )
        let sameTextNewID = itemCompleted(
            id: "user-two",
            type: "UserMessage",
            text: "继续"
        )
        let hiddenAnalysis = itemCompleted(
            id: "analysis-one",
            type: "AgentMessage",
            text: "隐藏分析",
            phase: "analysis"
        )
        let commandItem: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "item_completed",
                "item": [
                    "id": "command-one",
                    "type": "CommandExecution",
                    "content": [["type": "text", "text": "secret output"]]
                ]
            ]
        ]
        let responseItem: [String: Any] = [
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "developer",
                "content": [["type": "input_text", "text": "injected"]]
            ]
        ]
        let legacy: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "phase": "final_answer",
                "message": "旧格式仍可见"
            ]
        ]

        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            spacedUser,
            try encoded(assistantWithBlocks),
            try encoded(duplicateID),
            try encoded(sameTextNewID),
            try encoded(hiddenAnalysis),
            try encoded(commandItem),
            try encoded(responseItem),
            try encoded(legacy)
        ], to: url)

        let parser = ConversationParser(codexSessionsRoot: root)
        let messages = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )

        XCTAssertEqual(Array(messages.prefix(3)).map(\.id), [
            "native-item-user-one",
            "native-item-agent-one",
            "native-item-user-two"
        ])
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(messages[3].id.hasPrefix("native-"))
        XCTAssertFalse(messages[3].id.hasPrefix("native-item-"))
        XCTAssertEqual(messages.map(\.role), [
            .user, .assistant, .user, .assistant
        ])
        XCTAssertEqual(messages.map(\.textContent), [
            "继续", "第一段\n第二段", "继续", "旧格式仍可见"
        ])
    }

    func testPartialRowIsRetriedAfterNewlineArrives() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "partial-row"
        let cwd = "/tmp/partial-row"
        let url = try rolloutURL(root: root, sessionId: sessionId)
        let row = try encoded(itemCompleted(
            id: "partial-user",
            type: "UserMessage",
            text: "完整后再显示"
        ))
        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            row
        ], to: url, trailingNewline: false)

        let parser = ConversationParser(codexSessionsRoot: root)
        let initial = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertTrue(initial.isEmpty)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let update = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(update.newMessages.map(\.textContent), ["完整后再显示"])
        XCTAssertEqual(update.newMessages.first?.id, "native-item-partial-user")
    }

    func testMetadataSnapshotDoesNotConsumeTranscriptCursor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "metadata-cursor"
        let cwd = "/tmp/metadata-cursor"
        let url = try rolloutURL(root: root, sessionId: sessionId)
        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            try encoded(itemCompleted(
                id: "still-visible",
                type: "AgentMessage",
                text: "不会被元数据读取吞掉",
                phase: "final_answer"
            ))
        ], to: url)

        let parser = ConversationParser(codexSessionsRoot: root)
        _ = await parser.parse(sessionId: sessionId, cwd: cwd)
        let update = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(update.newMessages.map(\.textContent), [
            "不会被元数据读取吞掉"
        ])
    }

    func testSameInodeRewriteResetsMessagesUsingAnchor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "rewrite-anchor"
        let cwd = "/tmp/rewrite-anchor"
        let url = try rolloutURL(root: root, sessionId: sessionId)
        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            try encoded(itemCompleted(
                id: "old-message",
                type: "UserMessage",
                text: "旧消息"
            ))
        ], to: url)

        let parser = ConversationParser(codexSessionsRoot: root)
        let initial = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(initial.map(\.textContent), ["旧消息"])

        var replacement = Data()
        for line in [
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            try encoded(itemCompleted(
                id: "new-message",
                type: "AgentMessage",
                text: "替换后只保留新消息，而且内容更长以越过旧游标",
                phase: "final_answer"
            ))
        ] {
            replacement.append(line)
            replacement.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()

        let reparsed = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(reparsed.map(\.id), ["native-item-new-message"])
        XCTAssertEqual(reparsed.map(\.textContent), [
            "替换后只保留新消息，而且内容更长以越过旧游标"
        ])
    }

    func testRotatedRolloutPathDoesNotReuseOldCursor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "rotated-rollout"
        let cwd = "/tmp/rotated-rollout"
        let originalURL = try rolloutURL(root: root, sessionId: sessionId)
        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            try encoded(itemCompleted(
                id: "before-rotation",
                type: "UserMessage",
                text: "轮换前"
            ))
        ], to: originalURL)

        let parser = ConversationParser(codexSessionsRoot: root)
        let initial = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(initial.map(\.textContent), ["轮换前"])

        let rotatedURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent("rollout-rotated-\(sessionId).jsonl")
        try FileManager.default.removeItem(at: originalURL)
        try writeLines([
            try encoded(metadata(sessionId: sessionId, cwd: cwd)),
            try encoded(itemCompleted(
                id: "after-rotation",
                type: "AgentMessage",
                text: "轮换后只保留新文件内容",
                phase: "final_answer"
            ))
        ], to: rotatedURL)

        let reparsed = await parser.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        XCTAssertEqual(reparsed.map(\.id), ["native-item-after-rotation"])
        XCTAssertEqual(reparsed.map(\.textContent), [
            "轮换后只保留新文件内容"
        ])
    }
}
