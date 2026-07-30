//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchHeaderView.swift
//  ClaudeIsland
//
//  Header bar for the dynamic island
//

import AppKit
import Foundation
import SwiftUI

enum VibePetMotion: Equatable {
    case idle
    case working
    case waiting
    case ready
}

private struct VibePetAnimation {
    let frameNames: [String]
    let frameDurations: [TimeInterval]

    var duration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    func frameIndex(at date: Date) -> Int {
        guard !frameNames.isEmpty, duration > 0 else { return 0 }

        var elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration)

        for (index, frameDuration) in frameDurations.enumerated() {
            if elapsed < frameDuration {
                return min(index, frameNames.count - 1)
            }
            elapsed -= frameDuration
        }

        return frameNames.count - 1
    }
}

@MainActor
struct VibePetIcon: View {
    let size: CGFloat
    let motion: VibePetMotion
    private static var frameCache: [String: NSImage] = [:]
    private static let idlePauseRange = 18.0...36.0
    private static let rareGlancePauseRange = 45.0...90.0

    @State private var idleHeldFrameIndex = Int.random(in: 0..<7)
    @State private var idlePlaybackStartedAt: Date?
    @State private var rareGlanceVisible = false

    init(
        size: CGFloat = 19,
        motion: VibePetMotion = .idle
    ) {
        self.size = size
        self.motion = motion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: timelineInterval)) { context in
            let frameName = displayedFrameName(at: context.date)

            if let frameImage = Self.frameImage(named: frameName) {
                ZStack {
                    Image(nsImage: frameImage)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(glowColor)
                        .blur(radius: 2.6)
                        .opacity(0.32)

                    Image(nsImage: frameImage)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                        .aspectRatio(contentMode: .fit)
                        .shadow(
                            color: glowColor.opacity(0.46),
                            radius: 1.1
                        )
                        .shadow(
                            color: glowColor.opacity(0.18),
                            radius: 3.0
                        )
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: motion) {
            await runIdlePlaybackSchedule()
        }
        .task(id: motion) {
            await runRareGlanceSchedule()
        }
        .accessibilityHidden(true)
    }

    private static func frameImage(named name: String) -> NSImage? {
        if let cached = frameCache[name] {
            return cached
        }

        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "png"
        ),
        let image = NSImage(contentsOf: url) else {
            return nil
        }

        frameCache[name] = image
        return image
    }

    private var timelineInterval: TimeInterval {
        switch motion {
        case .working:
            return 2.0 / 3.0
        case .waiting:
            return 0.5
        case .idle, .ready:
            return 1.0
        }
    }

    private var glowColor: Color {
        switch motion {
        case .idle:
            return Color(red: 0.26, green: 0.78, blue: 0.48)
        case .working:
            return Color(red: 0.36, green: 0.64, blue: 0.88)
        case .waiting, .ready:
            return Color(red: 0.90, green: 0.58, blue: 0.32)
        }
    }

    private var glanceFrameIndex: Int {
        switch motion {
        case .idle:
            return 3
        case .working:
            return 2
        case .waiting, .ready:
            return 4
        }
    }

    private var regularAnimation: VibePetAnimation {
        let regularIndices = animation.frameNames.indices.filter {
            $0 != glanceFrameIndex
        }
        return VibePetAnimation(
            frameNames: regularIndices.map { animation.frameNames[$0] },
            frameDurations: regularIndices.map { animation.frameDurations[$0] }
        )
    }

    private func displayedFrameName(at date: Date) -> String {
        if rareGlanceVisible {
            return animation.frameNames[glanceFrameIndex]
        }

        guard motion == .idle else {
            return regularAnimation.frameNames[
                regularAnimation.frameIndex(at: date)
            ]
        }

        guard let playbackStartedAt = idlePlaybackStartedAt else {
            return regularAnimation.frameNames[
                min(idleHeldFrameIndex, regularAnimation.frameNames.count - 1)
            ]
        }

        let elapsed = max(0, date.timeIntervalSince(playbackStartedAt))
        let frameIndex = min(
            Int(elapsed / timelineInterval),
            regularAnimation.frameNames.count - 1
        )
        return regularAnimation.frameNames[frameIndex]
    }

    private func runIdlePlaybackSchedule() async {
        guard motion == .idle else {
            idlePlaybackStartedAt = nil
            return
        }

        idlePlaybackStartedAt = nil
        idleHeldFrameIndex = Int.random(in: regularAnimation.frameNames.indices)

        while !Task.isCancelled {
            do {
                let pause = Double.random(in: Self.idlePauseRange)
                try await Task.sleep(
                    nanoseconds: UInt64(pause * 1_000_000_000)
                )
                try Task.checkCancellation()

                idlePlaybackStartedAt = Date()
                try await Task.sleep(
                    nanoseconds: UInt64(
                        regularAnimation.duration * 1_000_000_000
                    )
                )
                try Task.checkCancellation()

                idleHeldFrameIndex = Int.random(
                    in: regularAnimation.frameNames.indices
                )
                idlePlaybackStartedAt = nil
            } catch {
                return
            }
        }
    }

    private func runRareGlanceSchedule() async {
        rareGlanceVisible = false

        while !Task.isCancelled {
            do {
                let pause = Double.random(in: Self.rareGlancePauseRange)
                try await Task.sleep(
                    nanoseconds: UInt64(pause * 1_000_000_000)
                )
                try Task.checkCancellation()

                rareGlanceVisible = true
                try await Task.sleep(
                    nanoseconds: UInt64(timelineInterval * 1_000_000_000)
                )
                try Task.checkCancellation()
                rareGlanceVisible = false
            } catch {
                rareGlanceVisible = false
                return
            }
        }
    }

    private var animation: VibePetAnimation {
        switch motion {
        case .idle:
            return VibePetAnimation(
                frameNames: (0...7).map {
                    String(
                        format: "dense-%02d-idle-green-f%d",
                        $0,
                        $0 + 1
                    )
                },
                frameDurations: Array(repeating: 1.0, count: 8)
            )
        case .working:
            return VibePetAnimation(
                frameNames: (8...15).map {
                    String(
                        format: "dense-%02d-working-blue-f%d",
                        $0,
                        $0 - 7
                    )
                },
                frameDurations: Array(repeating: 2.0 / 3.0, count: 8)
            )
        case .waiting:
            return VibePetAnimation(
                frameNames: (16...23).map {
                    String(
                        format: "dense-%02d-waiting-orange-f%d",
                        $0,
                        $0 - 15
                    )
                },
                frameDurations: Array(repeating: 0.5, count: 8)
            )
        case .ready:
            return VibePetAnimation(
                frameNames: (16...23).map {
                    String(
                        format: "dense-%02d-waiting-orange-f%d",
                        $0,
                        $0 - 15
                    )
                },
                frameDurations: Array(repeating: 1.0, count: 8)
            )
        }
    }
}

