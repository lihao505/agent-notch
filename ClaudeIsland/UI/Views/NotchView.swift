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

/// One animation value drives the notch shell. Keeping geometry changes in a
/// single transaction avoids several implicit springs fighting over the same
/// frame when status, content size, and activity state change together.
private struct NotchLayoutAnimationState: Equatable {
    let status: NotchStatus
    let size: CGSize
    let activityVisible: Bool
    let permissionVisible: Bool
    let completionVisible: Bool
    let compactStyle: CompactNotchStyle
    let compactWidth: Double
}

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
        CompactNotchMetrics.wingWidth(
            for: preferences.compactStyle,
            configuredWidth: preferences.compactWidth
        )
    }

    private var rightWingWidth: CGFloat {
        CompactNotchMetrics.wingWidth(
            for: preferences.compactStyle,
            configuredWidth: preferences.compactWidth
        )
    }

    private var compactAnimationScale: CGFloat {
        CompactNotchMetrics.animationScale(
            for: preferences.compactWidth
        )
    }

    private var layoutAnimationState: NotchLayoutAnimationState {
        NotchLayoutAnimationState(
            status: viewModel.status,
            size: notchSize,
            activityVisible: activityCoordinator.expandingActivity.show,
            permissionVisible: hasPendingPermission,
            completionVisible: hasWaitingForInput,
            compactStyle: preferences.compactStyle,
            compactWidth: preferences.compactWidth
        )
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
        let compactBaseWidth =
            leftWingWidth +
            rightWingWidth

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                return compactBaseWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return compactBaseWidth
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
                    .animation(
                        viewModel.status == .opened
                            ? openAnimation
                            : closeAnimation,
                        value: layoutAnimationState
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
                .frame(
                    height: viewModel.status == .opened
                        ? CompactNotchMetrics.openedHeaderHeight
                        : max(24, closedNotchSize.height)
                )

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        if viewModel.status == .opened {
            openedHeaderRow
        } else {
            compactHeaderRow
        }
    }

    private var compactHeaderRow: some View {
        HStack(spacing: 0) {
            // Left side - compact pet and its state signal.
            if showClosedActivity {
                HStack(spacing: -2) {
                    VibePetIcon(
                        size:
                            CompactNotchMetrics.compactAnimationSize
                            * compactAnimationScale,
                        motion: petMotion
                    )
                        .frame(
                            width:
                                CompactNotchMetrics.compactPetCanvasSize
                                * compactAnimationScale,
                            height:
                                CompactNotchMetrics.compactPetCanvasSize
                                * compactAnimationScale
                        )
                        .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showClosedActivity)

                    PetStateSignalIcon(
                        motion: petMotion,
                        size:
                            CompactNotchMetrics.compactSignalSize
                            * compactAnimationScale
                    )
                }
                .frame(width: leftWingWidth)
            }

            // Center content
            if !showClosedActivity {
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
                            (isBouncing ? 16 : 0)
                    )
            }

            // Right side - state animation, with an optional compact task count.
            if showClosedActivity {
                HStack(spacing: 5) {
                    if preferences.compactStyle == .detailed {
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

                    if hasPendingPermission {
                        WaitingPixelIndicatorIcon(
                            size:
                                CompactNotchMetrics
                                    .compactStatusAnimationSize
                                * compactAnimationScale
                        )
                            .frame(
                                width:
                                    CompactNotchMetrics
                                        .compactStatusCanvasSize
                                    * compactAnimationScale,
                                height:
                                    CompactNotchMetrics
                                        .compactStatusCanvasSize
                                    * compactAnimationScale
                            )
                            .matchedGeometryEffect(
                                id: "spinner",
                                in: activityNamespace,
                                isSource: showClosedActivity
                            )
                    } else if isProcessing {
                        PixelLoaderIcon(
                            size:
                                CompactNotchMetrics
                                    .compactStatusAnimationSize
                                * compactAnimationScale
                        )
                            .frame(
                                width:
                                    CompactNotchMetrics
                                        .compactStatusCanvasSize
                                    * compactAnimationScale,
                                height:
                                    CompactNotchMetrics
                                        .compactStatusCanvasSize
                                    * compactAnimationScale
                            )
                            .matchedGeometryEffect(
                                id: "spinner",
                                in: activityNamespace,
                                isSource: showClosedActivity
                            )
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(
                            size: 9 * compactAnimationScale,
                            color: TerminalColors.green
                        )
                        .frame(
                            width:
                                CompactNotchMetrics
                                    .compactStatusCanvasSize
                                * compactAnimationScale,
                            height:
                                CompactNotchMetrics
                                    .compactStatusCanvasSize
                                * compactAnimationScale
                        )
                        .matchedGeometryEffect(
                            id: "spinner",
                            in: activityNamespace,
                            isSource: showClosedActivity
                        )
                    } else {
                        IdlePixelIndicatorIcon(
                            size:
                                CompactNotchMetrics
                                    .compactStatusAnimationSize
                                * compactAnimationScale
                        )
                            .frame(
                                width:
                                    CompactNotchMetrics
                                        .compactStatusCanvasSize
                                    * compactAnimationScale,
                                height:
                                    CompactNotchMetrics
                                    .compactStatusCanvasSize
                                * compactAnimationScale
                        )
                        .matchedGeometryEffect(
                            id: "spinner",
                            in: activityNamespace,
                            isSource: showClosedActivity
                        )
                    }
                }
                .frame(
                    width: rightWingWidth
                )
            }
        }
        .frame(height: closedNotchSize.height)
    }

    // MARK: - Opened Header

    private var openedHeaderRow: some View {
        VStack(spacing: 2) {
            // Keep quota information inside the narrow rail beside the
            // physical camera notch. A compact bar cannot drift underneath
            // the opaque hardware area even on narrower displays.
            HStack(spacing: 8) {
                if preferences.showUsageLimits,
                   let usage = usageMonitor.snapshot {
                    UsageLimitBar(snapshot: usage)
                        .frame(maxWidth: 148)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: max(148, viewModel.deviceNotchRect.width))

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

            // The animated state lives below quota information. Both sides
            // remain outside the physical notch and can use the larger opened
            // size without being clipped.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    VibePetIcon(
                        size: CompactNotchMetrics.openedAnimationSize,
                        motion: petMotion
                    )
                    .frame(
                        width: CompactNotchMetrics.openedAnimationCanvasSize,
                        height: CompactNotchMetrics.openedAnimationCanvasSize
                    )
                    .matchedGeometryEffect(
                        id: "pet",
                        in: activityNamespace,
                        isSource: false
                    )

                    PetStateSignalIcon(
                        motion: petMotion,
                        size: CompactNotchMetrics.openedSignalSize
                    )
                }

                Spacer()

                Group {
                    if hasPendingPermission {
                        WaitingPixelIndicatorIcon(
                            size: CompactNotchMetrics.openedAnimationSize
                        )
                    } else if isProcessing {
                        PixelLoaderIcon(
                            size: CompactNotchMetrics.openedAnimationSize
                        )
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(
                            size: 20,
                            color: TerminalColors.green
                        )
                    } else {
                        IdlePixelIndicatorIcon(size: 20)
                    }
                }
                .frame(
                    width: CompactNotchMetrics.openedAnimationCanvasSize,
                    height: CompactNotchMetrics.openedAnimationCanvasSize
                )
                .matchedGeometryEffect(
                    id: "spinner",
                    in: activityNamespace,
                    isSource: false
                )
            }
        }
        .padding(.horizontal, 8)
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
        let currentIds = Set(sessions.compactMap(\.pendingToolId))
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        let newlyPendingSessions = sessions.filter { session in
                guard let toolUseId = session.pendingToolId else {
                    return false
                }
                return newPendingIds.contains(toolUseId)
            }
        if let pendingSession = newlyPendingSessions.max(
            by: { $0.lastActivity < $1.lastActivity }
        ) {
            // An approval is actionable only with its context visible. Open
            // the exact conversation even when a second request arrives for
            // a session that was already waiting.
            viewModel.showApproval(for: pendingSession)
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
