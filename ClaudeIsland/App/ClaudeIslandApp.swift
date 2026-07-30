//
//  Modified by lihao505 for Agent Notch, 2026.
//  ClaudeIslandApp.swift
//  ClaudeIsland
//
//  Dynamic Island for monitoring Claude Code instances
//

import SwiftUI

@main
struct ClaudeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            NotchStudioSettingsView()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Agent Notch Settings…") {
                    appDelegate.showDetailedSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
