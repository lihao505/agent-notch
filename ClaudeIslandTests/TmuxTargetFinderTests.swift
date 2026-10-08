import Foundation
import XCTest
@testable import Agent_Notch

final class TmuxTargetFinderTests: XCTestCase {
    func testWorkingDirectoryWithMultiplePanesIsNotAUniqueTarget() async {
        let finder = TmuxTargetFinder(commandRunner: { _ in
            "first:0.0\t%1\t/tmp/shared project\nsecond:0.0\t%2\t/tmp/shared project\n"
        })
        let target = await finder.findTarget(forWorkingDirectory: "/tmp/shared project")
        XCTAssertNil(target)
    }

    func testAmbiguousProcessAncestryCannotChooseFirstPane() async {
        let finder = TmuxTargetFinder(commandRunner: { _ in
            "outer:0.0\t%1\t10\ninner:0.0\t%2\t20\n"
        }, processTreeProvider: {
            [30: Agent_Notch.ProcessInfo(pid: 30, ppid: 20, command: "claude", tty: nil),
             20: Agent_Notch.ProcessInfo(pid: 20, ppid: 10, command: "shell", tty: nil),
             10: Agent_Notch.ProcessInfo(pid: 10, ppid: 1, command: "shell", tty: nil)]
        })
        let target = await finder.findTarget(forClaudePid: 30)
        XCTAssertNil(target)
    }

    func testUniqueDirectoryWithSpacesUsesStablePaneID() async {
        let finder = TmuxTargetFinder(commandRunner: { _ in
            "session with spaces:2.1\t%42\t/tmp/shared project\nother:0.0\t%43\t/tmp/other\n"
        })
        let target = await finder.findTarget(forWorkingDirectory: "/tmp/shared project")
        XCTAssertEqual(target?.session, "session with spaces")
        XCTAssertEqual(target?.targetString, "%42")
    }

    func testLinkedWindowRowsDeduplicatePhysicalPane() async {
        let finder = TmuxTargetFinder(commandRunner: { _ in
            "first:0.0\t%1\t/tmp/shared\nlinked:1.0\t%1\t/tmp/shared\n"
        })
        let target = await finder.findTarget(forWorkingDirectory: "/tmp/shared")
        XCTAssertEqual(target?.targetString, "%1")
    }

    func testInvalidOrConflictingRowsCannotProduceFalseUniqueTarget() async {
        for output in [
            "first:0.0\t%1\t/tmp/shared\nmalformed row\n",
            "first:0.0\tbad-id\t/tmp/shared\n",
            "first:0.0\t%1\t/tmp/shared\nlinked:1.0\t%1\t/tmp/different\n"
        ] {
            let finder = TmuxTargetFinder(commandRunner: { _ in output })
            let target = await finder.findTarget(forWorkingDirectory: "/tmp/shared")
            XCTAssertNil(target)
        }
    }

    func testTTYRequiresUniquePaneAndNormalizesDevicePrefix() async {
        let unique = TmuxTargetFinder(commandRunner: { _ in
            "first:0.0\t%1\t/dev/ttys001\n"
        })
        let target = await unique.findTarget(forTTY: "ttys001")
        XCTAssertEqual(target?.targetString, "%1")
        let ambiguous = TmuxTargetFinder(commandRunner: { _ in
            "first:0.0\t%1\t/dev/ttys001\nsecond:0.0\t%2\t/dev/ttys001\n"
        })
        let rejected = await ambiguous.findTarget(forTTY: "/dev/ttys001")
        XCTAssertNil(rejected)
    }

    func testKnownPIDFailureDoesNotFallBackToMatchingTTYOrDirectory() async {
        let finder = TmuxTargetFinder(commandRunner: { args in
            let format = args.last ?? ""
            if format.contains("pane_pid") { return "first:0.0\t%1\t10\n" }
            if format.contains("pane_tty") { return "first:0.0\t%1\t/dev/ttys001\n" }
            return "first:0.0\t%1\t/tmp/shared\n"
        }, processTreeProvider: { [:] })
        let session = SessionState(sessionId: "missing-pid", cwd: "/tmp/shared",
                                   pid: 99, tty: "ttys001", isInTmux: true)
        let target = await finder.findTarget(for: session)
        XCTAssertNil(target)
        let ttyTarget = await finder.findTarget(forTTY: "ttys001")
        XCTAssertNotNil(ttyTarget, "The lower-confidence match exists but must not override PID failure")
    }

    func testKnownPIDWinsOverStaleTTYAndCurrentPaneUsesStableID() async {
        let finder = TmuxTargetFinder(commandRunner: { args in
            if args.first == "display-message" { return "%42\n" }
            return "first:0.0\t%42\t10\nother:0.1\t%43\t20\n"
        }, processTreeProvider: {
            [99: Agent_Notch.ProcessInfo(pid: 99, ppid: 10, command: "claude", tty: nil)]
        })
        let session = SessionState(sessionId: "tracked-pid", cwd: "/tmp/shared",
                                   pid: 99, tty: "stale-tty", isInTmux: true)
        let target = await finder.findTarget(for: session)
        XCTAssertEqual(target?.targetString, "%42")
        let active = await finder.isSessionPaneActive(claudePid: 99)
        XCTAssertTrue(active)
    }

