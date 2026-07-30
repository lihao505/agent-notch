//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    /// The rendered SwiftUI panel includes the corner/padding wings outside
    /// `openedSize.width`. Keep global hover/click geometry aligned with the
    /// AppKit hosting view so controls near either edge remain interactive.
    nonisolated static let openedPanelHorizontalHitExpansion: CGFloat = 52
    nonisolated static let openedPanelVerticalHitExpansion: CGFloat = 32

    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        let width =
            size.width + Self.openedPanelHorizontalHitExpansion
        let height =
            size.height + Self.openedPanelVerticalHitExpansion
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - height,
            width: width,
            height: height
        )
    }

    /// Check if a point is in the notch area, including asymmetric compact
    /// wings and a small interaction margin.
    func isPointInNotch(
        _ point: CGPoint,
        leftExtension: CGFloat = 0,
        rightExtension: CGFloat = 0
    ) -> Bool {
        var rect = notchScreenRect
        rect.origin.x -= leftExtension + 8
        rect.size.width += leftExtension + rightExtension + 16
        rect = rect.insetBy(dx: 0, dy: -6)
        return rect.contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// A forgiving hover boundary prevents rounded corners and one-frame
    /// pointer gaps from collapsing the panel before the cursor is fully away.
    func isPointNearOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size)
            .insetBy(dx: -16, dy: -14)
            .contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}
