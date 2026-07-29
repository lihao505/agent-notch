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
        HStack(spacing: 8) {
            AgentBadge(source: snapshot.source)

            if let primary = snapshot.primary {
                windowRow(primary)
            }
            if snapshot.primary != nil, snapshot.secondary != nil {
                Text("|")
                    .font(.system(size: 9, weight: .light))
                    .foregroundColor(.white.opacity(0.18))
            }
            if let secondary = snapshot.secondary {
                windowRow(secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
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

        return HStack(spacing: 7) {
            Text(windowLabel(window.windowMinutes))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.48))

            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(progressColor(percent))

            Text(resetText(window.resetsAt))
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.34))
        }
        .frame(height: 10)
    }

    private func windowLabel(_ minutes: Int) -> String {
        if minutes >= 10_080 { return "7d" }
        if minutes >= 1_440 { return "\(minutes / 1_440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
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
