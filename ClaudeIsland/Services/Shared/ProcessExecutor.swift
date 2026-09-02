//
//  Modified by lihao505 for Agent Notch, 2026.
//  ProcessExecutor.swift
//  ClaudeIsland
//
//  Shared utility for executing shell commands with proper error handling
//

import Darwin
import Foundation
import os.log

/// A rolling byte cap can begin inside a multi-byte scalar. Skip only orphaned
/// continuation bytes at the retained prefix; all complete UTF-8 that follows
/// remains byte-for-byte identical to the CLI output.
nonisolated private func decodeCapturedUTF8Tail(_ data: Data) -> String {
    var start = data.startIndex
    while start < data.endIndex, (data[start] & 0xC0) == 0x80 {
        start = data.index(after: start)
    }
    return String(decoding: data[start...], as: UTF8.self)
}

/// Errors that can occur during process execution
enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, underlying: Error)
    case timedOut(command: String, seconds: Int)
    case cancelled(command: String)
    case standardInputFailed(command: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let command, let exitCode, let stderr):
            let stderrInfo = stderr.map { ", stderr: \($0)" } ?? ""
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrInfo)"
        case .invalidOutput(let command):
            return "Command '\(command)' produced invalid output"
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        case .launchFailed(let command, let underlying):
            return "Failed to launch '\(command)': \(underlying.localizedDescription)"
        case .timedOut(let command, let seconds):
            return "Command '\(command)' timed out after \(seconds) seconds"
        case .cancelled(let command):
            return "Command '\(command)' was cancelled"
        case .standardInputFailed(let command, let reason):
            return "Could not send input to '\(command)': \(reason)"
        }
    }
}

/// Process output is drained on background queues. Keep all cross-queue state
/// behind one lock so Swift 6 does not observe mutable Data races and the
/// continuation can be resumed exactly once across exit/timeout/launch paths.
private final class ProcessCaptureState: @unchecked Sendable {
    nonisolated struct CompletionSnapshot {
        let stdout: Data
        let stderr: Data
        let stdoutWasTruncated: Bool
        let stderrWasTruncated: Bool
        let timedOut: Bool
        let cancelled: Bool
        let standardInputFailure: String?
    }

    private nonisolated static let maximumStdoutBytes = 2 * 1_024 * 1_024
    private nonisolated static let maximumStderrBytes = 256 * 1_024
    private let lock = NSLock()
    nonisolated(unsafe) private var stdoutData = Data()
    nonisolated(unsafe) private var stderrData = Data()
    nonisolated(unsafe) private var stdoutWasTruncated = false
    nonisolated(unsafe) private var stderrWasTruncated = false
    nonisolated(unsafe) private var timedOut = false
    nonisolated(unsafe) private var cancelled = false
    nonisolated(unsafe) private var completed = false
    nonisolated(unsafe) private var terminationStarted = false
    nonisolated(unsafe) private var standardInputFailure: String?
    nonisolated(unsafe) private var process: Process?

    nonisolated init() {}

    /// Returns whether the chunk still belongs to an active invocation and may
    /// be forwarded to UI consumers. We continue capturing bytes after a stop
    /// request so pipe draining remains correct, but never emit late UI chunks.
    nonisolated func appendStdout(_ data: Data) -> Bool {
        lock.lock()
        appendBounded(
            data,
            to: &stdoutData,
            maximumBytes: Self.maximumStdoutBytes,
            wasTruncated: &stdoutWasTruncated
        )
        let shouldEmit = !timedOut && !cancelled && !completed
        lock.unlock()
        return shouldEmit
    }

    nonisolated func appendStderr(_ data: Data) {
        lock.lock()
        appendBounded(
            data,
            to: &stderrData,
            maximumBytes: Self.maximumStderrBytes,
            wasTruncated: &stderrWasTruncated
        )
        lock.unlock()
    }

