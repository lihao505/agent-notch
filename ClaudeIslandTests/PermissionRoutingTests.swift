import Darwin
import XCTest
@testable import Agent_Notch

final class PermissionRoutingTests: XCTestCase {
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

    private func sendPermission(
        client: Int32,
        sessionId: String,
        toolUseId: String
    ) throws {
        let event = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/agent-notch-permission-tests",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            observedAt: Date().timeIntervalSince1970,
            source: "codex",
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

        let clientA1 = try connect(to: socketPath)
        let clientA2 = try connect(to: socketPath)
        let clientB1 = try connect(to: socketPath)
        defer {
            close(clientA1)
            close(clientA2)
            close(clientB1)
        }

        try sendPermission(client: clientA1, sessionId: "session-A", toolUseId: "tool-A1")
        try sendPermission(client: clientA2, sessionId: "session-A", toolUseId: "tool-A2")
        try sendPermission(client: clientB1, sessionId: "session-B", toolUseId: "tool-B1")
        wait(for: [received], timeout: 3)

        let rejected = expectation(description: "cross-session response rejected")
        server.respondToPermission(
            toolUseId: "tool-A1",
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
            ("tool-B1", "session-B", "allow"),
            ("tool-A2", "session-A", "deny"),
            ("tool-A1", "session-A", "allow")
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
    }
}
