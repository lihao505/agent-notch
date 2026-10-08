import XCTest
@testable import Agent_Notch

final class ConversationParserIndexTests: XCTestCase {
    @discardableResult
    private func writeRollout(
        root: URL,
        date: Date,
        sessionId: String,
        cwd: String,
        destination: URL? = nil,
        atomically: Bool = false
    ) throws -> URL {
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
        let url = destination ?? directory.appendingPathComponent(
            "rollout-test-\(sessionId).jsonl"
        )
        try data.write(to: url, options: atomically ? .atomic : [])
        return url
    }

    func testColdIndexAndRecentDirectoryRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try writeRollout(
            root: root,
            date: Date(timeIntervalSince1970: 1_600_000_000),
            sessionId: "historical-session",
            cwd: "/tmp/historical"
        )
        let parser = ConversationParser(codexSessionsRoot: root)
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

    func testDiscoveryRepairsRotatedPathWithUnchangedDirectoryTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-rotated-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "rotated-discovery"
        let original = try writeRollout(
            root: root,
            date: Date(),
            sessionId: sessionId,
            cwd: root.path
        )
        let parser = ConversationParser(codexSessionsRoot: root)
        let threshold = Date().addingTimeInterval(-60)
        let before = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertTrue(before.contains { $0.sessionId == sessionId })

        let directory = original.deletingLastPathComponent()
        let directoryModifiedAt = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[
                .modificationDate
            ] as? Date
        )
        let replacement = directory.appendingPathComponent(
            "rollout-after-rotation-\(sessionId).jsonl"
        )
        try FileManager.default.moveItem(at: original, to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: directoryModifiedAt],
            ofItemAtPath: directory.path
        )

        let after = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertTrue(after.contains { $0.sessionId == sessionId })
    }

    func testAtomicReplacementRefreshesMetadataWithUnchangedSizeAndTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let url = try writeRollout(root: root, date: date,
                                   sessionId: "same-session", cwd: "/tmp/alpha")
        let parser = ConversationParser(codexSessionsRoot: root)
        let threshold = date.addingTimeInterval(-60)
        let before = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertEqual(before.first?.cwd, "/tmp/alpha")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let directory = url.deletingLastPathComponent()
        let directoryDate = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: directory.path
        )[.modificationDate] as? Date)

        try writeRollout(root: root, date: date, sessionId: "same-session",
                         cwd: "/tmp/bravo", destination: url, atomically: true)
        try FileManager.default.setAttributes([.modificationDate: modificationDate],
                                             ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: directoryDate],
                                             ofItemAtPath: directory.path)
        let replaced = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(replaced[.size] as? NSNumber, attributes[.size] as? NSNumber)
        XCTAssertNotEqual(replaced[.systemFileNumber] as? NSNumber,
                          attributes[.systemFileNumber] as? NSNumber)

        let after = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertEqual(after.map(\.sessionId), ["same-session"])
        XCTAssertEqual(after.first?.cwd, "/tmp/bravo")
    }

    func testReusedPathCannotAttributeReplacementToOldSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-reused-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let url = try writeRollout(root: root, date: date,
                                   sessionId: "before", cwd: "/tmp/before")
        let parser = ConversationParser(codexSessionsRoot: root)
        let threshold = date.addingTimeInterval(-60)
        let before = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertEqual(before.map(\.sessionId), ["before"])
        let directory = url.deletingLastPathComponent()
        let directoryDate = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: directory.path
        )[.modificationDate] as? Date)

        try writeRollout(root: root, date: date, sessionId: "after", cwd: "/tmp/after",
                         destination: url, atomically: true)
        try FileManager.default.setAttributes([.modificationDate: directoryDate],
                                             ofItemAtPath: directory.path)

        let after = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertEqual(after.map(\.sessionId), ["after"])
        XCTAssertEqual(after.first?.cwd, "/tmp/after")
        let oldLifecycle = await parser.codexTaskLifecycle(sessionId: "before")
        XCTAssertEqual(oldLifecycle, .missing)
        let newLifecycle = await parser.codexTaskLifecycle(sessionId: "after")
        guard case .active = newLifecycle else {
            return XCTFail("Replacement session was not indexed: \(newLifecycle)")
        }
    }

    func testSameInodeHeaderRewriteRefreshesWorkingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-header-rewrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let url = try writeRollout(root: root, date: date,
                                   sessionId: "rewrite", cwd: "/tmp/alpha")
        let parser = ConversationParser(codexSessionsRoot: root)
        let threshold = date.addingTimeInterval(-60)
        _ = await parser.discoverCodexTasks(modifiedAfter: threshold)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try writeRollout(root: root, date: date, sessionId: "rewrite",
                         cwd: "/tmp/bravo", destination: url)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(2)],
                                             ofItemAtPath: url.path)
        let rewritten = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber,
                       rewritten[.systemFileNumber] as? NSNumber)
        let after = await parser.discoverCodexTasks(modifiedAfter: threshold)
        XCTAssertEqual(after.first?.cwd, "/tmp/bravo")
    }

    func testOrdinaryAppendKeepsMetadataAndAdvancesLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-metadata-append-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let url = try writeRollout(root: root, date: date,
                                   sessionId: "append", cwd: "/tmp/append")
        let parser = ConversationParser(codexSessionsRoot: root)
        let threshold = date.addingTimeInterval(-60)
        let initial = await parser.discoverCodexTasks(modifiedAfter: threshold)
        guard case .active = initial.first?.lifecycle else {
            return XCTFail("Expected initial active turn")
        }
        let row: [String: Any] = ["type": "event_msg", "payload": ["type": "task_complete"]]
        var appended = try JSONSerialization.data(withJSONObject: row)
        appended.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        for _ in 0..<2 {
            let updated = await parser.discoverCodexTasks(modifiedAfter: threshold)
            XCTAssertEqual(updated.map(\.sessionId), ["append"])
            XCTAssertEqual(updated.first?.cwd, "/tmp/append")
            guard case .completed = updated.first?.lifecycle else {
                return XCTFail("Appended completion was not consumed")
            }
        }
    }
}
