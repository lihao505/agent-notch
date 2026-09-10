//
//  TmuxController.swift
//  ClaudeIsland
//
//  High-level tmux operations controller
//

import Foundation

/// Controller for tmux operations
actor TmuxController {
    static let shared = TmuxController()

    private init() {}

    func findTmuxTarget(forClaudePid pid: Int) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forClaudePid: pid)
    }

    func findTmuxTarget(forWorkingDirectory dir: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forWorkingDirectory: dir)
    }

    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }

    func approveOnce(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(target: target)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(target: target)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(target: target, message: message)
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-window", "-t", "\(target.session):\(target.window)"
            ])

            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-pane", "-t", target.targetString
            ])

            let outcome = await FocusVerificationPolicy.evaluate {
                await self.isTargetActive(target, tmuxPath: tmuxPath)
            }
            return outcome == .success
        } catch {
            return false
        }
    }

    /// `select-window` and `select-pane` can exit successfully before an
    /// attached client reflects the new target. Verify both dimensions so an
    /// inactive pane in the right session is not treated as a successful jump.
    private func isTargetActive(_ target: TmuxTarget, tmuxPath: String) async -> Bool {
        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "display-message",
                "-p",
                "-t", target.targetString,
                "#{window_active}:#{pane_active}",
            ])
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1:1"
        } catch {
            return false
        }
    }
}
