//
//  AgentBadge.swift
//  ClaudeIsland
//

import SwiftUI

struct AgentBadge: View {
    let source: AgentSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.symbolName)
                .font(.system(size: 8, weight: .bold))

            Text(source.displayName)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(source.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(source.accentColor.opacity(0.14))
        .overlay(
            Capsule()
                .strokeBorder(source.accentColor.opacity(0.28), lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .accessibilityLabel("\(source.displayName) session")
    }
}
