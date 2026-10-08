import Foundation
import XCTest
@testable import Agent_Notch

final class SessionStoreProcessMetadataTests: XCTestCase {
    /// Models the production short-lived cache: an ordinary query returns the
    /// last tree, while forced refresh advances to the next controlled snapshot.
    private final class TopologyProbe: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var requests: [Bool] = []
        nonisolated(unsafe) private var refreshed = 0
        private let snapshots: [[Int: Agent_Notch.ProcessInfo]]

        nonisolated init(_ snapshots: [[Int: Agent_Notch.ProcessInfo]]) {
            self.snapshots = snapshots
        }

        nonisolated func read(_ forceRefresh: Bool) -> [Int: Agent_Notch.ProcessInfo] {
            lock.lock()
            defer { lock.unlock() }
            requests.append(forceRefresh)
            if forceRefresh { refreshed += 1 }
            return snapshots[min(max(0, refreshed - 1), snapshots.count - 1)]
        }

        nonisolated var flags: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func tree(pid: Int = 101, tty: String = "ttys000", tmux: Bool = true) -> [Int: Agent_Notch.ProcessInfo] {
        [pid: Agent_Notch.ProcessInfo(pid: pid, ppid: 10, command: "claude", tty: tty),
         10: Agent_Notch.ProcessInfo(pid: 10, ppid: 1, command: tmux ? "tmux" : "Terminal", tty: nil)]
    }

    private func store(probe: TopologyProbe) -> SessionStore {
        SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                     externalLifecycleEffectsEnabled: false,
                     processTreeProvider: { probe.read($0) })
    }

    private func hook(at time: Date, pid: Int?, tty: String?, event: String = "UserPromptSubmit") -> HookEvent {
        HookEvent(sessionId: "process-metadata-fixture", cwd: "/tmp/agent-notch-metadata-tests",
                  event: event, status: "processing", observedAt: time.timeIntervalSince1970,
                  source: "claude", pid: pid, tty: tty, tool: nil, toolInput: nil,
                  toolUseId: nil, notificationType: nil, message: nil)
    }

    func testMissingPIDKeepsKnownProcessAndDoesNotRescanOnReturn() async throws {
        let probe = TopologyProbe([tree()])
        let store = store(probe: probe)
        let now = Date().addingTimeInterval(-10)
        await store.process(.hookReceived(hook(at: now, pid: 101, tty: "/dev/ttys000")))
        await store.process(.hookReceived(hook(at: now.addingTimeInterval(1), pid: nil, tty: nil)))
        var stored = await store.session(for: "process-metadata-fixture")
        var session = try XCTUnwrap(stored)
        XCTAssertEqual(session.pid, 101)
        XCTAssertEqual(session.tty, "ttys000")
        XCTAssertTrue(session.isInTmux)
        for offset in 2...10 {
            await store.process(.hookReceived(hook(at: now.addingTimeInterval(Double(offset)),
                                                  pid: 101, tty: "/dev/ttys000")))
        }
        stored = await store.session(for: "process-metadata-fixture")
        session = try XCTUnwrap(stored)
        XCTAssertEqual(session.pid, 101)
        XCTAssertEqual(probe.flags, [true])
    }

    func testTTYChangeForcesRefreshEvenWhenPIDIsOmitted() async throws {
        for pid: Int? in [101, nil] {
            let probe = TopologyProbe([tree(), tree(tty: "ttys001", tmux: false)])
            let store = store(probe: probe)
            let now = Date().addingTimeInterval(-2)
            await store.process(.hookReceived(hook(at: now, pid: 101, tty: "/dev/ttys000")))
            await store.process(.hookReceived(hook(at: now.addingTimeInterval(1),
                                                  pid: pid, tty: "/dev/ttys001")))
            let stored = await store.session(for: "process-metadata-fixture")
            let session = try XCTUnwrap(stored)
            XCTAssertEqual(session.pid, 101)
            XCTAssertEqual(session.tty, "ttys001")
            XCTAssertFalse(session.isInTmux)
            XCTAssertEqual(probe.flags, [true, true])
        }
    }

    func testNewPIDWithoutTTYCannotRetainOldTerminal() async throws {
        for replacement in [tree(pid: 202, tty: "ttys002"), [:]] {
            let probe = TopologyProbe([tree(), replacement])
            let store = store(probe: probe)
            let now = Date().addingTimeInterval(-2)
            await store.process(.hookReceived(hook(at: now, pid: 101, tty: "/dev/ttys000")))
            await store.process(.hookReceived(hook(at: now.addingTimeInterval(1), pid: 202, tty: nil)))
            let stored = await store.session(for: "process-metadata-fixture")
            let session = try XCTUnwrap(stored)
            XCTAssertEqual(session.pid, 202)
            XCTAssertEqual(session.tty, replacement[202]?.tty)
            XCTAssertEqual(probe.flags, [true, true])
        }
    }

    func testStaleHookCannotReplaceProcessOrQueryTopology() async throws {
        let probe = TopologyProbe([tree()])
        let store = store(probe: probe)
        let now = Date().addingTimeInterval(-2)
        await store.process(.hookReceived(hook(at: now, pid: 101, tty: "/dev/ttys000")))
        await store.process(.hookReceived(hook(at: now.addingTimeInterval(-1), pid: 202, tty: "/dev/ttys001")))
        let stored = await store.session(for: "process-metadata-fixture")
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(session.pid, 101)
        XCTAssertEqual(session.tty, "ttys000")
        XCTAssertEqual(probe.flags, [true])
    }
}
