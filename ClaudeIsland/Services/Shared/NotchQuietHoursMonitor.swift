// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import Combine
import Foundation

struct NotchQuietHoursSchedule: Equatable {
    let enabled: Bool
    let startMinute: Int
    let endMinute: Int
}

/// One cancellable boundary timer, never a repeating poll. Wall-clock changes
/// and wake notifications recompute both the current state and next deadline.
@MainActor
final class NotchQuietHoursMonitor: ObservableObject {
    @Published private(set) var isQuiet = false
    private(set) var nextCheckAt: Date?
    private var schedule: NotchQuietHoursSchedule?
    private var boundaryTask: Task<Void, Never>?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private let systemNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var systemObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        systemNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { .current },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.systemNotifications = systemNotifications
        self.workspaceNotifications = workspaceNotifications
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            systemObservers.append(observe(name, on: systemNotifications))
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(observe(name, on: workspaceNotifications))
        }
    }

    deinit {
        boundaryTask?.cancel()
        systemObservers.forEach { systemNotifications.removeObserver($0) }
        workspaceObservers.forEach { workspaceNotifications.removeObserver($0) }
    }

    func configure(_ schedule: NotchQuietHoursSchedule) {
        self.schedule = schedule
        refresh()
    }

    func stop() {
        boundaryTask?.cancel()
        boundaryTask = nil
        nextCheckAt = nil
        schedule = nil
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        boundaryTask?.cancel()
        boundaryTask = nil
        nextCheckAt = nil
        guard let schedule else { return }
        let date = now()
        let localCalendar = calendar()
        let quiet = NotchQuietHoursPolicy.isQuiet(
            enabled: schedule.enabled, startMinute: schedule.startMinute,
            endMinute: schedule.endMinute, at: date, calendar: localCalendar
        )
        if isQuiet != quiet { isQuiet = quiet }
        guard let next = NotchQuietHoursPolicy.nextRecheckDate(
            enabled: schedule.enabled, startMinute: schedule.startMinute,
            endMinute: schedule.endMinute, after: date, calendar: localCalendar
        ) else { return }
        nextCheckAt = next
        let wait = sleep
        boundaryTask = Task { @MainActor [weak self] in
            do { try await wait(next.timeIntervalSince(date)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
