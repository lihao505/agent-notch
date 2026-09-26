//
//  LifecycleDiagnosticsRenderingTests.swift
//  Agent Notch
//
//  Offline native settings fixtures; not installed-app interaction proof.
//

import AppKit
import SwiftUI
import XCTest
@testable import Agent_Notch

@MainActor
final class LifecycleDiagnosticsRenderingTests: XCTestCase {
    func testChineseEmptyAtMinimumSettingsWidth() async throws {
        try await render(language: .simplifiedChinese, width: 520, active: false)
    }

    func testChineseAttentionAtMinimumSettingsWidth() async throws {
        try await render(language: .simplifiedChinese, width: 520, active: true)
    }

    func testEnglishAttentionAtNormalSettingsWidth() async throws {
        try await render(language: .english, width: 660, active: true)
    }

    private func render(language: AppLanguage, width: CGFloat, active: Bool) async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let observation = SessionLifecycleObservation(
            sessionId: "raw-secret-fixture",
            cwd: "/Users/private/fixture",
            source: .codex,
            origin: .hook,
            evidence: .hook(.active),
            observedAt: now.addingTimeInterval(-1),
            receivedAt: now
        )
        let decision = DiagnosticsDecisionInput(
            sessionId: observation.sessionId,
            trace: LifecycleTraceEntry(
                observation: observation,
                previous: nil,
                transition: LifecycleTransition(
                    mutation: .none,
                    reason: .hookOlderThanBoundary
                )
            )
        )
        let store = SessionStoreDiagnosticsInput(
            sessions: active ? [DiagnosticsSessionInput(
                sessionId: observation.sessionId,
                source: .codex,
                phase: .processing,
                hasProcess: true,
                waitingForPermission: false,
                lastActivity: now.addingTimeInterval(-2)
            )] : [],
            decisions: active ? [decision] : []
        )
        let bridge = DiagnosticsBridgeInput(
            isRunning: active,
            socketExists: active,
            ownsSocket: active,
            pendingPermissionSessionIds: [],
            lastEventAt: active ? now.addingTimeInterval(-1) : nil
        )
        let watchers: [DiagnosticsWatcherInput] = active ? [DiagnosticsWatcherInput(
            sessionId: observation.sessionId,
            state: .recovering,
            retryCount: 2,
            lastOpenedAt: now.addingTimeInterval(-3),
            lastEventAt: now.addingTimeInterval(-2),
            lastRetryAt: now.addingTimeInterval(-1)
        )] : []
        let coordinator = LifecycleDiagnosticsCoordinator(
            readSessions: { store },
            readBridge: { bridge },
            readWatchers: { watchers },
            now: { now },
            appVersion: { "test" },
            macOSMajorVersion: { 26 }
        )
        await coordinator.refresh()
        defer { coordinator.stop() }

        let height: CGFloat = active ? 900 : 620
        let content = LifecycleDiagnosticsView(language: language, coordinator: coordinator)
            .frame(width: width, height: height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: bounds, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "diagnostics-\(language.rawValue)-\(active ? "attention" : "empty")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