/// A tiny state companion that sits beside the pet. Its silhouettes and
/// slower cadence deliberately differ from the 3x3 comet on the far right.
struct PetStateSignalIcon: View {
    let motion: VibePetMotion
    let size: CGFloat

    init(motion: VibePetMotion, size: CGFloat = 15) {
        self.motion = motion
        self.size = size
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { context in
            let phase = Int(
                context.date.timeIntervalSinceReferenceDate / interval
            )
            let breathingOpacity = waitingOpacity(at: context.date)

            Canvas { canvas, _ in
                if motion == .waiting {
                    let diameter: CGFloat = 5
                    canvas.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: (size - diameter) / 2,
                                y: (size - diameter) / 2,
                                width: diameter,
                                height: diameter
                            )
                        ),
                        with: .color(color.opacity(breathingOpacity))
                    )
                } else {
                    for pixel in pixels(for: phase) {
                        canvas.fill(
                            Path(
                                CGRect(
                                    x: pixel.x,
                                    y: pixel.y,
                                    width: 4,
                                    height: 4
                                )
                            ),
                            with: .color(color.opacity(pixel.opacity))
                        )
                    }
                }
            }
            .shadow(
                color: color.opacity(
                    motion == .waiting
                        ? 0.16 + breathingOpacity * 0.34
                        : 0.42
                ),
                radius: motion == .waiting ? 1.5 : 1.2
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var interval: TimeInterval {
        switch motion {
        case .working: return 0.5
        case .waiting: return 1.0 / 30.0
        case .idle: return 1
        case .ready: return 2
        }
    }

    private func waitingOpacity(at date: Date) -> Double {
        guard motion == .waiting else { return 1 }
        let cycleDuration = 2.4
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
            / cycleDuration
        let wave = (sin(progress * 2 * .pi - .pi / 2) + 1) / 2
        return 0.18 + wave * 0.82
    }

    private var color: Color {
        switch motion {
        case .idle:
            return Color(red: 0.26, green: 0.78, blue: 0.48)
        case .working:
            return Color(red: 0.36, green: 0.64, blue: 0.88)
        case .waiting, .ready:
            return Color(red: 0.90, green: 0.58, blue: 0.32)
        }
    }

    private func pixels(for phase: Int) -> [(x: CGFloat, y: CGFloat, opacity: Double)] {
        switch motion {
        case .idle:
            // A calm vertical breath: no chasing motion that could imply work.
            let active = abs(phase % 4 - 2)
            return (0..<3).map { index -> (x: CGFloat, y: CGFloat, opacity: Double) in
                let y = CGFloat(index * 5)
                let opacity: Double = index == active ? 0.95 : 0.34
                return (x: 5, y: y, opacity: opacity)
            }
        case .working:
            // A short rising staircase, visibly different from the comet loop.
            let active = phase % 3
            return (0..<3).map { index -> (x: CGFloat, y: CGFloat, opacity: Double) in
                let x = CGFloat(index * 5)
                let y = CGFloat(10 - index * 5)
                let opacity: Double = index == active ? 1.0 : 0.30
                return (x: x, y: y, opacity: opacity)
            }
        case .waiting:
            return []
        case .ready:
            // Completion is deliberately still; the far-right check owns it.
            return [
                (x: 5, y: 0, opacity: 0.72),
                (x: 0, y: 5, opacity: 0.72),
                (x: 10, y: 5, opacity: 0.72),
                (x: 5, y: 10, opacity: 0.72),
            ]
        }
    }
}

