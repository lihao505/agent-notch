import CryptoKit
import XCTest
@testable import Agent_Notch

private final class ReaderLifetimeProbe: @unchecked Sendable {}

private final class ReaderLifetimeObservation {
    weak var probe: ReaderLifetimeProbe?

    init(_ probe: ReaderLifetimeProbe) { self.probe = probe }
}

final class ProcessExecutorTests: XCTestCase {
    private let noisyScript = """
    import os
    os.write(2, b'e' * 524288)
    os.write(1, b'o' * 524288)
    """

    func testAsyncRunnerDrainsStdoutAndStderrConcurrently() async {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/python3",
            arguments: ["-c", noisyScript],
            timeoutSeconds: 10
        )

        switch result {
        case .success(let processResult):
            XCTAssertEqual(processResult.output.utf8.count, 524_288)
            XCTAssertEqual(processResult.exitCode, 0)
        case .failure(let error):
            XCTFail("Large dual-pipe command failed: \(error)")
        }
    }

    func testSyncRunnerDrainsStdoutAndStderrConcurrently() {
        let result = ProcessExecutor.shared.runSync(
            "/usr/bin/python3",
            arguments: ["-c", noisyScript],
            timeoutSeconds: 10
        )

        switch result {
        case .success(let output):
            XCTAssertEqual(output.utf8.count, 524_288)
        case .failure(let error):
            XCTFail("Large synchronous dual-pipe command failed: \(error)")
        }
    }

    func testAsyncRunnerPreservesExitCodeAndLargeStderr() async {
        let script = "import os; os.write(2, b'x' * 131072); raise SystemExit(7)"
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/python3",
            arguments: ["-c", script],
            timeoutSeconds: 10
        )

        guard case .failure(.executionFailed(_, let exitCode, let stderr)) = result else {
            return XCTFail("Expected executionFailed, got \(result)")
        }
        XCTAssertEqual(exitCode, 7)
        XCTAssertEqual(stderr?.utf8.count, 131_072)
    }

    func testRunnerTimeoutTerminatesChild() async {
        let startedAt = Date()
        let result = await ProcessExecutor.shared.runWithResult(
            "/bin/sleep",
            arguments: ["5"],
            timeoutSeconds: 0.2
        )

        guard case .failure(.timedOut) = result else {
            return XCTFail("Expected timeout, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testExitedRootCannotLeaveStandardInputWriterWaitingForDescendant() async {
        // The fixture child owns only inherited stdin and self-exits. It never
        // reads input or accesses user files; stdout/stderr close immediately.
        let script = """
        import os, time
        if os.fork() == 0:
            os.close(1)
            os.close(2)
            time.sleep(4)
            os._exit(0)
        os._exit(0)
        """
        let startedAt = Date()
        do {
            _ = try await ProcessExecutor.shared.runCapturingOutput(
                "/usr/bin/python3",
                arguments: ["-c", script],
                standardInput: String(repeating: "x", count: 4 * 1_024 * 1_024),
                timeoutSeconds: 3
            )
            XCTFail("The exited root cannot accept the complete input")
        } catch let error as ProcessExecutorError {
            guard case .standardInputFailed = error else {
                return XCTFail("Expected interrupted input delivery, got \(error)")
            }
        } catch {
            XCTFail("Unexpected input error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testStandardInputIsCompletelyDeliveredAcrossPartialWrites() async throws {
        let input = String(repeating: "你好-input\n", count: 64_000)
        let output = try await ProcessExecutor.shared.runCapturingOutput(
            "/usr/bin/python3",
            arguments: ["-c", "import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"],
            standardInput: input,
            timeoutSeconds: 10
        )
        // Calculate the expected digest in-process, independently of the writer.
        let expected = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines),
                       expected)
    }

    func testNonReadingStandardInputHonorsTimeout() async {
        let startedAt = Date()
        do {
            _ = try await ProcessExecutor.shared.runCapturingOutput(
                "/usr/bin/python3",
                arguments: ["-c", "import time; time.sleep(5)"],
                standardInput: String(repeating: "x", count: 4 * 1_024 * 1_024),
                timeoutSeconds: 0.2
            )
            XCTFail("Expected timeout for a full stdin pipe")
        } catch let error as ProcessExecutorError {
            guard case .timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testNonReadingStandardInputHonorsCancellation() async {
        let ready = expectation(description: "Child launched without reading stdin")
        let task = Task {
            try await ProcessExecutor.shared.runCapturingOutput(
                "/usr/bin/python3",
                arguments: ["-c", "import os, time; os.write(1, b'READY'); time.sleep(5)"],
                standardInput: String(repeating: "x", count: 4 * 1_024 * 1_024),
                timeoutSeconds: 10,
                onStdoutChunk: { _ in ready.fulfill() }
            )
        }
        await fulfillment(of: [ready], timeout: 3)
        let startedAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation for a full stdin pipe")
        } catch let error as ProcessExecutorError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testEarlyExitPreservesActionableStderrDespiteUndeliveredInput() async {
        do {
            _ = try await ProcessExecutor.shared.runCapturingOutput(
                "/usr/bin/python3",
                arguments: ["-c", "import os; os.write(2, b'configuration rejected'); os._exit(7)"],
                standardInput: String(repeating: "x", count: 4 * 1_024 * 1_024),
                timeoutSeconds: 10
            )
            XCTFail("Expected the child's actionable error")
        } catch let error as ProcessExecutorError {
            guard case .executionFailed(_, let code, let stderr) = error else {
                return XCTFail("Expected execution failure, got \(error)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertEqual(stderr, "configuration rejected")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private let inheritedOutputScript = """
    import os, time
    os.write(1, b'ROOT_DONE\\n')
    os.write(2, b'ROOT_WARNING')
    if os.fork() == 0:
        os.close(0)
        time.sleep(5)
        os._exit(0)
    os._exit(0)
    """

    private func runWithReaderLifetimeObservation() async throws -> (String, ReaderLifetimeObservation) {
        let probe = ReaderLifetimeProbe()
        let observation = ReaderLifetimeObservation(probe)
        let output = try await ProcessExecutor.shared.runCapturingOutput(
            "/usr/bin/python3",
            arguments: ["-c", inheritedOutputScript],
            timeoutSeconds: 10,
            onStdoutChunk: { _ in withExtendedLifetime(probe) {} }
        )
        return (output, observation)
    }

    func testExitedRootRetiresOutputReaderWithoutWaitingForDescendant() async throws {
        // The child holds stdout/stderr without writing and self-exits after 5s.
        // Observe the production reader callback's lifetime, not just the result.
        let startedAt = Date()
        let (output, observation) = try await runWithReaderLifetimeObservation()
        XCTAssertEqual(output, "ROOT_DONE\n")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(observation.probe, "Completed invocation still retains its output reader callback")
    }

    func testOutputCleanupHonorsDeadlineAfterRootHasExited() async {
        let startedAt = Date()
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/python3",
            arguments: ["-c", inheritedOutputScript],
            timeoutSeconds: 0.3
        )
        guard case .failure(.timedOut) = result else {
            return XCTFail("Expected the full invocation deadline, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testSyncOutputCleanupHonorsDeadlineAfterRootHasExited() {
        let startedAt = Date()
        let result = ProcessExecutor.shared.runSync(
            "/usr/bin/python3",
            arguments: ["-c", inheritedOutputScript],
            timeoutSeconds: 0.3
        )
        guard case .failure(.timedOut) = result else {
            return XCTFail("Expected the full sync invocation deadline, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testOutputCleanupRespondsToCancellationAfterRootHasExited() async {
        let ready = expectation(description: "Descendant confirmed root exit")
        let script = """
        import os, time
        root_pid = os.getpid()
        if os.fork() == 0:
            os.close(0)
            deadline = time.monotonic() + 2
            while os.getppid() == root_pid and time.monotonic() < deadline:
                time.sleep(0.01)
            if os.getppid() != root_pid:
                os.write(1, b'ROOT_EXITED')
            time.sleep(5)
            os._exit(0)
        os._exit(0)
        """
        let task = Task {
            try await ProcessExecutor.shared.runCapturingOutput(
                "/usr/bin/python3",
                arguments: ["-c", script],
                timeoutSeconds: 10,
                onStdoutChunk: { data in
                    if String(decoding: data, as: UTF8.self).contains("ROOT_EXITED") {
                        ready.fulfill()
                    }
                }
            )
        }
        await fulfillment(of: [ready], timeout: 3)
        let startedAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation during inherited-output cleanup")
        } catch let error as ProcessExecutorError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }
}
