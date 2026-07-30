//
//  PixelLoaderIcon.swift
//  ClaudeIsland
//
//  Compact pixel-art loader used on the right side of the notch.
//

import AppKit
import SwiftUI

@MainActor
struct PixelLoaderIcon: View {
    let size: CGFloat

    private static let framesPerSecond: TimeInterval = 8
    private static let frameDuration: TimeInterval = 1 / framesPerSecond
    private static var frameCache: [String: NSImage] = [:]

    init(size: CGFloat = 19) {
        self.size = size
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameDuration)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let frameIndex =
                Int(elapsed / Self.frameDuration) % Self.frameNames.count
            let frameName = Self.frameNames[frameIndex]

            if let frameImage = Self.frameImage(named: frameName) {
                Image(nsImage: frameImage)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .aspectRatio(contentMode: .fit)
                    .saturation(1.20)
                    .contrast(1.08)
                    .brightness(-0.02)
                    .shadow(
                        color: Self.glowColor,
                        radius: 1.3,
                        x: 0,
                        y: 0
                    )
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let glowColor = Color(
        red: 0.16,
        green: 0.48,
        blue: 0.92
    ).opacity(0.28)
    private static let frameNames = (0...7).map {
        String(format: "%02d-blue-f%d", $0, $0 + 1)
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
}

/// A calm amber orbit for "waiting for input". Rendering and movement speed
/// are independent: it refreshes at 30fps, but takes 3.2 seconds per orbit,
/// so it is smooth while remaining slower than the blue working comet.
@MainActor
struct WaitingPixelIndicatorIcon: View {
    let size: CGFloat

    init(size: CGFloat = 19) {
        self.size = size
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.orbitDuration)
                / Self.orbitDuration
            Canvas { canvas, _ in
                let scale = size / 20
                let block = 4 * scale
                let center = size / 2
                let radius = 7 * scale
                for trailIndex in 0..<3 {
                    let angle =
                        progress * 2 * Double.pi
                        - Double.pi / 2
                        - Double(trailIndex) * 0.38
                    let opacity = [1.0, 0.52, 0.22][trailIndex]
                    canvas.fill(
                        Path(
                            CGRect(
                                x: center
                                    + CGFloat(cos(angle)) * radius
                                    - block / 2,
                                y: center
                                    + CGFloat(sin(angle)) * radius
                                    - block / 2,
                                width: block,
                                height: block
                            )
                        ),
                        with: .color(
                            Self.color.opacity(opacity)
                        )
                    )
                }
            }
            .shadow(
                color: Self.color.opacity(0.32),
                radius: 1.4
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let color = Color(
        red: 0.95,
        green: 0.45,
        blue: 0.12
    )
    private static let orbitDuration: TimeInterval = 3.2
}

#Preview {
    HStack {
        PixelLoaderIcon()
        WaitingPixelIndicatorIcon()
    }
    .padding()
    .background(.black)
}
