//
//  Modified by lihao505 for Agent Notch, 2026.
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    /// Immutable event-time coordinates, not the live cursor position when a
    /// subscriber eventually consumes its queued main-thread delivery.
    let mouseDown = PassthroughSubject<CGPoint, Never>()

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?

    init(startMonitors: Bool = true) {
        if startMonitors { setupMonitors() }
    }

    private func setupMonitors() {
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] event in
            guard let location = Self.screenLocation(of: event) else { return }
            self?.mouseLocation.send(location)
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            guard let location = Self.screenLocation(of: event) else { return }
            self?.mouseDown.send(location)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] event in
            guard let location = Self.screenLocation(of: event) else { return }
            self?.mouseLocation.send(location)
        }
        mouseDraggedMonitor?.start()
    }

    static func screenLocation(of event: NSEvent) -> CGPoint? {
        // AppKit's local event position is window-relative. Quartz already
        // exposes the original event in AppKit-compatible global coordinates,
        // including negative origins and displays above the primary display.
        if let quartzEvent = event.cgEvent {
            return quartzEvent.unflippedLocation
        }
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        // Never invent a click location from the current cursor as a fallback.
        return nil
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
    }
}
