// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchFullScreenTests: XCTestCase {
    func testPreferenceDefaultsVisibleAndRestoresBothChoices() async throws {
        let suite = "NotchFullScreenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NotchPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showInFullScreen)

        for choice in [false, true] {
            preferences.showInFullScreen = choice
            let restored = NotchPreferences(defaults: defaults)
            XCTAssertEqual(restored.showInFullScreen, choice)
            XCTAssertEqual(defaults.object(forKey: "notchShowInFullScreen") as? Bool, choice)
        }
    }

    func testWindowPolicySwitchesExclusivelyAndPreservesOtherBehavior() async {
        let panel = NotchPanel(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: false
        )
        // This standalone fixture is owned by ARC, not an NSWindowController.
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let preserved: NSWindow.CollectionBehavior = [
            .stationary, .canJoinAllSpaces, .ignoresCycle
        ]
        for shows in [false, true, false, true] {
            panel.setShowsInFullScreen(shows)
            XCTAssertEqual(panel.showsInFullScreen, shows)
            XCTAssertEqual(panel.collectionBehavior.contains(.fullScreenAuxiliary), shows)
            XCTAssertEqual(panel.collectionBehavior.contains(.fullScreenNone), !shows)
            XCTAssertTrue(panel.collectionBehavior.isSuperset(of: preserved))
            XCTAssertEqual(
                panel.allowsPresentationOnCurrentSpace,
                shows || panel.isOnActiveSpace
            )
        }
    }
}
