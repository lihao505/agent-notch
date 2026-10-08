//
//  Modified by lihao505 for Agent Notch, 2026.
//  TmuxTarget.swift
//  ClaudeIsland
//
//  Data model for tmux session/window/pane targeting
//

import Foundation

/// Represents a tmux target (session:window.pane)
struct TmuxTarget: Sendable {
    let session: String
    let window: String
    let pane: String
    /// Stable for the pane's lifetime in one tmux server. Indexes can be reused
    /// after another pane closes, so discovered targets must send by this ID.
    let paneID: String?

    nonisolated var targetString: String {
        paneID ?? "\(session):\(window).\(pane)"
    }

    nonisolated init(session: String, window: String, pane: String) {
        self.session = session
        self.window = window
        self.pane = pane
        self.paneID = nil
    }

    /// Parse from tmux target string format "session:window.pane"
    nonisolated init?(from targetString: String, paneID: String? = nil) {
        if let paneID {
            guard paneID.hasPrefix("%"), paneID.count > 1,
                  paneID.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else {
                return nil
            }
        }
        let sessionSplit = targetString.split(separator: ":", maxSplits: 1)
        guard sessionSplit.count == 2 else { return nil }

        let session = String(sessionSplit[0])
        let windowPane = String(sessionSplit[1])

        let paneSplit = windowPane.split(separator: ".", maxSplits: 1)
        guard paneSplit.count == 2 else { return nil }

        self.session = session
        self.window = String(paneSplit[0])
        self.pane = String(paneSplit[1])
        self.paneID = paneID
    }
}