/// A purpose-built signal for narrow compact notches. It uses a fixed 7×7
/// logical grid and fewer, larger pixels than the full companion.
struct CompactPetCompanionIcon: View {
    let motion: VibePetMotion
    let size: CGFloat

    init(motion: VibePetMotion, size: CGFloat = 14) {
        self.motion = motion
        self.size = size
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = Int(elapsed / interval)
            let breath = (sin(elapsed * .pi) + 1) / 2

            Canvas { canvas, _ in
                for pixel in pixels(phase: phase, breath: breath) {
                    canvas.fill(
                        Path(
                            CGRect(
                                x: (pixel.x + 1) * unit,
                                y: (pixel.y + 1) * unit,
                                width: unit,
                                height: unit
                            )
                        ),
                        with: .color(color.opacity(pixel.opacity))
                    )
                }
            }
            .shadow(color: color.opacity(0.32), radius: 0.8)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var unit: CGFloat {
        max(1, floor(size / 7))
    }

    private var interval: TimeInterval {
        switch motion {
        case .working: return 0.24
        case .waiting: return 1.0 / 30.0
        case .idle: return 1.4
        case .ready: return 2
        }
    }

    private var color: Color {
        switch motion {
        case .idle:
            return Color(red: 0.26, green: 0.78, blue: 0.48)
        case .working:
            return Color(red: 0.36, green: 0.64, blue: 0.88)
        case .waiting, .ready:
            return Color(red: 0.90, green: 0.58, blue: 0.32)
        }
    }

    private func pixels(
        phase: Int,
        breath: Double
    ) -> [(x: CGFloat, y: CGFloat, opacity: Double)] {
        switch motion {
        case .idle:
            return [
                (2, 2, 0.34),
                (2, 4, phase.isMultiple(of: 2) ? 0.72 : 0.44),
            ]
        case .working:
            let active = phase % 3
            let firstOpacity = active == 0 ? 1.0 : 0.26
            let secondOpacity = active == 1 ? 1.0 : 0.26
            let thirdOpacity = active == 2 ? 1.0 : 0.26
            return [
                (0, 4, firstOpacity),
                (2, 2, secondOpacity),
                (4, 0, thirdOpacity),
            ]
        case .waiting:
            return [(2, 2, 0.22 + breath * 0.78)]
        case .ready:
            return [
                (2, 0, 0.78),
                (0, 2, 0.78),
                (4, 2, 0.78),
                (2, 4, 0.78),
            ]
        }
    }
}

/// Quiet, static pixel marker used when no agent needs attention.
/// It deliberately never pulses: motion on the right edge always means work.
struct IdlePixelIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green.opacity(0.72)) {
        self.size = size
        self.color = color
    }

    private let pixels: [(CGFloat, CGFloat)] = [
        (15, 3), (15, 7),
        (7, 15), (11, 15), (15, 15), (19, 15), (23, 15),
        (15, 19), (15, 23),
    ]

    var body: some View {
        Canvas { context, _ in
            let scale = size / 30
            let pixelSize = 4 * scale

            for (x, y) in pixels {
                context.fill(
                    Path(
                        CGRect(
                            x: x * scale - pixelSize / 2,
                            y: y * scale - pixelSize / 2,
                            width: pixelSize,
                            height: pixelSize
                        )
                    ),
                    with: .color(color)
                )
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}
