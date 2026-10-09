import Darwin
import XCTest
@testable import Agent_Notch

@MainActor
private final class BufferedBatchCanceller: SessionPermissionCancelling {
    let server: HookSocketServer
    private(set) var batches: [(sessionId: String, completedAt: Date?)] = []
    init(server: HookSocketServer) { self.server = server }
    func cancelPendingPermission(sessionId: String, toolUseId: String, completedAt: Date?) {
        server.cancelPendingPermission(sessionId: sessionId, toolUseId: toolUseId, completedAt: completedAt)
    }
    func cancelPendingPermissions(sessionId: String, completedAt: Date?) {
        batches.append((sessionId, completedAt))
    }
    func flush() {
        for batch in batches {
            server.cancelPendingPermissions(sessionId: batch.sessionId, completedAt: batch.completedAt)
        }
    }
}

final class PermissionRoutingTests: XCTestCase {
    @MainActor
    func testRenderedButtonBindingsDoNotRetargetWhenQueueAdvances() {
        var displayed = PermissionContext(
            toolUseId: "first", toolName: "Bash", toolInput: nil, receivedAt: Date()
        )
        var actions: [String] = []
        let approve = displayed.bindAction { actions.append("approve:\($0)") }
        let auto = displayed.bindAction { actions.append("auto:\($0)") }
        let deny = displayed.bindAction { actions.append("deny:\($0)") }

        displayed = PermissionContext(
            toolUseId: "second", toolName: "Read", toolInput: nil, receivedAt: Date()
        )
        let nextApprove = displayed.bindAction { actions.append("approve:\($0)") }
        approve()
        auto()
        deny()
        nextApprove()
        XCTAssertEqual(actions, ["approve:first", "auto:first", "deny:first", "approve:second"])
    }

    @MainActor
    func testStructuredRejectBindingKeepsRenderedRequestAfterDismissal() {
        var displayed: PermissionContext? = PermissionContext(
            toolUseId: "question", toolName: "AskUserQuestion", toolInput: nil, receivedAt: Date()
        )
        var rejected: [String] = []
        let reject = displayed!.bindAction { rejected.append($0) }
        displayed = nil
        reject()
        XCTAssertNil(displayed)
        XCTAssertEqual(rejected, ["question"])
    }

