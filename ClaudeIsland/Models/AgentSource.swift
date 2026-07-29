//
//  AgentSource.swift
//  ClaudeIsland
//
//  Visual identity for coding agents connected through the hook socket.
//

import SwiftUI

enum AgentSource: String, Equatable, Sendable {
    case claude
    case codex
    case codebuddy
    case gemini
    case cursor
    case unknown

    nonisolated init(hookValue: String?) {
        self = AgentSource(rawValue: hookValue?.lowercased() ?? "") ?? .unknown
    }

    nonisolated var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .codebuddy: return "CodeBuddy"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .unknown: return "Agent"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .codebuddy: return "pawprint.fill"
        case .gemini: return "diamond.fill"
        case .cursor: return "cursorarrow.rays"
        case .unknown: return "terminal"
        }
    }

    nonisolated var accentColor: Color {
        switch self {
        case .claude:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:
            return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .codebuddy:
            return Color(red: 0.94, green: 0.34, blue: 0.30)
        case .gemini:
            return Color(red: 0.36, green: 0.56, blue: 0.96)
        case .cursor:
            return Color(red: 0.65, green: 0.48, blue: 0.96)
        case .unknown:
            return Color.white.opacity(0.65)
        }
    }
}
