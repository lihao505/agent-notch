import XCTest
@testable import Agent_Notch

final class ConversationParserIndexTests: XCTestCase {
    private func writeRollout(
        root: URL,
        date: Date,
        sessionId: String,
        cwd: String
    ) throws {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let directory = root
            .appendingPathComponent(String(format: "%04d", components.year!))
            .appendingPathComponent(String(format: "%02d", components.month!))
            .appendingPathComponent(String(format: "%02d", components.day!))
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rows: [[String: Any]] = [
            [
                "timestamp": timestamp,
                "type": "session_meta",
                "payload": ["id": sessionId, "cwd": cwd]
            ],
            [
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": ["type": "task_started"]
            ]
        ]
        let data = try rows.map {
            try JSONSerialization.data(withJSONObject: $0)
        }.reduce(into: Data()) { result, row in
            result.append(row)
            result.append(0x0A)
        }
        try data.write(
            to: directory.appendingPathComponent(
                "rollout-test-\(sessionId).jsonl"
            )
        )
    }

    func testColdIndexAndRecentDirectoryRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let previous = getenv("AGENT_NOTCH_CODEX_SESSIONS_ROOT")
            .map { String(cString: $0) }
        setenv("AGENT_NOTCH_CODEX_SESSIONS_ROOT", root.path, 1)
        defer {
            if let previous {
                setenv("AGENT_NOTCH_CODEX_SESSIONS_ROOT", previous, 1)
            } else {
                unsetenv("AGENT_NOTCH_CODEX_SESSIONS_ROOT")
            }
        }

        try writeRollout(
            root: root,
            date: Date(timeIntervalSince1970: 1_600_000_000),
            sessionId: "historical-session",
            cwd: "/tmp/historical"
        )
        let parser = ConversationParser()
        var observations = await parser.discoverCodexTasks(
            modifiedAfter: Date().addingTimeInterval(-60)
        )
        XCTAssertTrue(observations.contains {
            $0.sessionId == "historical-session"
        })

        try writeRollout(
            root: root,
            date: Date(),
            sessionId: "new-session",
            cwd: "/tmp/new"
        )
        observations = await parser.discoverCodexTasks(
            modifiedAfter: Date().addingTimeInterval(-60)
        )
        XCTAssertTrue(observations.contains {
            $0.sessionId == "new-session"
        })
    }
}
