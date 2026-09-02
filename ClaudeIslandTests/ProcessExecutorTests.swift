import XCTest
@testable import Agent_Notch

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
}
