//
//  FocusVerificationPolicyTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import Agent_Notch

final class FocusVerificationPolicyTests: XCTestCase {
    private actor Probe {
        private var results: [Bool]
        private(set) var delays: [UInt64] = []
        private(set) var checkCount = 0

        init(results: [Bool]) {
            self.results = results
        }

        func check() -> Bool {
            checkCount += 1
            return results.isEmpty ? false : results.removeFirst()
        }

        func recordSleep(_ delay: UInt64) {
            delays.append(delay)
        }

        func snapshot() -> (checkCount: Int, delays: [UInt64]) {
            (checkCount, delays)
        }
    }

    func testImmediateSuccessDoesNotWait() async {
        let probe = Probe(results: [true])

        let outcome = await FocusVerificationPolicy.evaluate(
            delays: [10, 20],
            isCancelled: { false },
            sleep: { await probe.recordSleep($0) },
            checkSucceeded: { await probe.check() }
        )

        XCTAssertEqual(outcome, .success)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.checkCount, 1)
        XCTAssertEqual(snapshot.delays, [])
    }

    func testDelayedSuccessStopsAfterFirstConfirmedFocus() async {
        let probe = Probe(results: [false, false, true])

        let outcome = await FocusVerificationPolicy.evaluate(
            delays: [10, 20, 30],
            isCancelled: { false },
            sleep: { await probe.recordSleep($0) },
            checkSucceeded: { await probe.check() }
        )

        XCTAssertEqual(outcome, .success)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.checkCount, 3)
        XCTAssertEqual(snapshot.delays, [10, 20])
    }

    func testFailedVerificationExhaustsBoundedSchedule() async {
        let probe = Probe(results: [false, false, false])

        let outcome = await FocusVerificationPolicy.evaluate(
            delays: [10, 20],
            isCancelled: { false },
            sleep: { await probe.recordSleep($0) },
            checkSucceeded: { await probe.check() }
        )

        XCTAssertEqual(outcome, .failed)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.checkCount, 3)
        XCTAssertEqual(snapshot.delays, [10, 20])
    }

    func testCancellationSkipsChecksAndWaits() async {
        let probe = Probe(results: [true])

        let outcome = await FocusVerificationPolicy.evaluate(
            delays: [10],
            isCancelled: { true },
            sleep: { await probe.recordSleep($0) },
            checkSucceeded: { await probe.check() }
        )

        XCTAssertEqual(outcome, .cancelled)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.checkCount, 0)
        XCTAssertEqual(snapshot.delays, [])
    }

    func testYabaiFocusRequiresMatchingWindowIdentityAndFocusFlag() {
        let focused = #"{"id":42,"pid":100,"has-focus":true}"#
        let unfocused = #"{"id":42,"pid":100,"has-focus":false}"#

        XCTAssertTrue(WindowFinder.isFocusedWindow(id: 42, yabaiOutput: focused))
        XCTAssertFalse(WindowFinder.isFocusedWindow(id: 7, yabaiOutput: focused))
        XCTAssertFalse(WindowFinder.isFocusedWindow(id: 42, yabaiOutput: unfocused))
        XCTAssertFalse(WindowFinder.isFocusedWindow(id: 42, yabaiOutput: "not-json"))
    }
}