    func testMissingPIDUsesTTYWithoutDirectoryFallbackAndLegacyDirectoryMustBeUnique() async {
        let finder = TmuxTargetFinder(commandRunner: { args in
            if args.last?.contains("pane_tty") == true {
                return "first:0.0\t%1\t/dev/ttys001\n"
            }
            return "first:0.0\t%1\t/tmp/shared\n"
        })
        let byTTY = await finder.findTarget(for: SessionState(
            sessionId: "tty-only", cwd: "/tmp/shared", tty: "ttys001", isInTmux: true
        ))
        XCTAssertEqual(byTTY?.targetString, "%1")
        let staleTTY = await finder.findTarget(for: SessionState(
            sessionId: "stale-tty", cwd: "/tmp/shared", tty: "missing", isInTmux: true
        ))
        XCTAssertNil(staleTTY, "A known TTY must not fall through to cwd")
        let byDirectory = await finder.findTarget(for: SessionState(
            sessionId: "legacy", cwd: "/tmp/shared", isInTmux: true
        ))
        XCTAssertEqual(byDirectory?.targetString, "%1")
    }

    func testStablePaneIDValidationAndLegacyTargetCompatibility() {
        XCTAssertEqual(TmuxTarget(from: "session:0.1")?.targetString, "session:0.1")
        XCTAssertEqual(TmuxTarget(session: "session", window: "0", pane: "1").targetString, "session:0.1")
        XCTAssertEqual(TmuxTarget(from: "session:0.1", paneID: "%12")?.targetString, "%12")
        for invalid in ["%", "12", "%12:0", "%١", "%1\n"] {
            XCTAssertNil(TmuxTarget(from: "session:0.1", paneID: invalid))
        }
    }

    func testPrivateTmuxServerRejectsAmbiguityAndDoesNotRetargetClosedPane() async throws {
        guard let tmux = await TmuxPathFinder.shared.getTmuxPath() else {
            throw XCTSkip("tmux not installed; private-server integration is not verified")
        }
        let root = try await ProcessExecutor.shared.run("/usr/bin/mktemp", arguments: [
            "-d", "/tmp/agent-notch-tmux.XXXXXX"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/tmp/agent-notch-tmux.") else {
            return XCTFail("Unexpected fixture directory")
        }
        let socket = root + "/private.sock"
        let prefix = ["-u", "-f", "/dev/null", "-S", socket]
        defer {
            _ = ProcessExecutor.shared.runSyncOrNil(tmux, arguments: prefix + ["kill-server"])
            try? FileManager.default.removeItem(atPath: root)
        }
        // Foundation's test-host path normalization may retain /tmp; tmux
        // reports the physical /private/tmp path. Compare physical cwd values.
        let projectDirectory = root + "/测试 project"
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: false)
        let cwd = try await ProcessExecutor.shared.runCapturingOutput(
            "/bin/pwd", arguments: ["-P"], currentDirectoryPath: projectDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstID = try await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "fixture session",
            "-c", cwd, "/bin/sleep", "60"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "split-window", "-d", "-t", firstID, "-c", cwd, "/bin/sleep", "60"
        ])
        let paneList = try await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}"
        ])
        let records = paneList.split(separator: "\n").map { $0.components(separatedBy: "\t") }
        XCTAssertEqual(records.count, 2)
        let first = try XCTUnwrap(records.first { $0.first == firstID },
                                  "Fixture first ID: \(String(reflecting: firstID)); records: \(records)")
        XCTAssertEqual(first.count, 4)
        let pid = try XCTUnwrap(Int(first[1]))
        XCTAssertEqual(first[3], cwd)
        let finder = TmuxTargetFinder(commandRunner: { args in
            try? await ProcessExecutor.shared.run(tmux, arguments: prefix + args)
        })
        let ambiguous = await finder.findTarget(forWorkingDirectory: cwd)
        XCTAssertNil(ambiguous)
        let found = await finder.findTarget(forClaudePid: pid)
        let target = try XCTUnwrap(found)
        XCTAssertEqual(target.targetString, firstID)
        let ttyTarget = await finder.findTarget(forTTY: first[2])
        XCTAssertEqual(ttyTarget?.targetString, firstID)
        let missing = await finder.findTarget(for: SessionState(
            sessionId: "fixture-missing", cwd: cwd, pid: 999_999, tty: first[2], isInTmux: true
        ))
        XCTAssertNil(missing)

        _ = try await ProcessExecutor.shared.run(tmux, arguments: prefix + ["kill-pane", "-t", firstID])
        let remaining = await finder.findTarget(forWorkingDirectory: cwd)
        let remainingTarget = try XCTUnwrap(remaining)
        XCTAssertNotEqual(remainingTarget.paneID, firstID)
        let legacyAddress = "\(target.session):\(target.window).\(target.pane)"
        let nowAtOldIndex = try await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "display-message", "-p", "-t", legacyAddress, "#{pane_id}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(nowAtOldIndex, remainingTarget.paneID)
        let closedTarget = try? await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "display-message", "-p", "-t", target.targetString, "#{pane_id}"
        ])
        // display-message may print an empty value with exit 0 for a missing
        // target. A command that operates on a pane must actually reject it.
        XCTAssertTrue(closedTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let selectClosed = try? await ProcessExecutor.shared.run(tmux, arguments: prefix + [
            "select-pane", "-t", target.targetString
        ])
        XCTAssertNil(selectClosed, "A closed stable pane must not resolve to the reused index")
        _ = try await ProcessExecutor.shared.run(tmux, arguments: prefix + ["kill-server"])
        // tmux can leave its socket pathname after exit; connection failure,
        // not pathname absence, proves this private server no longer serves.
        let afterStop = try? await ProcessExecutor.shared.run(tmux, arguments: prefix + ["list-panes"])
        XCTAssertNil(afterStop)
    }
}