    /// Retain a rolling tail. Once full, trim in batches to avoid repeatedly
    /// moving a multi-megabyte Data buffer for every small pipe read.
    private nonisolated func appendBounded(
        _ data: Data,
        to buffer: inout Data,
        maximumBytes: Int,
        wasTruncated: inout Bool
    ) {
        guard !data.isEmpty else { return }
        if data.count >= maximumBytes {
            buffer = Data(data.suffix(maximumBytes))
            wasTruncated = true
            return
        }

        buffer.append(data)
        guard buffer.count > maximumBytes else { return }
        let retainedBytes = maximumBytes * 3 / 4
        buffer = Data(buffer.suffix(retainedBytes))
        wasTruncated = true
    }

    /// Register the launched process. Cancellation can race process startup,
    /// so a cancellation requested before `Process.run()` still terminates the
    /// child immediately after its PID becomes available.
    nonisolated func register(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = (timedOut || cancelled || standardInputFailure != nil)
            && !terminationStarted
        if shouldTerminate {
            terminationStarted = true
        }
        lock.unlock()
        if shouldTerminate {
            terminateProcessTree(process)
        }
    }

    /// Atomically decide whether stdin may begin writing. Cancellation that
    /// happened before this point therefore cannot race into a post-terminate
    /// write. A cancellation after this point is safe because the descriptor is
    /// configured with F_SETNOSIGPIPE and the throwing FileHandle API is used.
    nonisolated func beginStandardInputWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !timedOut && !cancelled && !completed && standardInputFailure == nil
    }

    nonisolated func markTimedOutAndTerminate() {
        lock.lock()
        guard !completed, !timedOut else {
            lock.unlock()
            return
        }
        timedOut = true
        let process = processForTerminationLocked()
        lock.unlock()
        if let process {
            terminateProcessTree(process)
        }
    }

    nonisolated func markCancelledAndTerminate() {
        lock.lock()
        guard !completed, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let process = processForTerminationLocked()
        lock.unlock()
        if let process {
            terminateProcessTree(process)
        }
    }

    nonisolated func markStandardInputFailedAndTerminate(_ reason: String) {
        lock.lock()
        guard !completed, standardInputFailure == nil else {
            lock.unlock()
            return
        }
        standardInputFailure = reason
        let process = processForTerminationLocked()
        lock.unlock()
        if let process {
            terminateProcessTree(process)
        }
    }

    /// Claims the continuation and its terminal state in one lock operation,
    /// eliminating the cancellation-between-snapshot-and-resume race.
    nonisolated func claimCompletionSnapshot() -> CompletionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        process = nil
        return CompletionSnapshot(
            stdout: stdoutData,
            stderr: stderrData,
            stdoutWasTruncated: stdoutWasTruncated,
            stderrWasTruncated: stderrWasTruncated,
            timedOut: timedOut,
            cancelled: cancelled,
            standardInputFailure: standardInputFailure
        )
    }

    /// Wait for both readers on every exit path. If a descendant inherited a
    /// pipe and did not exit, close our read descriptors after a bounded wait
    /// so no GCD worker or callback remains retained indefinitely.
    nonisolated func finishReading(
        _ readGroup: DispatchGroup,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval = 2
    ) {
        guard readGroup.wait(timeout: .now() + timeout) == .timedOut else {
            return
        }
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        _ = readGroup.wait(timeout: .now() + 0.25)
    }

    private nonisolated func processForTerminationLocked() -> Process? {
        guard !terminationStarted, let process else { return nil }
        terminationStarted = true
        return process
    }

    /// Foundation.Process only signals its direct PID. Both Codex and
    /// CodeBuddy can spawn agent/tool descendants, so snapshot and signal the
    /// whole process tree. The delayed KILL covers descendants that ignore TERM.
    private nonisolated func terminateProcessTree(_ process: Process) {
        let rootPID = process.processIdentifier
        guard rootPID > 1, process.isRunning else { return }

        let tree = ProcessTreeBuilder.shared.buildTree(forceRefresh: true)
        let descendants = ProcessTreeBuilder.shared.findDescendants(
            of: Int(rootPID),
            tree: tree
        )
        let targetPIDs = Set(descendants.map(Int32.init)).union([rootPID])
        let initialCommands = Dictionary(uniqueKeysWithValues: descendants.compactMap { pid in
            tree[pid].map { (Int32(pid), $0.command) }
        })

        // Signal the wrapper first so it cannot keep creating children while
        // the captured descendant set is being stopped.
        kill(rootPID, SIGTERM)
        for pid in targetPIDs where pid != rootPID {
            kill(pid, SIGTERM)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            let rootIsStillRunning = process.isRunning
            let latestTree = ProcessTreeBuilder.shared.buildTree(
                forceRefresh: true
            )
            var forceCommands = initialCommands
            if rootIsStillRunning {
                for pid in ProcessTreeBuilder.shared.findDescendants(
                    of: Int(rootPID),
                    tree: latestTree
                ) {
                    if let info = latestTree[pid] {
                        forceCommands[Int32(pid)] = info.command
                    }
                }
            }

            // Avoid killing an unrelated process if a short-lived descendant's
            // PID was reused during the grace period. The Process instance is
            // authoritative for the root; descendants must still match their
            // captured command identity.
            if rootIsStillRunning {
                kill(rootPID, SIGKILL)
            }
            for (pid, expectedCommand) in forceCommands where pid > 1 {
                guard latestTree[Int(pid)]?.command == expectedCommand else {
                    continue
                }
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Result type for process execution
struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stderr: String?

    var isSuccess: Bool { exitCode == 0 }
}

/// Default implementation using Foundation.Process
actor ProcessExecutor {
    /// Shared instance for asynchronous and synchronous process helpers.
    nonisolated static let shared = ProcessExecutor()

    /// Logger for process execution (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "ProcessExecutor")

    private init() {}

    /// Run a command asynchronously and return output (throws on failure)
    func run(_ executable: String, arguments: [String]) async throws -> String {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let processResult):
            return processResult.output
        case .failure(let error):
            throw error
        }
    }

    /// Run a potentially chatty command while discarding the returned text.
    /// The shared runner still drains both pipes concurrently with bounded
    /// memory, timeout, cancellation, and process-tree termination.
    func runDiscardingOutput(
        _ executable: String,
        arguments: [String],
        standardInput: String? = nil,
        currentDirectoryPath: String? = nil
    ) async throws {
        // Keep this API for call-site intent, but share the same bounded,
        // concurrently drained, timeout/cancellation-safe runner as every
        // output-producing command. The returned text is deliberately ignored.
        _ = try await runCapturingOutput(
            executable,
            arguments: arguments,
            standardInput: standardInput,
            currentDirectoryPath: currentDirectoryPath
        )
    }

    /// Run a CLI chat command and return its stdout. Output is drained on a
    /// background reader before waiting for termination, so a verbose agent
    /// cannot deadlock on a full stdout pipe.
    func runCapturingOutput(
        _ executable: String,
        arguments: [String],
        standardInput: String? = nil,
        currentDirectoryPath: String? = nil,
        timeoutSeconds: TimeInterval = 600,
        onStdoutChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws -> String {
        let capture = ProcessCaptureState()
        let result: Result<String, ProcessExecutorError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let inputPipe = standardInput.map { _ in Pipe() }
                let startupGroup = DispatchGroup()
                startupGroup.enter()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectoryPath,
                   FileManager.default.fileExists(atPath: currentDirectoryPath) {
                    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
                }
                process.standardInput = inputPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { readGroup.leave() }
                    while true {
                        let data = stdoutPipe.fileHandleForReading.availableData
                        guard !data.isEmpty else { return }
                        if capture.appendStdout(data) {
                            onStdoutChunk?(data)
                        }
                    }
                }
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { readGroup.leave() }
                    while true {
                        let data = stderrPipe.fileHandleForReading.availableData
                        guard !data.isEmpty else { return }
                        capture.appendStderr(data)
                    }
                }

                process.terminationHandler = { completedProcess in
                    DispatchQueue.global(qos: .utility).async {
                        // A very short-lived child can terminate while stdin is
                        // still being set up. Wait until that setup either
                        // succeeds or records its failure before deciding the
                        // invocation's result.
                        startupGroup.wait()
                        capture.finishReading(
                            readGroup,
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe
                        )
                        guard let snapshot = capture.claimCompletionSnapshot() else {
                            return
                        }

                        if snapshot.cancelled {
                            continuation.resume(returning: .failure(.cancelled(
                                command: executable
                            )))
                            return
                        }
                        if snapshot.timedOut {
                            continuation.resume(returning: .failure(.timedOut(
                                command: executable,
                                seconds: max(1, Int(timeoutSeconds.rounded()))
                            )))
                            return
                        }
                        var output = decodeCapturedUTF8Tail(snapshot.stdout)
                        if snapshot.stdoutWasTruncated {
                            output = "…\n" + output
                        }
                        var stderr = decodeCapturedUTF8Tail(snapshot.stderr)
                        if snapshot.stderrWasTruncated {
                            stderr = "…\n" + stderr
                        }
                        let optionalStderr = stderr.isEmpty ? nil : stderr
                        if completedProcess.terminationStatus != 0 {
                            continuation.resume(returning: .failure(.executionFailed(
                                command: executable,
                                exitCode: completedProcess.terminationStatus,
                                stderr: optionalStderr
                            )))
                        } else if let reason = snapshot.standardInputFailure {
                            // A short-lived CLI can close stdin while also
                            // exiting with its own actionable error. Preserve
                            // that real exit status/stderr above; report the
                            // pipe failure only when the child itself succeeded.
                            continuation.resume(returning: .failure(.standardInputFailed(
                                command: executable,
                                reason: reason
                            )))
                        } else {
                            continuation.resume(returning: .success(output))
                        }
                    }
                }

                do {
                    try process.run()
                    capture.register(process)

                    // Start the wall-clock timeout before touching stdin. A
                    // child can launch successfully and then never read its
                    // pipe; the timeout must still be able to terminate it and
                    // unblock the writer.
                    if timeoutSeconds > 0 {
                        DispatchQueue.global(qos: .utility).asyncAfter(
                            deadline: .now() + timeoutSeconds
                        ) { [weak capture, weak process] in
                            guard let capture, let process, process.isRunning else {
                                return
                            }
                            capture.markTimedOutAndTerminate()
                        }
                    }

                    if let standardInput, let inputPipe {
                        // Keep a blocked stdin consumer off the ProcessExecutor
                        // actor. terminationHandler waits for this group, while
                        // timeout/cancellation closes the child side and lets
                        // the throwing write finish deterministically.
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { startupGroup.leave() }
                            let inputHandle = inputPipe.fileHandleForWriting
                            defer { try? inputHandle.close() }

                            // Prevent EPIPE from terminating Agent Notch. The
                            // throwing write then turns a child that closed stdin
                            // early into a normal, reportable command error.
                            let noSigPipe = fcntl(
                                inputHandle.fileDescriptor,
                                F_SETNOSIGPIPE,
                                1
                            ) == 0
                            if !noSigPipe {
                                capture.markStandardInputFailedAndTerminate(
                                    "Could not configure a signal-safe stdin pipe (errno \(errno))"
                                )
                            } else if capture.beginStandardInputWrite() {
                                do {
                                    try inputHandle.write(
                                        contentsOf: Data(standardInput.utf8)
                                    )
                                } catch {
                                    capture.markStandardInputFailedAndTerminate(
                                        error.localizedDescription
                                    )
                                }
                            }
                        }
                    } else {
                        startupGroup.leave()
                    }
                } catch let error as NSError {
                    try? inputPipe?.fileHandleForWriting.close()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    startupGroup.leave()

                    DispatchQueue.global(qos: .utility).async {
                        capture.finishReading(
                            readGroup,
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe,
                            timeout: 0.25
                        )
                        guard let snapshot = capture.claimCompletionSnapshot() else {
                            return
                        }
                        if snapshot.cancelled {
                            continuation.resume(returning: .failure(.cancelled(
                                command: executable
                            )))
                        } else if error.domain == NSCocoaErrorDomain
                                    && error.code == NSFileNoSuchFileError {
                            continuation.resume(returning: .failure(.commandNotFound(executable)))
                        } else {
                            continuation.resume(returning: .failure(.launchFailed(
                                command: executable,
                                underlying: error
                            )))
                        }
                    }
                }
            }
        } onCancel: {
            capture.markCancelledAndTerminate()
        }
        return try result.get()
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    func runWithResult(
        _ executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 600
    ) async -> Result<ProcessResult, ProcessExecutorError> {
        do {
            let output = try await runCapturingOutput(
                executable,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
            return .success(ProcessResult(
                output: output,
                exitCode: 0,
                stderr: nil
            ))
        } catch let error as ProcessExecutorError {
            return .failure(error)
        } catch {
            return .failure(.launchFailed(
                command: executable,
                underlying: error
            ))
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    nonisolated func runSync(
        _ executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 60
    ) -> Result<String, ProcessExecutorError> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let capture = ProcessCaptureState()
        let readGroup = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave() }
            while true {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard !data.isEmpty else { return }
                _ = capture.appendStdout(data)
            }
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave() }
            while true {
                let data = stderrPipe.fileHandleForReading.availableData
                guard !data.isEmpty else { return }
                capture.appendStderr(data)
            }
        }

        do {
            try process.run()
            capture.register(process)
            if timeoutSeconds > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeoutSeconds
                ) { [weak capture, weak process] in
                    guard let capture, let process, process.isRunning else {
                        return
                    }
                    capture.markTimedOutAndTerminate()
                }
            }
            process.waitUntilExit()
            capture.finishReading(
                readGroup,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            guard let snapshot = capture.claimCompletionSnapshot() else {
                return .failure(.invalidOutput(command: executable))
            }
            if snapshot.timedOut {
                return .failure(.timedOut(
                    command: executable,
                    seconds: max(1, Int(timeoutSeconds.rounded()))
                ))
            }

            var stdout = decodeCapturedUTF8Tail(snapshot.stdout)
            if snapshot.stdoutWasTruncated {
                stdout = "…\n" + stdout
            }
            var stderr = decodeCapturedUTF8Tail(snapshot.stderr)
            if snapshot.stderrWasTruncated {
                stderr = "…\n" + stderr
            }

            if process.terminationStatus == 0 {
                return .success(stdout)
            } else {
                Self.logger.warning("Sync command failed: \(executable, privacy: .public) - exit code \(process.terminationStatus)")
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: process.terminationStatus,
                    stderr: stderr
                ))
            }
        } catch let error as NSError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            capture.finishReading(
                readGroup,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: 0.25
            )
            _ = capture.claimCompletionSnapshot()
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            } else {
                Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                return .failure(.launchFailed(command: executable, underlying: error))
            }
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            capture.finishReading(
                readGroup,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: 0.25
            )
            _ = capture.claimCompletionSnapshot()
            Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return .failure(.launchFailed(command: executable, underlying: error))
        }
    }
}

// MARK: - Convenience Extensions

extension ProcessExecutor {
    /// Run a command and return output, returning nil only if the command itself fails to execute
    /// (as opposed to non-zero exit codes which may still have useful output)
    func runOrNil(_ executable: String, arguments: [String]) async -> String? {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let processResult):
            return processResult.output
        case .failure:
            return nil
        }
    }

    /// Run a command synchronously, returning nil on failure (backwards compatible)
    nonisolated func runSyncOrNil(_ executable: String, arguments: [String]) -> String? {
        switch runSync(executable, arguments: arguments) {
        case .success(let output):
            return output
        case .failure:
            return nil
        }
    }
}
