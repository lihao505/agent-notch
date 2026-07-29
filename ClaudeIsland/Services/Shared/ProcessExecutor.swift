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

    /// Run a potentially chatty, long-lived command without buffering its
    /// output. This avoids filling a Pipe while commands such as `codex exec`
    /// are still running.
    func runDiscardingOutput(
        _ executable: String,
        arguments: [String],
        standardInput: String? = nil
    ) async throws {
        let result: Result<Void, ProcessExecutorError> = await withCheckedContinuation { continuation in
            let process = Process()
            let inputPipe = standardInput.map { _ in Pipe() }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
