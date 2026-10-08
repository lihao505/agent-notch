//
//  Modified by lihao505 for Agent Notch, 2026.
//  TmuxTargetFinder.swift
//  ClaudeIsland
//
//  Finds tmux targets for Claude processes
//

import Foundation

/// Finds tmux session/window/pane targets for Claude processes
actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    private let commandRunner: @Sendable ([String]) async -> String?
    private let processTreeProvider: @Sendable () -> [Int: ProcessInfo]

    init(
        commandRunner: @escaping @Sendable ([String]) async -> String? = { args in
            guard let path = await TmuxPathFinder.shared.getTmuxPath() else { return nil }
            // GUI/test processes may have a C locale. tmux otherwise replaces
            // control separators (and non-ASCII metadata) with underscores.
            return try? await ProcessExecutor.shared.run(path, arguments: ["-u"] + args)
        },
        processTreeProvider: @escaping @Sendable () -> [Int: ProcessInfo] = {
            ProcessTreeBuilder.shared.buildTree(forceRefresh: true)
        }
    ) {
        self.commandRunner = commandRunner
        self.processTreeProvider = processTreeProvider
    }

    /// Find the tmux target for a given Claude PID
    func findTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        guard claudePid > 0,
              let records = await paneRecords(field: "pane_pid") else {
            return nil
        }
        let tree = processTreeProvider()
        var matches: [PaneRecord] = []
        for record in records {
            guard let panePID = Int(record.value), panePID > 0 else { return nil }
            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: panePID, tree: tree) {
                matches.append(record)
            }
        }
        return uniqueTarget(in: matches)
    }

    /// Find the tmux target for a given working directory
    func findTarget(forWorkingDirectory workingDir: String) async -> TmuxTarget? {
        guard !workingDir.isEmpty,
              let records = await paneRecords(field: "pane_current_path") else { return nil }
        return uniqueTarget(in: records.filter { $0.value == workingDir })
    }

    func findTarget(forTTY tty: String) async -> TmuxTarget? {
        let normalized = tty.replacingOccurrences(of: "/dev/", with: "")
        guard !normalized.isEmpty,
              let records = await paneRecords(field: "pane_tty") else { return nil }
        return uniqueTarget(in: records.filter {
            $0.value.replacingOccurrences(of: "/dev/", with: "") == normalized
        })
    }

    /// A known PID is an identity constraint, not a hint. Failure to locate it
    /// must not fall through to an unrelated pane that shares the same cwd.
    func findTarget(for session: SessionState) async -> TmuxTarget? {
        if let pid = session.pid { return await findTarget(forClaudePid: pid) }
        if let tty = session.tty { return await findTarget(forTTY: tty) }
        return await findTarget(forWorkingDirectory: session.cwd)
    }

    /// Check if a session's tmux pane is currently the active pane
    func isSessionPaneActive(claudePid: Int) async -> Bool {
        // Find which pane the Claude session is in
        guard let sessionTarget = await findTarget(forClaudePid: claudePid) else {
            return false
        }

        // Get the currently active pane
        guard let output = await commandRunner([
            "display-message", "-p", "#{pane_id}"
        ]) else {
            return false
        }

        let activeTarget = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTarget.paneID == activeTarget
    }

    private struct PaneRecord {
        let target: TmuxTarget
        let value: String
    }

    private func paneRecords(field: String) async -> [PaneRecord]? {
        // Tabs preserve ordinary spaces in session names and working dirs.
        // If the metadata itself contains a delimiter, fail closed rather than
        // treating a partially parsed list as a unique target.
        guard let output = await commandRunner([
            "list-panes", "-a", "-F",
            "#{session_name}:#{window_index}.#{pane_index}\t#{pane_id}\t#{\(field)}"
        ]) else { return nil }
        var records: [PaneRecord] = []
        var valuesByPaneID: [String: String] = [:]
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3,
                  let target = TmuxTarget(from: parts[0], paneID: parts[1]) else { return nil }
            if let existing = valuesByPaneID[parts[1]], existing != parts[2] { return nil }
            valuesByPaneID[parts[1]] = parts[2]
            records.append(PaneRecord(target: target, value: parts[2]))
        }
        return records
    }

    private func uniqueTarget(in records: [PaneRecord]) -> TmuxTarget? {
        // A linked window may list the same physical pane more than once.
        // Deduplicate by stable ID, never by cwd or an index-based address.
        guard Set(records.compactMap { $0.target.paneID }).count == 1 else { return nil }
        return records.first?.target
    }
}
