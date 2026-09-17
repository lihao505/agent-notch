// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI
import XCTest
@testable import Agent_Notch

/// Native control snapshots with no shared preferences or system integrations.
/// Attachments support visual review; they do not prove installed-app hit testing.
@MainActor
final class NotchQuickControlsRenderingTests: XCTestCase {
    private final class InteractionProbe {
        private(set) var setterCalls: [String: Int] = [:]
        private(set) var actionCalls: [String: Int] = [:]

        func binding<Value>(_ value: Value, name: String) -> Binding<Value> {
            Binding(
                get: { value },
                set: { _ in self.setterCalls[name, default: 0] += 1 }
            )
        }

        func action(_ name: String) -> () -> Void {
            { self.actionCalls[name, default: 0] += 1 }
        }
    }

    func testChineseAtMinimumPanelContentHeight() async throws {
        try await render(language: .simplifiedChinese, height: 272)
    }

    func testEnglishAtMinimumPanelContentHeight() async throws {
        try await render(language: .english, height: 272)
    }

    func testChineseAtNormalPanelContentHeight() async throws {
        try await render(language: .simplifiedChinese, height: 302)
    }

    func testEnglishAtNormalPanelContentHeight() async throws {
        try await render(language: .english, height: 302)
    }

    func testChineseFullContentWithAutomaticApprovalAndUpdatingBridge() async throws {
        try await render(
            language: .simplifiedChinese, height: 720,
            approvalMode: .auto, isUpdatingHooks: true,
            variant: "full-updating"
        )
    }

    func testEnglishFullContentWithAutomaticApprovalAndUpdatingBridge() async throws {
        try await render(
            language: .english, height: 720,
            approvalMode: .auto, isUpdatingHooks: true,
            variant: "full-updating"
        )
    }

    func testChineseFullContentWithTrustedApprovalRepairAndError() async throws {
        try await render(
            language: .simplifiedChinese, height: 720,
            approvalMode: .trusted, hooksNeedRepair: true,
            showsError: true, variant: "full-repair-error"
        )
    }

    func testEnglishFullContentWithTrustedApprovalRepairAndError() async throws {
        try await render(
            language: .english, height: 720,
            approvalMode: .trusted, hooksNeedRepair: true,
            showsError: true, variant: "full-repair-error"
        )
    }

    private func render(
        language: AppLanguage,
        height: CGFloat,
        approvalMode: ApprovalMode = .ask,
        hooksNeedRepair: Bool = false,
        isUpdatingHooks: Bool = false,
        showsError: Bool = false,
        variant: String = "viewport"
    ) async throws {
        // 480 pt minimum panel width minus 24 pt of outer content inset.
        let width: CGFloat = 456
        let probe = InteractionProbe()
        let controls = NotchQuickControls(
            language: language,
            idleBehavior: probe.binding(IdleNotchBehavior.alwaysVisible, name: "idleBehavior"),
            compactStyle: probe.binding(CompactNotchStyle.detailed, name: "compactStyle"),
            approvalMode: probe.binding(approvalMode, name: "approvalMode"),
            expandOnHover: probe.binding(true, name: "expandOnHover"),
            hoverDelay: 0.25,
            showUsageLimits: probe.binding(false, name: "showUsageLimits"),
            launchAtLogin: probe.binding(false, name: "launchAtLogin"),
            hooksInstalled: probe.binding(true, name: "hooksInstalled"),
            hooksNeedRepair: hooksNeedRepair,
            isUpdatingHooks: isUpdatingHooks,
            errorMessage: showsError ? language.text(
                "Bridge update failed. Open All Settings to review integrations.",
                "桥接更新未完成，请打开完整设置检查集成。"
            ) : nil,
            onBack: probe.action("back"),
            onToggleLanguage: probe.action("language"),
            onOpenSettings: probe.action("settings"),
            onQuit: probe.action("quit")
        )
        .frame(width: width, height: height)
        .background(Color.black)
        .preferredColorScheme(.dark)

        // ImageRenderer omits the AppKit-backed segmented controls and switches.
        // Host once in a never-presented window and cache its native display once.
        let host = NSHostingView(rootView: controls)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: bounds, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.bounds.width, width, accuracy: 1)
        XCTAssertEqual(host.bounds.height, height, accuracy: 1)
        XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
        XCTAssertFalse(window.isVisible, "The fixture must stay offscreen")

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertEqual(
            Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh),
            Double(width / height), accuracy: 0.01
        )
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        XCTAssertTrue(probe.setterCalls.isEmpty,
                      "Rendering must not change any setting: \(probe.setterCalls)")
        XCTAssertTrue(probe.actionCalls.isEmpty,
                      "Rendering must not navigate, change language, open settings or quit: \(probe.actionCalls)")

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "quick-settings-\(language.rawValue)-456x\(Int(height))-\(variant)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
