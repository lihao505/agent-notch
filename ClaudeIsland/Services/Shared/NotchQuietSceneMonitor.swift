//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchQuietSceneMonitor.swift
//  ClaudeIsland
//
//  Testable macOS availability state for automatic attention sounds.
//

import AppKit
import Combine
import Foundation
import os.log

private let quietSceneLogger = Logger(
    subsystem: "com.agentnotch",
    category: "QuietScenes"
)

struct NotchQuietSceneState: Equatable, Sendable {
    var isScreenLocked: Bool
    var isDisplayAsleep: Bool
    var isSystemAsleep: Bool
    var isSessionActive: Bool

    static let available = NotchQuietSceneState(
        isScreenLocked: false,
        isDisplayAsleep: false,
        isSystemAsleep: false,
        isSessionActive: true
    )

    var shouldSuppressAttention: Bool {
        isScreenLocked ||
            isDisplayAsleep ||
            isSystemAsleep ||
            !isSessionActive
    }
}

enum NotchQuietSceneEvent: String, Sendable {
    case screenLocked = "screen_locked"
    case screenUnlocked = "screen_unlocked"
    case displaySlept = "display_slept"
    case displayWoke = "display_woke"
    case systemWillSleep = "system_will_sleep"
    case systemDidWake = "system_did_wake"
    case sessionResigned = "session_resigned"
    case sessionBecameActive = "session_became_active"
}

/// Keeps independent availability flags so wake/unlock notifications arriving
/// in a different order cannot unmute the app prematurely.
@MainActor
final class NotchQuietSceneMonitor: ObservableObject {
    static let shared = NotchQuietSceneMonitor()

    static let screenLockedNotification = Notification.Name(
        "com.apple.screenIsLocked"
    )
    static let screenUnlockedNotification = Notification.Name(
        "com.apple.screenIsUnlocked"
    )

    @Published private(set) var state: NotchQuietSceneState

    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(
        workspaceNotificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter =
            DistributedNotificationCenter.default(),
        initialScreenLocked: Bool? = nil
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        state = NotchQuietSceneState(
            isScreenLocked: initialScreenLocked ?? Self.currentScreenLocked(),
            isDisplayAsleep: false,
            isSystemAsleep: false,
            isSessionActive: true
        )

        observeWorkspace(
            NSWorkspace.screensDidSleepNotification,
            event: .displaySlept
        )
        observeWorkspace(
            NSWorkspace.screensDidWakeNotification,
            event: .displayWoke
        )
        observeWorkspace(
            NSWorkspace.willSleepNotification,
            event: .systemWillSleep
        )
        observeWorkspace(
            NSWorkspace.didWakeNotification,
            event: .systemDidWake
        )
        observeWorkspace(
            NSWorkspace.sessionDidResignActiveNotification,
            event: .sessionResigned
        )
        observeWorkspace(
            NSWorkspace.sessionDidBecomeActiveNotification,
            event: .sessionBecameActive
        )
        observeDistributed(
            Self.screenLockedNotification,
            event: .screenLocked
        )
        observeDistributed(
            Self.screenUnlockedNotification,
            event: .screenUnlocked
        )
    }

    deinit {
        workspaceObservers.forEach {
            workspaceNotificationCenter.removeObserver($0)
        }
        distributedObservers.forEach {
            distributedNotificationCenter.removeObserver($0)
        }
    }

    private func observeWorkspace(
        _ name: Notification.Name,
        event: NotchQuietSceneEvent
    ) {
        let observer = workspaceNotificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(event)
            }
        }
        workspaceObservers.append(observer)
    }

    private func observeDistributed(
        _ name: Notification.Name,
        event: NotchQuietSceneEvent
    ) {
        let observer = distributedNotificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(event)
            }
        }
        distributedObservers.append(observer)
    }

    private func apply(_ event: NotchQuietSceneEvent) {
        var next = state
        switch event {
        case .screenLocked:
            next.isScreenLocked = true
        case .screenUnlocked:
            next.isScreenLocked = false
        case .displaySlept:
            next.isDisplayAsleep = true
        case .displayWoke:
            next.isDisplayAsleep = false
        case .systemWillSleep:
            next.isSystemAsleep = true
        case .systemDidWake:
            next.isSystemAsleep = false
        case .sessionResigned:
            next.isSessionActive = false
        case .sessionBecameActive:
            next.isSessionActive = true
        }

        guard next != state else { return }
        state = next
        quietSceneLogger.info("Quiet scene changed: \(event.rawValue, privacy: .public), suppressing=\(next.shouldSuppressAttention)")
    }

    /// macOS has no public synchronous lock-state query. This de-facto session
    /// key complements live distributed notifications so a launch that occurs
    /// while locked starts from the safe state.
    nonisolated static func currentScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary()
                as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
