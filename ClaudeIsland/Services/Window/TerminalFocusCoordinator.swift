//
//  TerminalFocusCoordinator.swift
//  ClaudeIsland
//
//  Shared, result-oriented terminal focus routing for notch surfaces.
//

import AppKit
import Foundation

actor TerminalFocusCoordinator {
    static let shared = TerminalFocusCoordinator()

    private init() {}

    /// Focus a local terminal-backed session and return success only after the
    /// observable foreground state agrees with the requested session.
    func focus(_ session: SessionState) async -> Bool {
        if session.isInTmux {
            let exactFocusSucceeded: Bool
            if let pid = session.pid {
                exactFocusSucceeded = await YabaiController.shared.focusWindow(
                    forClaudePid: pid
                )
            } else {
                exactFocusSucceeded = await YabaiController.shared.focusWindow(
                    forWorkingDirectory: session.cwd
                )
            }
            if exactFocusSucceeded {
                return true
            }

            // Preserve the useful fallback when yabai is unavailable: switch
            // the tmux pane and bring its owning terminal app forward. This is
            // intentionally not reported as exact success because one terminal
            // process can own several macOS windows.
            guard let pid = session.pid,
                  let target = await TmuxController.shared.findTmuxTarget(
                    forClaudePid: pid
                  ),
                  await TmuxController.shared.switchToPane(target: target) else {
                return false
            }
            _ = await activateOwningTerminal(sessionPid: pid)
            return false
        }

        guard let pid = session.pid else { return false }
        return await activateOwningTerminal(sessionPid: pid)
    }

    private func activateOwningTerminal(sessionPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
            forProcess: sessionPid,
            tree: tree
        ) else {
            return false
        }

        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: pid_t(terminalPid))?
                .activate(options: [.activateAllWindows]) ?? false
        }
        guard activated else { return false }

        let outcome = await FocusVerificationPolicy.evaluate {
            await TerminalVisibilityDetector.isSessionFocused(
                sessionPid: sessionPid
            )
        }
        return outcome == .success
    }
}
