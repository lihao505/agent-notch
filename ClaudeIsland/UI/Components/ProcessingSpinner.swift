//
//  Modified by lihao505 for Agent Notch, 2026.
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import SwiftUI

struct ProcessingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color: Color
    private let frameInterval: TimeInterval = 0.15

    init(color: Color = Color(red: 0.85, green: 0.47, blue: 0.34)) {
        self.color = color
    }

    var body: some View {
        Group {
            if reduceMotion {
                symbol(at: 1)
            } else {
                // TimelineView is lifecycle-aware and only invalidates this
                // tiny subtree. A Combine timer in every row woke the parent
                // view even when the indicator was off-screen.
                TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                    symbol(at: phase(at: context.date))
                }
            }
        }
    }

    private func symbol(at phase: Int) -> some View {
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .frame(width: 12, alignment: .center)
    }

    private func phase(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / frameInterval) % symbols.count
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
