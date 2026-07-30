//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var usageMonitor = UsageLimitMonitor.shared
    @StateObject private var preferences = NotchPreferences.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show while the compact completion reminder is active.
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) <
                    preferences.completionCompactDuration
            }
            return false
        }
    }

    private var compactTaskCount: Int {
        sessionMonitor.instances.count
    }

    private var leftWingWidth: CGFloat {
        CompactNotchMetrics.leftWingWidth
    }

    private var rightWingWidth: CGFloat {
        CompactNotchMetrics.rightWingWidth(
            for: preferences.compactStyle
        )
    }

    private var physicalNotchSideClearance: CGFloat {
        CompactNotchMetrics.userExtraWidth(
            for: preferences.compactWidth
        ) / 2
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0
        let compactBaseWidth =
            leftWingWidth +
            rightWingWidth +
            2 * physicalNotchSideClearance

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                return compactBaseWidth + permissionIndicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return compactBaseWidth + permissionIndicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return compactBaseWidth
        }

        // A persistent idle notch keeps the two animated edges visible. The
        // detailed style adds only the task counter, so an empty project never
        // produces an unnecessarily long island.
        if preferences.idleBehavior == .alwaysVisible {
            return compactBaseWidth
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        width: viewModel.status == .opened
                            ? notchSize.width
                            : closedContentWidth,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : 0
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.smooth, value: preferences.compactStyle)
                    .animation(
                        .spring(response: 0.34, dampingFraction: 0.86),
                        value: preferences.compactWidth
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            viewModel.updateVisibleSessionCount(sessionMonitor.instances.count)
            updateIdleVisibility()
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            viewModel.updateVisibleSessionCount(instances.count)
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: preferences.idleBehavior) { _, _ in
            updateIdleVisibility()
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing ||
            hasPendingPermission ||
            hasWaitingForInput ||
            preferences.idleBehavior == .alwaysVisible
    }

    private var petMotion: VibePetMotion {
        if hasPendingPermission { return .waiting }
        if hasWaitingForInput { return .ready }
        if isProcessing { return .working }
        return .idle
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains the pet and status indicator.
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                if preferences.showUsageLimits,
                   let usage = usageMonitor.snapshot {
                    UsageLimitBar(snapshot: usage)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 8)
                        .transition(
                            .move(edge: .top)
                                .combined(with: .opacity)
                        )
                }

                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - pet + optional permission indicator.
            if showClosedActivity {
                HStack(spacing: 4) {
                    VibePetIcon(size: 19, motion: petMotion)
                        .frame(
                            width: CompactNotchMetrics.animationCanvasSize,
                            height: CompactNotchMetrics.animationCanvasSize
                        )
                        .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showClosedActivity)

                    PetStateSignalIcon(motion: petMotion)

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(
                    width: viewModel.status == .opened
                        ? nil
                        : leftWingWidth +
                            (hasPendingPermission ? 18 : 0)
                )
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer (with optional bounce)
                Rectangle()
                    .fill(.black)
                    .frame(
                        width: closedNotchSize.width +
                            2 * physicalNotchSideClearance +
                            (isBouncing ? 16 : 0)
                    )
            }

            // Right side - state animation, with an optional compact task count.
            if showClosedActivity {
                HStack(spacing: 5) {
                    if viewModel.status != .opened,
                       preferences.compactStyle == .detailed {
                        HStack(spacing: 3) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 7, weight: .semibold))
                            Text("\(compactTaskCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                        .foregroundStyle(.white.opacity(0.58))
                        .accessibilityLabel(
                            preferences.language.text(
                                "\(compactTaskCount) tasks",
                                "\(compactTaskCount) 个任务"
                            )
                        )
                    }

                    if isProcessing {
                        PixelLoaderIcon(size: 19)
                            .frame(
                                width: CompactNotchMetrics.animationCanvasSize,
                                height: CompactNotchMetrics.animationCanvasSize
                            )
                            .matchedGeometryEffect(
                                id: "spinner",
                                in: activityNamespace,
                                isSource: showClosedActivity
                            )
                    } else if hasPendingPermission {
                        WaitingPixelIndicatorIcon(size: 19)
                            .frame(
                                width: CompactNotchMetrics.animationCanvasSize,
                                height: CompactNotchMetrics.animationCanvasSize
                            )
                            .matchedGeometryEffect(
                                id: "spinner",
                                in: activityNamespace,
                                isSource: showClosedActivity
                            )
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(
                            size: 14,
                            color: TerminalColors.green
                        )
                        .frame(
                            width: CompactNotchMetrics.animationCanvasSize,
                            height: CompactNotchMetrics.animationCanvasSize
                        )
                        .matchedGeometryEffect(
                            id: "spinner",
                            in: activityNamespace,
                            isSource: showClosedActivity
                        )
                    } else {
                        IdlePixelIndicatorIcon()
                            .frame(
                                width: CompactNotchMetrics.animationCanvasSize,
                                height: CompactNotchMetrics.animationCanvasSize
                            )
                    }
                }
                .frame(
                    width: viewModel.status == .opened
                        ? 20
                        : rightWingWidth
                )
            }
        }
        .frame(height: closedNotchSize.height)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show the idle pet here when the compact header is not active.
            // The compact header owns the pet while an activity is visible.
            if !showClosedActivity {
                VibePetIcon(size: 19)
                    .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                preferences.language == .simplifiedChinese
                    ? "快捷设置"
                    : "Quick Controls"
            )
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                // Force a fresh ChatView when switching sessions — otherwise
                // @State (history, session, scroll position) leaks from the
                // previous session and the view shows the wrong conversation.
                // Keyed on sessionId only (not the whole SessionState) so
                // per-event updates still reuse the view.
                .id(session.sessionId)
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
    }

    // MARK: - Event Handlers

    private func updateIdleVisibility() {
        if !viewModel.hasPhysicalNotch ||
           preferences.idleBehavior == .alwaysVisible {
            isVisible = true
        } else if !isAnyProcessing &&
                  !hasPendingPermission &&
                  !hasWaitingForInput &&
                  viewModel.status == .closed {
            isVisible = false
        }
    }

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed &&
               viewModel.hasPhysicalNotch &&
               preferences.idleBehavior == .smartHide {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // A deliberate click acknowledges completion. Merely hovering must
            // not consume the compact reminder and make the notch disappear.
            if viewModel.openReason == .click {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch,
                  preferences.idleBehavior == .smartHide else {
                isVisible = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        // Completion (`waitingForInput`) should stay compact. Only an actual
        // permission decision is urgent enough to open the full panel.
        let currentIds = Set(
            sessions
                .filter { $0.phase.isWaitingForApproval }
                .map { $0.stableId }
        )
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // A completed task gets a compact, visible reminder. If an older
            // notification auto-opened the panel, collapse it; never override
            // a panel the user deliberately opened by click or hover.
            isVisible = true
            activityCoordinator.hideActivity()
            if viewModel.status == .opened && viewModel.openReason == .notification {
                viewModel.notchClose()
            }

            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Completion reminders dwell briefly, then leave the session card
            // available without keeping the collapsed notch in alert mode.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + preferences.completionCompactDuration
            ) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
