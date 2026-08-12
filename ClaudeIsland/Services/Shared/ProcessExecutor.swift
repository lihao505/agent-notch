//
//  Modified by lihao505 for Agent Notch, 2026.
//  ProcessExecutor.swift
//  ClaudeIsland
//
//  Shared utility for executing shell commands with proper error handling
//

import Foundation
import os.log

/// Errors that can occur during process execution
enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, underlying: Error)
    case timedOut(command: String, seconds: Int)

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
        }
    }
}

/// Process output is drained on background queues. Keep all cross-queue state
/// behind one lock so Swift 6 does not observe mutable Data races and the
/// continuation can be resumed exactly once across exit/timeout/launch paths.
private final class ProcessCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var stdoutData = Data()
    nonisolated(unsafe) private var stderrData = Data()
    nonisolated(unsafe) private var timedOut = false
    nonisolated(unsafe) private var completed = false

    nonisolated init() {}

    nonisolated func setStdout(_ data: Data) {
        lock.lock()
        stdoutData = data
        lock.unlock()
    }

    nonisolated func setStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }

    nonisolated func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    nonisolated func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }

    nonisolated func snapshot() -> (stdout: Data, stderr: Data, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData, timedOut)
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

    /// Run a potentially chatty, long-lived command without buffering its
    /// output. This avoids filling a Pipe while commands such as `codex exec`
    /// are still running.
    func runDiscardingOutput(
        _ executable: String,
        arguments: [String],
        standardInput: String? = nil,
        currentDirectoryPath: String? = nil
    ) async throws {
        let result: Result<Void, ProcessExecutorError> = await withCheckedContinuation { continuation in
            let process = Process()
            let inputPipe = standardInput.map { _ in Pipe() }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectoryPath,
               FileManager.default.fileExists(atPath: currentDirectoryPath) {
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
            }
            process.standardInput = inputPipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 {
                    continuation.resume(returning: .success(()))
                } else {
                    continuation.resume(returning: .failure(.executionFailed(
                        command: executable,
                        exitCode: completed.terminationStatus,
                        stderr: nil
                    )))
                }
            }

            do {
                try process.run()
                if let standardInput, let inputPipe {
                    inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                    inputPipe.fileHandleForWriting.closeFile()
                }
            } catch let error as NSError {
                inputPipe?.fileHandleForWriting.closeFile()
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    continuation.resume(returning: .failure(.commandNotFound(executable)))
                } else {
                    continuation.resume(returning: .failure(.launchFailed(
                        command: executable,
                        underlying: error
                    )))
                }
            }
        }

        try result.get()
    }

    /// Run a CLI chat command and return its stdout. Output is drained on a
    /// background reader before waiting for termination, so a verbose agent
    /// cannot deadlock on a full stdout pipe.
    func runCapturingOutput(
        _ executable: String,
        arguments: [String],
        standardInput: String? = nil,
        currentDirectoryPath: String? = nil,
        timeoutSeconds: TimeInterval = 600
    ) async throws -> String {
        let result: Result<String, ProcessExecutorError> = await withCheckedContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let inputPipe = standardInput.map { _ in Pipe() }
            let capture = ProcessCaptureState()
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
                capture.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                capture.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                readGroup.leave()
            }

            process.terminationHandler = { completedProcess in
                DispatchQueue.global(qos: .utility).async {
                    // A timed-out CLI may leave a descendant holding stdout
                    // open. Return as soon as the parent terminates instead of
                    // waiting forever for inherited pipe descriptors.
                    if capture.snapshot().timedOut {
                        guard capture.claimCompletion() else { return }
                        continuation.resume(returning: .failure(.timedOut(
                            command: executable,
                            seconds: max(1, Int(timeoutSeconds.rounded()))
                        )))
                        return
                    }

                    readGroup.wait()
                    guard capture.claimCompletion() else { return }

                    let snapshot = capture.snapshot()
                    let output = String(data: snapshot.stdout, encoding: .utf8) ?? ""
                    let stderr = String(data: snapshot.stderr, encoding: .utf8)
                    if completedProcess.terminationStatus == 0 {
                        continuation.resume(returning: .success(output))
                    } else {
                        continuation.resume(returning: .failure(.executionFailed(
                            command: executable,
                            exitCode: completedProcess.terminationStatus,
                            stderr: stderr
                        )))
                    }
                }
            }

            do {
                try process.run()
                if let standardInput, let inputPipe {
                    inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                    inputPipe.fileHandleForWriting.closeFile()
                }

                if timeoutSeconds > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + timeoutSeconds
                    ) {
                        guard process.isRunning else { return }
                        capture.markTimedOut()
                        process.terminate()
                        DispatchQueue.global(qos: .utility).asyncAfter(
                            deadline: .now() + 2
                        ) {
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
            } catch let error as NSError {
                inputPipe?.fileHandleForWriting.closeFile()
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                guard capture.claimCompletion() else { return }
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    continuation.resume(returning: .failure(.commandNotFound(executable)))
                    return
                }
                continuation.resume(returning: .failure(.launchFailed(
                    command: executable,
                    underlying: error
                )))
            }
        }
        return try result.get()
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)

                let result = ProcessResult(
                    output: stdout,
                    exitCode: process.terminationStatus,
                    stderr: stderr
                )

                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(result))
                } else {
                    Self.logger.warning("Command failed: \(executable) \(arguments.joined(separator: " "), privacy: .public) - exit code \(process.terminationStatus)")
                    continuation.resume(returning: .failure(.executionFailed(
                        command: executable,
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    )))
                }
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    Self.logger.error("Command not found: \(executable, privacy: .public)")
                    continuation.resume(returning: .failure(.commandNotFound(executable)))
                } else {
                    Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failure(.launchFailed(command: executable, underlying: error)))
                }
            } catch {
                Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: .failure(.launchFailed(command: executable, underlying: error)))
            }
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    nonisolated func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)

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
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            } else {
                Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                return .failure(.launchFailed(command: executable, underlying: error))
            }
        } catch {
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
