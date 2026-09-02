//
//  AgentTransport.swift
//  ClaudeIsland
//
//  Unified message transport for CLI-backed and tmux-backed agents.
//

import Foundation

protocol AgentTransport {
    var isAvailable: Bool { get }

    func send(
        _ text: String,
        to session: SessionState,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async throws -> String
}

enum AgentTransportError: LocalizedError {
    case executableNotFound(agentName: String)
    case requiresTmux
    case tmuxPaneNotFound
    case tmuxSendFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let agentName):
            return "\(agentName) CLI was not found."
        case .requiresTmux:
            return "This agent is not connected through tmux."
        case .tmuxPaneNotFound:
            return "Could not find the agent's tmux pane."
        case .tmuxSendFailed:
            return "Could not send the message to tmux."
        }
    }
}

enum AgentTransportKind: Equatable {
    case codexCLI
    case codeBuddyCLI
    case tmux
}

enum AgentTransportRouter {
    static func kind(for source: AgentSource) -> AgentTransportKind {
        switch source {
        case .codex:
            return .codexCLI
        case .codebuddy:
            return .codeBuddyCLI
        default:
            return .tmux
        }
    }

    static func isAvailable(for source: AgentSource) -> Bool {
        transport(for: source).isAvailable
    }

    static func send(
        _ text: String,
        to session: SessionState,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async throws -> String {
        try await transport(for: session.source).send(
            text,
            to: session,
            onStdoutChunk: onStdoutChunk
        )
    }

    private static func transport(for source: AgentSource) -> any AgentTransport {
        switch kind(for: source) {
        case .codexCLI:
            return CodexCLITransport()
        case .codeBuddyCLI:
            return CodeBuddyCLITransport()
        case .tmux:
            return TmuxAgentTransport()
        }
    }
}

struct CodexCLITransport: AgentTransport {
    private var executablePath: String? {
        AgentExecutableLocator.executablePath(named: "codex")
    }

    var isAvailable: Bool { executablePath != nil }

    static func arguments(sessionId: String) -> [String] {
        [
            "exec", "resume",
            "--all",
            "--skip-git-repo-check",
            sessionId,
            "-"
        ]
    }

    func send(
        _ text: String,
        to session: SessionState,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async throws -> String {
        guard let executablePath else {
            throw AgentTransportError.executableNotFound(agentName: "Codex")
        }
        return try await ProcessExecutor.shared.runCapturingOutput(
            executablePath,
            arguments: Self.arguments(sessionId: session.sessionId),
            standardInput: text + "\n",
            currentDirectoryPath: session.cwd,
            timeoutSeconds: 600,
            onStdoutChunk: onStdoutChunk
        )
    }
}

struct CodeBuddyCLITransport: AgentTransport {
    private var executablePath: String? {
        AgentExecutableLocator.executablePath(named: "codebuddy")
    }

    var isAvailable: Bool { executablePath != nil }

    static func arguments(sessionId: String) -> [String] {
        [
            "--resume", sessionId,
            "--print",
            "--output-format", "text"
        ]
    }

    func send(
        _ text: String,
        to session: SessionState,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async throws -> String {
        guard let executablePath else {
            throw AgentTransportError.executableNotFound(agentName: "CodeBuddy")
        }
        return try await ProcessExecutor.shared.runCapturingOutput(
            executablePath,
            arguments: Self.arguments(sessionId: session.sessionId),
            standardInput: text + "\n",
            currentDirectoryPath: session.cwd,
            timeoutSeconds: 600,
            onStdoutChunk: onStdoutChunk
        )
    }
}

private struct TmuxAgentTransport: AgentTransport {
    // Availability for a specific session still depends on its tmux metadata;
    // the composer checks that before invoking this transport.
    var isAvailable: Bool { true }

    func send(
        _ text: String,
        to session: SessionState,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async throws -> String {
        guard session.isInTmux else {
            throw AgentTransportError.requiresTmux
        }
        guard let target = await findTarget(for: session) else {
            throw AgentTransportError.tmuxPaneNotFound
        }
        guard await ToolApprovalHandler.shared.sendMessage(text, to: target) else {
            throw AgentTransportError.tmuxSendFailed
        }
        return ""
    }

    private func findTarget(for session: SessionState) async -> TmuxTarget? {
        // TTYs can change when a terminal is reattached. Prefer the exact TTY,
        // then fall back to the tracked process and working directory.
        if let tty = session.tty,
           let target = await findTarget(tty: tty) {
            return target
        }
        if let pid = session.pid,
           let target = await TmuxController.shared.findTmuxTarget(
               forClaudePid: pid
           ) {
            return target
        }
        if !session.cwd.isEmpty {
            return await TmuxController.shared.findTmuxTarget(
                forWorkingDirectory: session.cwd
            )
        }
        return nil
    }

    private func findTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: [
                    "list-panes", "-a", "-F",
                    "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"
                ]
            )
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }
                let paneTTY = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTTY == tty {
                    return TmuxTarget(from: parts[0])
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

private enum AgentExecutableLocator {
    static func executablePath(named name: String) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)"
        ]
        if let path = Foundation.ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":")
                .map { "\($0)/\(name)" })
        }
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }
}
