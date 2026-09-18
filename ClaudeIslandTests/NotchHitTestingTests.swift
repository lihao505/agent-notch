// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchHitTestingTests: XCTestCase {
    private final class FlippedParent: NSView {
        override var isFlipped: Bool { true }
    }

    func testHostingHitRegionUsesWindowCoordinates() async {
        checkHitRegion(flippedParent: false)
    }

    func testHostingHitRegionConvertsFlippedOffsetParent() async {
        checkHitRegion(flippedParent: true)
    }

    private func checkHitRegion(flippedParent: Bool) {
        // This window is never ordered onscreen and receives no real events.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 750),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let parent: NSView = flippedParent ? FlippedParent() : NSView()
        parent.frame = CGRect(x: 30, y: 40, width: 1452, height: 710)
        window.contentView?.addSubview(parent)
        let host = PassThroughHostingView(rootView: Color.black)
        host.frame = parent.bounds
        host.hitTestRect = { CGRect(x: 480, y: 390, width: 552, height: 360) }
        parent.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let inside = parent.convert(CGPoint(x: 756, y: 730), from: nil)
        let outside = parent.convert(CGPoint(x: 756, y: 100), from: nil)
        XCTAssertNotNil(host.hitTest(inside))
        XCTAssertNil(host.hitTest(outside))
        window.close()
    }

    func testPassThroughCopiesOriginalMouseEventWithoutLosingMetadata() async throws {
        for type: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            let original = try XCTUnwrap(CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: -900, y: -350),
                mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left
            ))
            original.flags = [.maskShift, .maskCommand]
            original.setIntegerValueField(.mouseEventClickState, value: 2)
            let event = try XCTUnwrap(NSEvent(cgEvent: original))
            let copy = try XCTUnwrap(NotchPanel.passThroughEvent(from: event))
            XCTAssertEqual(copy.type, original.type)
            XCTAssertEqual(copy.location, original.location)
            XCTAssertEqual(copy.flags, original.flags)
            XCTAssertEqual(copy.getIntegerValueField(.mouseEventClickState), 2)
            copy.location = .zero
            XCTAssertEqual(original.location, CGPoint(x: -900, y: -350))
        }
    }

    func testPassThroughRejectsUnrelatedEvents() async throws {
        let original = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: .zero, mouseButton: .left
        ))
        XCTAssertNil(NotchPanel.passThroughEvent(from: try XCTUnwrap(NSEvent(cgEvent: original))))
    }
}
