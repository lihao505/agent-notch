//
//  TerminalColors.swift
//  ClaudeIsland
//
//  Color palette for terminal-style UI
//

import SwiftUI

struct TerminalColors {
    static let green = Color(red: 0.26, green: 0.78, blue: 0.48)
    static let amber = Color(red: 0.90, green: 0.58, blue: 0.32)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let cyan = Color(red: 0.0, green: 0.8, blue: 0.8)
    static let blue = Color(red: 0.36, green: 0.64, blue: 0.88)
    static let magenta = Color(red: 0.8, green: 0.4, blue: 0.8)
    static let dim = Color.white.opacity(0.4)
    static let dimmer = Color.white.opacity(0.2)
    static let prompt = Color(red: 0.85, green: 0.47, blue: 0.34)  // #d97857
    static let background = Color.white.opacity(0.05)
    static let backgroundHover = Color.white.opacity(0.1)
}
