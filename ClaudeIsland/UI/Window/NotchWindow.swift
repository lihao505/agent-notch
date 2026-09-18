//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchWindow.swift
//  ClaudeIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    /// Mirrors the view model's opened state so a pass-through click can
    /// restore the correct hit-testing mode after it is re-posted.
    var shouldAcceptMouseEvents = false

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    override func sendEvent(_ event: NSEvent) {
        // For mouse events, check if we should pass through
        if event.type == .leftMouseDown || event.type == .leftMouseUp ||
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            // Check if any view wants to handle this event
            if let contentView = self.contentView,
               contentView.hitTest(
                    contentView.superview?.convert(event.locationInWindow, from: nil)
                        ?? event.locationInWindow
               ) == nil,
               let forwardedEvent = Self.passThroughEvent(from: event) {
                // No view wants this event - pass it through to windows behind
                // by temporarily ignoring mouse events and re-posting
                ignoresMouseEvents = true

                // Re-post the event after a tiny delay
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    forwardedEvent.post(tap: .cghidEventTap)

                    // A pass-through click must not leave the opened panel
                    // permanently click-through. This used to make the next
                    // click on the chat input (or any button) disappear
                    // after the user clicked just outside the panel.
                    self.ignoresMouseEvents = !self.shouldAcceptMouseEvents
                }
                return
            }

            // A nonactivating panel can remain key-less when the app was
            // opened by a background notification. Once the user clicks a
            // real control, explicitly promote the panel so TextField and
            // keyboard events work on the first attempt.
            if event.type == .leftMouseDown {
                NSApp.activate(ignoringOtherApps: false)
                makeKey()
            }
        }

        super.sendEvent(event)
    }

    /// Copy only an intercepted event, preserving its original screen location,
    /// button, modifiers and click count. NSScreen.main is the key-window screen,
    /// not necessarily the primary display that defines Quartz coordinates.
    static func passThroughEvent(from event: NSEvent) -> CGEvent? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            return event.cgEvent?.copy()
        default:
            return nil
        }
    }
}
