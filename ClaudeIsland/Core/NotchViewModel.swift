//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published private(set) var visibleSessionCount: Int = 0
    @Published private var compactApprovalSessionId: String?

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let claudeDirSelector = ClaudeDirSelector.shared
    let preferences = NotchPreferences.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        let configuredWidth = min(
            max(CGFloat(preferences.panelWidth), 480),
            screenRect.width - 48
        )
        let configuredHeight = min(
            max(CGFloat(preferences.panelHeight), 360),
            windowHeight - 32
        )

        switch contentType {
        case .chat(let session)
            where compactApprovalSessionId == session.sessionId:
            return CGSize(
                width: min(configuredWidth, 500),
                height: min(configuredHeight, 360)
            )
        case .chat:
            return CGSize(width: configuredWidth, height: configuredHeight)
        case .menu:
            // The in-notch control center is intentionally compact. Detailed
            // preferences live in the standalone Notch Studio window.
            return CGSize(
                width: configuredWidth,
                height: min(configuredHeight, 390)
            )
        case .instances:
            let listHeight: CGFloat = visibleSessionCount == 0
                ? 82
                : CGFloat(visibleSessionCount) * 58 + 8
            let contentDrivenHeight = max(180, 70 + listHeight)

            return CGSize(
                width: configuredWidth,
                height: min(configuredHeight, contentDrivenHeight)
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        claudeDirSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        preferences.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A control should take effect while the pointer is already over the
        // notch too. Without this, changing a delay only affects a later
        // enter/leave cycle and makes the setting look decorative.
        preferences.$expandOnHover
            .combineLatest(
                preferences.$hoverDelay,
                preferences.$collapseOnMouseLeave,
                preferences.$collapseDelay
            )
            .dropFirst()
            .sink { [weak self] _, _, _, _ in
                self?.reschedulePointerTransition()
            }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private var compactLeftHitExtension: CGFloat {
        CompactNotchMetrics.wingWidth(
            for: preferences.compactStyle,
            configuredWidth: preferences.compactWidth
        )
    }

    private var compactRightHitExtension: CGFloat {
        CompactNotchMetrics.wingWidth(
            for: preferences.compactStyle,
            configuredWidth: preferences.compactWidth
        )
    }

    private func isPointInCompactNotch(_ location: CGPoint) -> Bool {
        geometry.isPointInNotch(
            location,
            leftExtension: compactLeftHitExtension,
            rightExtension: compactRightHitExtension
        )
    }

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = isPointInCompactNotch(location)
        let inOpened =
            status == .opened &&
            geometry.isPointNearOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        schedulePointerTransition()
    }

    /// Schedules the appropriate transition using the *current* preferences.
    /// Both mouse movement and a live Settings change call this so Studio's
    /// sliders are genuinely live controls rather than persisted-only values.
    private func schedulePointerTransition() {
        hoverTimer?.cancel()
        hoverTimer = nil

        if isHovering,
           preferences.expandOnHover,
           (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, preferences.hoverDelay),
                execute: workItem
            )
        } else if !isHovering,
                  preferences.collapseOnMouseLeave,
                  status == .opened {
            // Wait until the pointer has stayed fully outside the expanded
            // boundary. This avoids collapsing while crossing rounded edges
            // or moving toward nearby menu-bar controls.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isHovering,
                      self.status == .opened else { return }
                self.notchClose()
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, preferences.collapseDelay),
                execute: workItem
            )
        }
    }

    private func reschedulePointerTransition() {
        schedulePointerTransition()
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Header controls (including Quick Controls) live beside the
                // physical notch. Do not let the global mouse monitor close
                // the panel before their SwiftUI button actions are delivered.
                // Users can still close via outside click or mouse-leave.
                return
            }
        case .closed, .popping:
            if isPointInCompactNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
        compactApprovalSessionId = nil
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        compactApprovalSessionId = nil
        contentType = contentType == .menu ? .instances : .menu
    }

    func updateVisibleSessionCount(_ count: Int) {
        visibleSessionCount = max(0, count)
    }

    func showChat(for session: SessionState) {
        compactApprovalSessionId = nil
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Open a permission request in a smaller, scrollable conversation panel.
    /// The normal chat size remains available when the user opens it manually.
    func showApproval(for session: SessionState) {
        openReason = .notification
        currentChatSession = nil
        compactApprovalSessionId = session.sessionId
        contentType = .chat(session)
        status = .opened
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        compactApprovalSessionId = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
