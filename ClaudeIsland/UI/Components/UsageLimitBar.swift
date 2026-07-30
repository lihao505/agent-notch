//
//  UsageLimitBar.swift
//  ClaudeIsland
//
//  Compact subscription usage shown at the top of the opened notch.
//

import SwiftUI

struct UsageLimitBar: View {
    let snapshot: UsageLimitSnapshot

    @AppStorage("usageDisplayRemaining") private var displayRemaining = false

    var body: some View {
        HStack(spacing: 5) {
            AgentBadge(source: snapshot.source)

            if let primary = snapshot.primary {
                windowRow(primary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                displayRemaining.toggle()
            }
        }
        .help(displayRemaining ? "显示已用量" : "显示剩余量")
    }

    private func windowRow(_ window: UsageLimitWindow) -> some View {
        let percent = displayRemaining
            ? window.remainingPercent
            : window.usedPercent

        return HStack(spacing: 4) {
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(progressColor(percent))

            Label {
                Text(resetText(window.resetsAt))
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.system(size: 7.5, design: .rounded))
            .foregroundColor(.white.opacity(0.40))
        }
        .frame(height: 9)
    }

    private func resetText(_ date: Date) -> String {
        let remaining = max(0, date.timeIntervalSinceNow)
        if remaining >= 86_400 {
            let days = Int(remaining / 86_400)
            let hours = Int(remaining.truncatingRemainder(
                dividingBy: 86_400
            ) / 3_600)
            return "\(days)d\(hours)h"
        }
        if remaining >= 3_600 {
            let hours = Int(remaining / 3_600)
            let minutes = Int(remaining.truncatingRemainder(
                dividingBy: 3_600
            ) / 60)
            return "\(hours)h\(minutes)m"
        }
        return "\(Int(remaining / 60))m"
    }

    private func progressColor(_ percent: Double) -> Color {
        switch percent {
        case 85...:
            return TerminalColors.red
        case 65...:
            return TerminalColors.amber
        default:
            return snapshot.source.accentColor
        }
    }
}
