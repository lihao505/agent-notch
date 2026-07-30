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
            AgentUsageIcon(source: snapshot.source)

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

/// A compact quota-source mark that does not depend on a tiny SF Symbol being
/// available on the current macOS release. Codex uses a custom-drawn code
/// glyph; the remaining sources use stable, high-contrast system marks.
private struct AgentUsageIcon: View {
    let source: AgentSource

    var body: some View {
        ZStack {
            Circle()
                .fill(source.accentColor.opacity(0.18))

            if source == .codex {
                CodexUsageMark()
                    .stroke(
                        source.accentColor,
                        style: StrokeStyle(
                            lineWidth: 1.25,
                            lineCap: .square,
                            lineJoin: .miter
                        )
                    )
                    .padding(3.5)
            } else {
                Image(systemName: source.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(source.accentColor)
            }
        }
        .frame(width: 17, height: 17)
        .overlay {
            Circle()
                .strokeBorder(
                    source.accentColor.opacity(0.28),
                    lineWidth: 0.5
                )
        }
        .accessibilityLabel("\(source.displayName) usage")
    }
}

private struct CodexUsageMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.50))
        path.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.82))

        path.move(to: CGPoint(x: rect.width * 0.70, y: rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.width * 0.92, y: rect.height * 0.50))
        path.addLine(to: CGPoint(x: rect.width * 0.70, y: rect.height * 0.82))

        path.move(to: CGPoint(x: rect.width * 0.58, y: rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.92))
        return path
    }
}
