//
//  LifecycleDiagnosticsCoordinator.swift
//  Agent Notch
//
//  Read-only bridge from the lifecycle sources to the settings UI.
//

import Combine
import Foundation

@MainActor
final class LifecycleDiagnosticsCoordinator: ObservableObject {
    typealias SessionReader = @Sendable () async -> SessionStoreDiagnosticsInput

    @Published private(set) var snapshot: LifecycleDiagnosticsSnapshot?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshDelayed = false

    private let readSessions: SessionReader
    private let readBridge: @MainActor () -> DiagnosticsBridgeInput
    private let readWatchers: @MainActor () -> [DiagnosticsWatcherInput]
    private let now: @MainActor () -> Date
    private let appVersion: @MainActor () -> String
    private let macOSMajorVersion: @MainActor () -> Int
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private var activeRefreshID: UUID?

    var isPolling: Bool { pollingTask != nil }

    init(
        readSessions: @escaping SessionReader = {
            SessionStore.shared.diagnosticsInput()
        },
        readBridge: @escaping @MainActor () -> DiagnosticsBridgeInput = {
            HookSocketServer.shared.diagnosticsInput()
        },
        readWatchers: @escaping @MainActor () -> [DiagnosticsWatcherInput] = {
            InterruptWatcherManager.shared.diagnosticsInputs()
        },
        now: @escaping @MainActor () -> Date = { Date() },
        appVersion: @escaping @MainActor () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        },
        macOSMajorVersion: @escaping @MainActor () -> Int = {
            Foundation.ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        }
    ) {
        self.readSessions = readSessions
        self.readBridge = readBridge
        self.readWatchers = readWatchers
        self.now = now
        self.appVersion = appVersion
        self.macOSMajorVersion = macOSMajorVersion
    }

    /// The view owns this loop; disappearing or closing the settings window
    /// cancels it. Calling start twice never creates a second poller.
    func start() {
        guard pollingTask == nil else { return }
        generation += 1
        let currentGeneration = generation
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh(expectedGeneration: currentGeneration)
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        generation += 1
        pollingTask?.cancel()
        pollingTask = nil
        activeRefreshID = nil
        isRefreshing = false
        refreshDelayed = false
    }

    /// Manual refresh uses the same read-only path as periodic polling.
    func refresh() async {
        await refresh(expectedGeneration: generation)
    }

    private func refresh(expectedGeneration: Int) async {
        guard activeRefreshID == nil, expectedGeneration == generation else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        isRefreshing = true
        refreshDelayed = false

        let delayNotice = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.activeRefreshID == refreshID,
                  self.generation == expectedGeneration else { return }
            self.refreshDelayed = true
        }
        defer {
            delayNotice.cancel()
            if activeRefreshID == refreshID {
                activeRefreshID = nil
                isRefreshing = false
                refreshDelayed = false
            }
        }

        let store = await readSessions()
        guard expectedGeneration == generation, !Task.isCancelled else { return }
        let capturedAt = now()
        let next = LifecycleDiagnosticsAssembler.build(
            at: capturedAt,
            appVersion: appVersion(),
            macOSMajorVersion: macOSMajorVersion(),
            sessions: store.sessions,
            decisions: store.decisions,
            bridge: readBridge(),
            watchers: readWatchers()
        )
        guard expectedGeneration == generation, !Task.isCancelled else { return }
        snapshot = next
        lastRefreshedAt = capturedAt
    }
}