    private func connect(to path: String) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.ENOTSOCK) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                UnsafeMutableRawPointer(pathPointer)
                    .assumingMemoryBound(to: CChar.self)
                    .initialize(from: pointer, count: path.utf8.count + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    client,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            close(client)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        return client
    }

    @discardableResult
    private func sendPermission(
        client: Int32,
        sessionId: String,
        toolUseId: String,
        observedAt: Date? = Date(),
        source: String = "codex"
    ) throws -> HookEvent {
        let event = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/agent-notch-permission-tests",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: observedAt?.timeIntervalSince1970,
            source: source,
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("true")],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil,
            responseTimeoutSeconds: 10
        )
        let data = try JSONEncoder().encode(event)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.write(
                    client,
                    base.advanced(by: sent),
                    data.count - sent
                )
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                sent += count
            }
        }
        shutdown(client, SHUT_WR)
        return event
    }

    private func readResponse(client: Int32) throws -> HookResponse {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                break
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return try JSONDecoder().decode(HookResponse.self, from: data)
    }

    func testTwoSessionsAndMultipleToolsRequireExactIdentity() throws {
        let socketPath = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: socketPath)
        defer {
            server.stop()
            unlink(socketPath)
        }

        let received = expectation(description: "all permissions received")
        received.expectedFulfillmentCount = 3
        server.start(onEvent: { event in
            if event.expectsResponse { received.fulfill() }
        })

        for _ in 0..<100 where access(socketPath, F_OK) != 0 {
            usleep(10_000)
        }
        XCTAssertEqual(access(socketPath, F_OK), 0)
        for _ in 0..<100 where !server.diagnosticsInput().isRunning {
            usleep(10_000)
        }
        let running = server.diagnosticsInput()
        XCTAssertTrue(running.isRunning)
        XCTAssertTrue(running.socketExists)
        XCTAssertTrue(running.ownsSocket)
        XCTAssertTrue(running.pendingPermissionSessionIds.isEmpty)

        let clientA1 = try connect(to: socketPath)
        let clientA2 = try connect(to: socketPath)
        let clientB1 = try connect(to: socketPath)
        defer {
            close(clientA1)
            close(clientA2)
            close(clientB1)
        }

        // Reuse one tool id across sessions to prove that storage and delivery
        // use the complete (session, tool) identity.
        try sendPermission(client: clientA1, sessionId: "session-A", toolUseId: "shared-tool")
        try sendPermission(client: clientA2, sessionId: "session-A", toolUseId: "tool-A2")
        try sendPermission(client: clientB1, sessionId: "session-B", toolUseId: "shared-tool")
        wait(for: [received], timeout: 3)
        let pending = server.diagnosticsInput()
        XCTAssertEqual(pending.pendingPermissionSessionIds.count, 3)
        XCTAssertEqual(pending.pendingPermissionSessionIds.filter { $0 == "session-A" }.count, 2)
        XCTAssertEqual(pending.pendingPermissionSessionIds.filter { $0 == "session-B" }.count, 1)
        XCTAssertNotNil(pending.lastEventAt)

        let rejected = expectation(description: "cross-session response rejected")
        server.respondToPermission(
            toolUseId: "tool-A2",
            sessionId: "session-B",
            decision: "allow"
        ) { delivered in
            XCTAssertFalse(delivered)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        XCTAssertTrue(server.hasPendingPermission(sessionId: "session-A"))
        XCTAssertTrue(server.hasPendingPermission(sessionId: "session-B"))

        let delivered = expectation(description: "exact responses delivered")
        delivered.expectedFulfillmentCount = 3
        for request in [
            ("shared-tool", "session-B", "allow"),
            ("tool-A2", "session-A", "deny"),
            ("shared-tool", "session-A", "allow")
        ] {
            server.respondToPermission(
                toolUseId: request.0,
                sessionId: request.1,
                decision: request.2
            ) { success in
                XCTAssertTrue(success)
                delivered.fulfill()
            }
        }
        wait(for: [delivered], timeout: 3)

        XCTAssertEqual(try readResponse(client: clientB1).decision, "allow")
        XCTAssertEqual(try readResponse(client: clientA2).decision, "deny")
        XCTAssertEqual(try readResponse(client: clientA1).decision, "allow")
        XCTAssertTrue(server.diagnosticsInput().pendingPermissionSessionIds.isEmpty)
        server.stop()
        let stopped = server.diagnosticsInput()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertFalse(stopped.socketExists)
        XCTAssertFalse(stopped.ownsSocket)
    }

    private func startPrivateServer(_ server: HookSocketServer, path: String, received: XCTestExpectation) async {
        server.start(onEvent: { event in if event.expectsResponse { received.fulfill() } })
        let deadline = Date().addingTimeInterval(3)
        while (access(path, F_OK) != 0 || !server.diagnosticsInput().isRunning) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(access(path, F_OK), 0)
    }

    private func assertEOF(client: Int32, file: StaticString = #filePath, line: UInt = #line) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(client, &byte, 1), 0, "Completed request must reach EOF", file: file, line: line)
    }

    @MainActor
    func testTranscriptResolutionClosesExactPrivateSocketAndPreservesNextRequest() async throws {
        for mode in ["direct", "history", "incremental"] {
            let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
            let server = HookSocketServer(socketPath: path)
            defer { server.stop(); unlink(path) }
            let received = expectation(description: "private requests registered: \(mode)")
            received.expectedFulfillmentCount = 2
            await startPrivateServer(server, path: path, received: received)
            let first = try connect(to: path)
            let second = try connect(to: path)
            defer { close(first); close(second) }
            let base = Date().addingTimeInterval(-30)
            let eventA = try sendPermission(client: first, sessionId: "fixture", toolUseId: "first", observedAt: base, source: "claude")
            let eventB = try sendPermission(client: second, sessionId: "fixture", toolUseId: "second", observedAt: base.addingTimeInterval(1), source: "claude")
            await fulfillment(of: [received], timeout: 3)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notch-socket-result-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                     conversationParser: ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root),
                                     permissionCanceller: HookPermissionCanceller(server: server), processTreeProvider: { _ in [:] })
            await store.process(.hookReceived(eventA))
            await store.process(.hookReceived(eventB))
            let completedAt = base.addingTimeInterval(2)
            let result = ConversationParser.ToolResult(content: "done", stdout: nil, stderr: nil, isError: false, observedAt: completedAt)
            switch mode {
            case "history":
                await store.process(.historyLoaded(sessionId: "fixture", messages: [], completedTools: ["first"],
                                                  toolResults: ["first": result], structuredResults: [:],
                                                  conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                                                                                     lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)))
            case "incremental":
                await store.process(.fileUpdated(FileUpdatePayload(sessionId: "fixture", cwd: eventA.cwd, messages: [], isIncremental: true,
                                                                  completedToolIds: ["first"], toolResults: ["first": result], structuredResults: [:])))
            default:
                await store.process(.toolCompleted(sessionId: "fixture", toolUseId: "first", result: .from(parserResult: result, structuredResult: nil)))
            }
            let state = await store.session(for: "fixture")
            XCTAssertEqual(state?.pendingInteractions.toolUseIds, ["second"])
            assertEOF(client: first)
            let delivered = expectation(description: "next request remains deliverable")
            server.respondToPermission(toolUseId: "second", sessionId: "fixture", decision: "deny") { success in
                XCTAssertTrue(success)
                delivered.fulfill()
            }
            await fulfillment(of: [delivered], timeout: 3)
            XCTAssertEqual(try readResponse(client: second).decision, "deny")
        }
    }

    @MainActor
    func testOldCompletionCannotCancelReplacementSocketWithSameKey() async throws {
        let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop(); unlink(path) }
        let received = expectation(description: "old and replacement registered")
        received.expectedFulfillmentCount = 2
        await startPrivateServer(server, path: path, received: received)
        let old = try connect(to: path)
        let replacement = try connect(to: path)
        defer { close(old); close(replacement) }
        let base = Date().addingTimeInterval(-30)
        try sendPermission(client: old, sessionId: "fixture", toolUseId: "same", observedAt: base)
        try sendPermission(client: replacement, sessionId: "fixture", toolUseId: "same", observedAt: base.addingTimeInterval(4))
        await fulfillment(of: [received], timeout: 3)
        assertEOF(client: old)
        server.cancelPendingPermission(sessionId: "fixture", toolUseId: "same", completedAt: base.addingTimeInterval(2))
        let delivered = expectation(description: "replacement survives old completion")
        server.respondToPermission(toolUseId: "same", sessionId: "fixture", decision: "deny") { success in
            XCTAssertTrue(success)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual((try? readResponse(client: replacement))?.decision, "deny")
    }

    @MainActor
    func testRejectedTranscriptResultsLeavePrivateRequestDeliverable() async throws {
        for timestamped in [false, true] {
            let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
            let server = HookSocketServer(socketPath: path)
            defer { server.stop(); unlink(path) }
            let received = expectation(description: "private request registered")
            await startPrivateServer(server, path: path, received: received)
            let client = try connect(to: path)
            defer { close(client) }
            let base = Date().addingTimeInterval(-30)
            let event = try sendPermission(client: client, sessionId: "fixture", toolUseId: "pending", observedAt: base, source: "claude")
            await fulfillment(of: [received], timeout: 3)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notch-socket-rejected-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                                     conversationParser: ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root),
                                     permissionCanceller: HookPermissionCanceller(server: server), processTreeProvider: { _ in [:] })
            await store.process(.hookReceived(event))
            await store.process(.toolCompleted(sessionId: "fixture", toolUseId: "pending", result: ToolCompletionResult(
                status: .success, result: "stale", structuredResult: nil, observedAt: timestamped ? base.addingTimeInterval(-1) : nil)))
            let state = await store.session(for: "fixture")
            XCTAssertEqual(state?.pendingInteractions.toolUseIds, ["pending"])
            let delivered = expectation(description: "rejected result leaves socket usable")
            server.respondToPermission(toolUseId: "pending", sessionId: "fixture", decision: "deny") { success in
                XCTAssertTrue(success)
                delivered.fulfill()
            }
            await fulfillment(of: [delivered], timeout: 3)
            XCTAssertEqual(try readResponse(client: client).decision, "deny")
        }
    }

    @MainActor
    func testUntimestampedRequestAndInvalidCompletionCannotBeCanceledByOldBoundary() async throws {
        let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop(); unlink(path) }
        let received = expectation(description: "untimestamped request registered")
        await startPrivateServer(server, path: path, received: received)
        let client = try connect(to: path)
        defer { close(client) }
        try sendPermission(client: client, sessionId: "fixture", toolUseId: "pending", observedAt: nil)
        await fulfillment(of: [received], timeout: 3)
        server.cancelPendingPermission(sessionId: "fixture", toolUseId: "pending", completedAt: Date().addingTimeInterval(-30))
        server.cancelPendingPermission(sessionId: "fixture", toolUseId: "pending", completedAt: Date(timeIntervalSince1970: .nan))
        let delivered = expectation(description: "request survives invalid boundaries")
        server.respondToPermission(toolUseId: "pending", sessionId: "fixture", decision: "deny") { success in
            XCTAssertTrue(success)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(try readResponse(client: client).decision, "deny")
    }

    @MainActor
    private func batchStore(canceller: any SessionPermissionCancelling) throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notch-batch-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SessionStore(persistenceEnabled: false, fileSyncEnabled: false,
                            conversationParser: ConversationParser(codexSessionsRoot: root, claudeProjectsRoot: root),
                            permissionCanceller: canceller, processTreeProvider: { _ in [:] })
    }

    private func lifecycleHook(_ event: String, at time: Date, pid: Int? = nil) -> SessionEvent {
        .hookReceived(HookEvent(sessionId: "fixture", cwd: "/tmp/agent-notch-permission-tests", event: event,
                                status: event == "SessionEnd" ? "ended" : (event == "Stop" ? "waiting_for_input" : "processing"),
                                observedAt: time.timeIntervalSince1970, source: "claude", pid: pid, tty: nil,
                                tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil, message: nil))
    }

    @MainActor
    func testBatchCancellationClosesOldRequestsButPreservesNewAndOtherSession() async throws {
        let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop(); unlink(path) }
        let received = expectation(description: "mixed batch registered")
        received.expectedFulfillmentCount = 4
        await startPrivateServer(server, path: path, received: received)
        let clients = try (0..<4).map { _ in try connect(to: path) }
        defer { clients.forEach { close($0) } }
        let base = Date().addingTimeInterval(-30)
        try sendPermission(client: clients[0], sessionId: "fixture", toolUseId: "old-1", observedAt: base)
        try sendPermission(client: clients[1], sessionId: "fixture", toolUseId: "old-2", observedAt: base.addingTimeInterval(1))
        try sendPermission(client: clients[2], sessionId: "fixture", toolUseId: "new", observedAt: base.addingTimeInterval(4))
        try sendPermission(client: clients[3], sessionId: "other", toolUseId: "old-1", observedAt: base)
        await fulfillment(of: [received], timeout: 3)
        server.cancelPendingPermissions(sessionId: "fixture", completedAt: base.addingTimeInterval(2))
        assertEOF(client: clients[0])
        assertEOF(client: clients[1])
        for (client, session, tool) in [(clients[2], "fixture", "new"), (clients[3], "other", "old-1")] {
            let delivered = expectation(description: "protected request delivered")
            server.respondToPermission(toolUseId: tool, sessionId: session, decision: "deny") { success in
                XCTAssertTrue(success); delivered.fulfill()
            }
            await fulfillment(of: [delivered], timeout: 3)
            XCTAssertEqual((try? readResponse(client: client))?.decision, "deny")
        }
    }

    @MainActor
    func testAcceptedStopInterruptExitAndSessionEndKeepNewerRawRequest() async throws {
        for kind in ["Stop", "interrupt", "exit", "SessionEnd"] {
            let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
            let server = HookSocketServer(socketPath: path)
            defer { server.stop(); unlink(path) }
            let received = expectation(description: "terminal race: \(kind)")
            received.expectedFulfillmentCount = 2
            await startPrivateServer(server, path: path, received: received)
            let old = try connect(to: path), new = try connect(to: path)
            defer { close(old); close(new) }
            let base = Date().addingTimeInterval(-30)
            let oldEvent = try sendPermission(client: old, sessionId: "fixture", toolUseId: "old", observedAt: base.addingTimeInterval(1), source: "claude")
            try sendPermission(client: new, sessionId: "fixture", toolUseId: "new", observedAt: base.addingTimeInterval(4), source: "claude")
            await fulfillment(of: [received], timeout: 3)
            let store = try batchStore(canceller: HookPermissionCanceller(server: server))
            await store.process(lifecycleHook("UserPromptSubmit", at: base, pid: 12345))
            await store.process(.hookReceived(oldEvent))
            switch kind {
            case "interrupt": await store.process(.interruptDetected(sessionId: "fixture", observedAt: base.addingTimeInterval(2)))
            case "exit": await store.process(.processExited(sessionId: "fixture", pid: 12345, observedAt: base.addingTimeInterval(2)))
            default: await store.process(lifecycleHook(kind, at: base.addingTimeInterval(2)))
            }
            assertEOF(client: old)
            let delivered = expectation(description: "new request remains after \(kind)")
            server.respondToPermission(toolUseId: "new", sessionId: "fixture", decision: "deny") { success in
                XCTAssertTrue(success); delivered.fulfill()
            }
            await fulfillment(of: [delivered], timeout: 3)
            XCTAssertEqual((try? readResponse(client: new))?.decision, "deny")
        }
    }

    @MainActor
    func testDuplicateStopUsesFirstCompletionForBatchCleanup() async throws {
        let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop(); unlink(path) }
        let received = expectation(description: "new raw request registered")
        await startPrivateServer(server, path: path, received: received)
        let client = try connect(to: path)
        defer { close(client) }
        let base = Date().addingTimeInterval(-30)
        let store = try batchStore(canceller: HookPermissionCanceller(server: server))
        await store.process(lifecycleHook("UserPromptSubmit", at: base))
        await store.process(lifecycleHook("Stop", at: base.addingTimeInterval(2)))
        try sendPermission(client: client, sessionId: "fixture", toolUseId: "new", observedAt: base.addingTimeInterval(3), source: "claude")
        await fulfillment(of: [received], timeout: 3)
        await store.process(lifecycleHook("Stop", at: base.addingTimeInterval(4)))
        let state = await store.session(for: "fixture")
        let firstWireTime = Date(timeIntervalSince1970: base.addingTimeInterval(2).timeIntervalSince1970)
        XCTAssertEqual(state?.completedAt, firstWireTime)
        let delivered = expectation(description: "duplicate Stop keeps newer socket")
        server.respondToPermission(toolUseId: "new", sessionId: "fixture", decision: "deny") { success in
            XCTAssertTrue(success); delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual((try? readResponse(client: client))?.decision, "deny")
    }

    @MainActor
    func testLocalSessionEndCapturedBeforeDelayedCleanupPreservesLaterRequest() async throws {
        let path = "/tmp/agent-notch-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop(); unlink(path) }
        let received = expectation(description: "old and later requests registered")
        received.expectedFulfillmentCount = 2
        await startPrivateServer(server, path: path, received: received)
        let old = try connect(to: path), new = try connect(to: path)
        defer { close(old); close(new) }
        let oldEvent = try sendPermission(client: old, sessionId: "fixture", toolUseId: "old", observedAt: Date().addingTimeInterval(-1), source: "claude")
        let deadline = Date().addingTimeInterval(3)
        while !server.hasPendingPermission(sessionId: "fixture") && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(server.hasPendingPermission(sessionId: "fixture"))
        let buffered = BufferedBatchCanceller(server: server)
        let store = try batchStore(canceller: buffered)
        await store.process(.hookReceived(oldEvent))
        let before = Date()
        await store.process(.sessionEnded(sessionId: "fixture"))
        let after = Date()
        XCTAssertEqual(buffered.batches.count, 1)
        let boundary = buffered.batches.first?.completedAt
        XCTAssertNotNil(boundary)
        if let boundary {
            XCTAssertGreaterThanOrEqual(boundary, before)
            XCTAssertLessThanOrEqual(boundary, after)
        }
        let newEvent = try sendPermission(client: new, sessionId: "fixture", toolUseId: "new", source: "claude")
        await fulfillment(of: [received], timeout: 3)
        if let boundary { XCTAssertGreaterThan(newEvent.observedAt ?? 0, boundary.timeIntervalSince1970) }
        await store.process(.hookReceived(newEvent))
        buffered.flush()
        assertEOF(client: old)
        let recreated = await store.session(for: "fixture")
        XCTAssertEqual(recreated?.pendingInteractions.toolUseIds, ["new"])
        let delivered = expectation(description: "later request survives delayed local end")
        server.respondToPermission(toolUseId: "new", sessionId: "fixture", decision: "deny") { success in
            XCTAssertTrue(success); delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual((try? readResponse(client: new))?.decision, "deny")
    }
}
