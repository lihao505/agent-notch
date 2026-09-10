//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import Combine
import CoreGraphics
import os.log
import SwiftUI

private let attentionLogger = Logger(
    subsystem: "com.agentnotch",
    category: "Attention"
)

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

/// Task handles are deliberately kept outside SwiftUI's visible state. Making
/// these `@State` values would invalidate the entire notch hierarchy whenever
/// a timer is replaced, even though no rendered value changed.
@MainActor
private final class NotchDelayedUIWork: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var visibilityTask: Task<Void, Never>?
    var bounceTask: Task<Void, Never>?
    var completionSoundTask: Task<Void, Never>?
    var followUpDeliveryTask: Task<Void, Never>?
    var completionVisibilityTasks: [String: Task<Void, Never>] = [:]

    func cancelAll() {
        visibilityTask?.cancel()
        visibilityTask = nil
        bounceTask?.cancel()
        bounceTask = nil
        completionSoundTask?.cancel()
        completionSoundTask = nil
        followUpDeliveryTask?.cancel()
        followUpDeliveryTask = nil
        completionVisibilityTasks.values.forEach { $0.cancel() }
        completionVisibilityTasks.removeAll()
    }
}

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var usageMonitor = UsageLimitMonitor.shared
    @StateObject private var preferences = NotchPreferences.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousInteractionTokens:
        Set<NotchInteractionToken> = []
    @State private var previousCompletionTokens: Set<NotchCompletionToken> = []
    @State private var completionVisibilityStartedAt: [String: Date] = [:]
    @State private var attentionTrackingStartedAt = Date()
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @StateObject private var delayedUIWork = NotchDelayedUIWork()
    @StateObject private var followUpReminderCoordinator =
        NotchFollowUpReminderCoordinator()

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
            if let displayStartedAt =
                completionVisibilityStartedAt[session.sessionId] {
                return now.timeIntervalSince(displayStartedAt) <
                    preferences.completionCompactDuration
            }
            return false
        }
    }

    private var compactTaskCount: Int {
        sessionMonitor.instances.filter {
            $0.completedAt == nil &&
                ($0.phase.isActive || $0.phase.isWaitingForApproval)
        }.count
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

    private var compactCompanionPresentation:
        CompactCompanionPresentation {
        CompactNotchMetrics.companionPresentation(
            for: preferences.compactWidth
        )
    }

    private var layoutAnimationState: NotchLayoutAnimationState {
        NotchLayoutAnimationState(
            status: viewModel.status,
            size: notchSize,
            activityVisible: isAnyProcessing,
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
        if isAnyProcessing {
            return compactBaseWidth
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
    private var openAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    }

    private var closeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.96, anchor: .top)
                .combined(with: .opacity),
            removal: .opacity
        )
    }

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
                    // The persistent pet keeps a 40pt source canvas for the
                    // opened matched-geometry transition. That canvas is
                    // scaled visually in compact mode, but SwiftUI still
                    // measures its unscaled height. Pin the closed shell to
                    // the real hardware notch so the source canvas cannot
                    // make the black pill extend below the camera housing.
                    .frame(
                        height: viewModel.status == .opened
                            ? nil
                            : closedNotchSize.height,
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
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.3, dampingFraction: 0.5),
                        value: isBouncing
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(
                            reduceMotion
                                ? .easeOut(duration: 0.1)
                                : .spring(response: 0.38, dampingFraction: 0.8)
                        ) {
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
            reconcileFollowUpReminders(sessionMonitor.instances)
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
            reconcileFollowUpReminders(instances)
        }
        .onChange(of: preferences.idleBehavior) { _, _ in
            updateIdleVisibility()
        }
        .onChange(of: preferences.completionCompactDuration) { _, _ in
            rescheduleCompletionVisibilityExpiries()
        }
        .onChange(of: preferences.followUpRemindersEnabled) { _, _ in
            reconcileFollowUpReminders(sessionMonitor.instances)
        }
        .onChange(of: preferences.followUpReminderDelay) { _, _ in
            reconcileFollowUpReminders(sessionMonitor.instances)
        }
        .onChange(of: followUpReminderCoordinator.pendingTargets) {
            _, targets in
            deliverFollowUpReminders(targets)
        }
        .onDisappear {
            cancelDelayedUIWork()
            followUpReminderCoordinator.cancelAll()
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        isAnyProcessing
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
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                    .frame(
                        height: viewModel.status == .opened
                            ? CompactNotchMetrics.openedHeaderHeight
                            : max(24, closedNotchSize.height)
                    )

                if viewModel.status == .opened {
                    contentView
                        .frame(width: notchSize.width - 24)
                        .transition(contentTransition)
                }
            }

            persistentPet
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
                Color.clear
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

    /// The pet is a single persistent view rather than two matched snapshots.
    /// The shell width, offset, and scale animate together, so the sprite keeps
    /// its current frame while travelling from the compact wing to the row
    /// beneath quota information.
    @ViewBuilder
    private var persistentPet: some View {
        if viewModel.status == .opened || showClosedActivity {
            let isOpened = viewModel.status == .opened
            let compactScale =
                CompactNotchMetrics.compactAnimationSize *
                compactAnimationScale /
                CompactNotchMetrics.openedAnimationSize
            let scale = isOpened ? 1 : compactScale
            let companionPresentation = isOpened
                ? CompactCompanionPresentation.full
                : compactCompanionPresentation
            let companionSize = petCompanionSize(
                for: companionPresentation
            )
            let companionSpacing = petCompanionSpacing(
                for: companionPresentation
            )
            let fullWidth =
                CompactNotchMetrics.openedAnimationCanvasSize +
                companionSpacing +
                companionSize
            let compactX = max(
                0,
                (leftWingWidth - fullWidth * compactScale) / 2
            )
            let compactY = max(
                0,
                (closedNotchSize.height -
                    CompactNotchMetrics.openedAnimationCanvasSize *
                    compactScale) / 2
            )

            HStack(spacing: companionSpacing) {
                VibePetIcon(
                    size: CompactNotchMetrics.openedAnimationSize,
                    motion: petMotion
                )
                .frame(
                    width: CompactNotchMetrics.openedAnimationCanvasSize,
                    height: CompactNotchMetrics.openedAnimationCanvasSize
                )

                switch companionPresentation {
                case .hidden:
                    EmptyView()
                case .micro:
                    CompactPetCompanionIcon(
                        motion: petMotion,
                        size: companionSize
                    )
                case .full:
                    PetStateSignalIcon(
                        motion: petMotion,
                        size: companionSize
                    )
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(
                x: isOpened ? 8 : compactX,
                y: isOpened ? 27 : compactY
            )
            .allowsHitTesting(false)
            .zIndex(3)
        }
    }

    private func petCompanionSize(
        for presentation: CompactCompanionPresentation
    ) -> CGFloat {
        switch presentation {
        case .hidden: return 0
        case .micro: return 14
        case .full: return CompactNotchMetrics.openedSignalSize
        }
    }

    private func petCompanionSpacing(
        for presentation: CompactCompanionPresentation
    ) -> CGFloat {
        switch presentation {
        case .hidden: return 0
        case .micro: return 3
        case .full: return 6
        }
    }

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
                        // Compensate for the shell's shape-safe outer inset so
                        // quota information aligns with the pet at the true
                        // left edge of the opened content.
                        .offset(x: -24)
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
            .frame(maxWidth: .infinity, alignment: .leading)

            // The animated state lives below quota information. Both sides
            // remain outside the physical notch and can use the larger opened
            // size without being clipped.
            HStack(spacing: 10) {
                Color.clear
                    .frame(
                        width:
                            CompactNotchMetrics.openedAnimationCanvasSize +
                            6 +
                            CompactNotchMetrics.openedSignalSize,
                        height:
                            CompactNotchMetrics.openedAnimationCanvasSize
                    )

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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            delayedUIWork.visibilityTask?.cancel()
            delayedUIWork.visibilityTask = nil
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
            delayedUIWork.visibilityTask?.cancel()
            delayedUIWork.visibilityTask = nil
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            delayedUIWork.visibilityTask?.cancel()
            delayedUIWork.visibilityTask = nil
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
                scheduleIdleVisibilityUpdate(after: 0.5)
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            delayedUIWork.visibilityTask?.cancel()
            delayedUIWork.visibilityTask = nil
            isVisible = true
            // A deliberate click acknowledges completion. Merely hovering must
            // not consume the compact reminder and make the notch disappear.
            if viewModel.openReason == .click {
                acknowledgeCurrentCompletions()
                completionVisibilityStartedAt.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch,
                  preferences.idleBehavior == .smartHide else {
                isVisible = true
                return
            }
            scheduleIdleVisibilityUpdate(after: 0.35)
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        // Completion (`waitingForInput`) stays compact. New interactions open
        // their exact conversation unless compact-question mode deliberately
        // defers AskUserQuestion until the user opens the notch.
        let currentTokens = Set(
            sessions.compactMap { session in
                NotchAttentionPolicy.interactionToken(for: session)
            }
        )
        if let pendingSession = NotchAttentionPolicy.newestSessionToAutoExpand(
            from: sessions,
            excluding: previousInteractionTokens,
            expandQuestionsAutomatically:
                preferences.expandQuestionsAutomatically
        ) {
            // An approval is actionable only with its context visible. Open
            // the exact conversation even when a second request arrives for
            // a session that was already waiting.
            viewModel.showApproval(for: pendingSession)
        }

        previousInteractionTokens = currentTokens
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let waitingForInputSessions = instances.filter {
            $0.phase == .waitingForInput
        }
        let tokenBySession = Dictionary(
            uniqueKeysWithValues: waitingForInputSessions.compactMap {
                session -> (String, NotchCompletionToken)? in
                guard let token = NotchAttentionPolicy.completionToken(
                    for: session
                ) else {
                    return nil
                }
                return (session.sessionId, token)
            }
        )
        let currentTokens = Set(tokenBySession.values)
        let newTokens = currentTokens.subtracting(previousCompletionTokens)
        let now = Date()
        let presentableTokens = newTokens.filter {
            NotchAttentionPolicy.shouldPresent(
                $0,
                presentationStartedAt: attentionTrackingStartedAt,
                duration: preferences.completionCompactDuration,
                now: now
            )
        }
        let presentableIds = Set(presentableTokens.map(\.sessionId))
        let currentIds = Set(tokenBySession.keys)

        // The visibility lifetime starts at the real completion boundary, not
        // when a delayed parser/UI update happened to arrive.
        for token in presentableTokens {
            completionVisibilityStartedAt[token.sessionId] = token.completedAt
            scheduleCompletionVisibilityExpiry(
                sessionId: token.sessionId,
                displayStartedAt: token.completedAt
            )
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(completionVisibilityStartedAt.keys)
            .subtracting(currentIds)
        for staleId in staleIds {
            delayedUIWork.completionVisibilityTasks[staleId]?.cancel()
            delayedUIWork.completionVisibilityTasks.removeValue(
                forKey: staleId
            )
            completionVisibilityStartedAt.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !presentableTokens.isEmpty {
            // A completed task gets a compact, visible reminder. If an older
            // notification auto-opened the panel, collapse it; never override
            // a panel the user deliberately opened by click or hover.
            isVisible = true
            activityCoordinator.hideActivity()
            if viewModel.status == .opened && viewModel.openReason == .notification {
                viewModel.notchClose()
            }

            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter {
                presentableIds.contains($0.sessionId)
            }
            let completionTargets = newlyWaitingSessions.compactMap {
                session -> (SessionState, NotchCompletionToken)? in
                guard let token = tokenBySession[session.sessionId] else {
                    return nil
                }
                return (session, token)
            }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Focus detection may yield while another turn begins. Keep
                // one cancellable task and revalidate the exact completion
                // generation before emitting a now-stale sound.
                delayedUIWork.completionSoundTask?.cancel()
                delayedUIWork.completionSoundTask = Task { @MainActor in
                    let shouldPlaySound = await shouldPlayNotificationSound(
                        for: completionTargets
                    )
                    guard !Task.isCancelled else { return }
                    if shouldPlaySound {
                        playAttentionSoundIfAllowed(named: soundName)
                    }
                    delayedUIWork.completionSoundTask = nil
                }
            }

            // Trigger bounce animation to get user's attention
            triggerAttentionBounce()
        } else if currentTokens.isEmpty {
            // A new turn supersedes any completion flourish immediately.
            delayedUIWork.completionSoundTask?.cancel()
            delayedUIWork.completionSoundTask = nil
            delayedUIWork.bounceTask?.cancel()
            delayedUIWork.bounceTask = nil
            isBouncing = false
        }

        previousCompletionTokens = currentTokens
    }

    private func scheduleCompletionVisibilityExpiry(
        sessionId: String,
        displayStartedAt: Date
    ) {
        delayedUIWork.completionVisibilityTasks[sessionId]?.cancel()
        let remaining = max(
            0,
            displayStartedAt.addingTimeInterval(
                preferences.completionCompactDuration
            ).timeIntervalSinceNow
        )
        delayedUIWork.completionVisibilityTasks[sessionId] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            guard completionVisibilityStartedAt[sessionId] ==
                    displayStartedAt else {
                return
            }
            // Mutating the timestamp map invalidates the SwiftUI body. Merely
            // comparing Date() in `hasWaitingForInput` does not schedule a
            // refresh when the reminder duration elapses.
            completionVisibilityStartedAt.removeValue(forKey: sessionId)
            delayedUIWork.completionVisibilityTasks.removeValue(
                forKey: sessionId
            )
            handleProcessingChange()
            updateIdleVisibility()
        }
    }

    private func rescheduleCompletionVisibilityExpiries() {
        for (sessionId, displayStartedAt) in
            completionVisibilityStartedAt {
            scheduleCompletionVisibilityExpiry(
                sessionId: sessionId,
                displayStartedAt: displayStartedAt
            )
        }
    }

    private func reconcileFollowUpReminders(_ sessions: [SessionState]) {
        followUpReminderCoordinator.reconcile(
            sessions: sessions,
            enabled: preferences.followUpRemindersEnabled,
            delay: preferences.followUpReminderDelay,
            trackingStartedAt: attentionTrackingStartedAt
        )

        // Work that completes while a click-owned panel is already open is
        // already visible to the user and must not produce a delayed ping.
        if viewModel.status == .opened && viewModel.openReason == .click {
            acknowledgeCurrentCompletions()
        }
    }

    private func acknowledgeCurrentCompletions() {
        followUpReminderCoordinator.acknowledgeCompletions(
            sessionMonitor.instances.compactMap {
                NotchAttentionPolicy.completionToken(for: $0)
            }
        )
    }

    private func deliverFollowUpReminders(
        _ targets: Set<NotchFollowUpTarget>
    ) {
        delayedUIWork.followUpDeliveryTask?.cancel()
        delayedUIWork.followUpDeliveryTask = nil
        guard !targets.isEmpty else { return }

        delayedUIWork.followUpDeliveryTask = Task { @MainActor in
            // A visible panel is already doing the reminder's job. Consuming
            // these generations also prevents an old ping after it closes.
            guard viewModel.status != .opened else {
                attentionLogger.info(
                    "Suppressed follow-up because the notch is already open"
                )
                delayedUIWork.followUpDeliveryTask = nil
                followUpReminderCoordinator.consume(targets)
                return
            }

            var eligibleTargets: Set<NotchFollowUpTarget> = []
            for target in targets.sorted(by: {
                $0.sessionId < $1.sessionId
            }) {
                guard followUpReminderCoordinator.isCurrent(target),
                      let session = sessionMonitor.instances.first(where: {
                          $0.sessionId == target.sessionId
                      }) else {
                    continue
                }

                let isFocused: Bool
                if let pid = session.pid {
                    isFocused = await TerminalVisibilityDetector
                        .isSessionFocused(sessionPid: pid)
                } else {
                    isFocused = false
                }

                guard !Task.isCancelled,
                      viewModel.status != .opened,
                      !isFocused,
                      followUpReminderCoordinator.isCurrent(target) else {
                    if isFocused {
                        attentionLogger.info(
                            "Suppressed focused follow-up for \(target.sessionId.prefix(8), privacy: .public)"
                        )
                    }
                    continue
                }
                eligibleTargets.insert(target)
            }

            guard !Task.isCancelled else { return }
            let reminderAt = Date()
            for target in eligibleTargets {
                guard case .completion = target else { continue }
                completionVisibilityStartedAt[target.sessionId] = reminderAt
                scheduleCompletionVisibilityExpiry(
                    sessionId: target.sessionId,
                    displayStartedAt: reminderAt
                )
            }

            if !eligibleTargets.isEmpty {
                attentionLogger.info(
                    "Delivered one follow-up for \(eligibleTargets.count) current target(s)"
                )
                isVisible = true
                handleProcessingChange()
                triggerAttentionBounce()
                if let soundName = AppSettings.notificationSound.soundName {
                    playAttentionSoundIfAllowed(named: soundName)
                }
            }

            delayedUIWork.followUpDeliveryTask = nil
            followUpReminderCoordinator.consume(targets)
        }
    }

    private func triggerAttentionBounce() {
        delayedUIWork.bounceTask?.cancel()
        delayedUIWork.bounceTask = nil
        guard !reduceMotion else {
            isBouncing = false
            return
        }

        isBouncing = true
        delayedUIWork.bounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isBouncing = false
            delayedUIWork.bounceTask = nil
        }
    }

    private func playAttentionSoundIfAllowed(named soundName: String) {
        let isQuiet = NotchQuietHoursPolicy.isQuiet(
            enabled: preferences.quietHoursEnabled,
            startMinute: preferences.quietHoursStartMinute,
            endMinute: preferences.quietHoursEndMinute
        )
        guard !isQuiet else {
            attentionLogger.info(
                "Suppressed automatic attention sound during quiet hours"
            )
            return
        }
        NSSound(named: soundName)?.play()
    }

    private func scheduleIdleVisibilityUpdate(after delay: TimeInterval) {
        delayedUIWork.visibilityTask?.cancel()
        delayedUIWork.visibilityTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            delayedUIWork.visibilityTask = nil
            if viewModel.status == .closed &&
               !isAnyProcessing &&
               !hasPendingPermission &&
               !hasWaitingForInput {
                isVisible = false
            }
        }
    }

    private func cancelDelayedUIWork() {
        delayedUIWork.cancelAll()
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(
        for targets: [(SessionState, NotchCompletionToken)]
    ) async -> Bool {
        for (session, token) in targets {
            guard let pid = session.pid else {
                // No PID means we can't check focus. It is still safe to alert
                // only if this exact completion remains current.
                if NotchAttentionPolicy.isStillCurrent(
                    token,
                    in: sessionMonitor.instances
                ) {
                    return true
                }
                continue
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            guard !Task.isCancelled,
                  NotchAttentionPolicy.isStillCurrent(
                    token,
                    in: sessionMonitor.instances
                  ) else {
                continue
            }
            if !isFocused {
                return true
            }
        }

        return false
    }
}
