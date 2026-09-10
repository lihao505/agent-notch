//
//  FocusVerificationPolicy.swift
//  ClaudeIsland
//
//  Bounded post-action verification for terminal/window jumps.
//

import Foundation

nonisolated enum FocusVerificationOutcome: Equatable, Sendable {
    case success
    case failed
    case cancelled
}

/// A focus command finishing successfully only means macOS accepted the
/// request. The target may still be switching Spaces, or another window may
/// have won the race, so callers verify the observable result before reporting
/// success.
nonisolated struct FocusVerificationPolicy {
    /// Fast paths normally pass the immediate check. These follow-up checks
    /// cover Space/window transitions without polling indefinitely.
    static let defaultDelays: [UInt64] = [
        120_000_000,
        320_000_000,
        640_000_000,
    ]

    nonisolated static func evaluate(
        delays: [UInt64] = defaultDelays,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: delay)
        },
        checkSucceeded: @escaping @Sendable () async -> Bool
    ) async -> FocusVerificationOutcome {
        guard !isCancelled() else { return .cancelled }
        if await checkSucceeded() {
            return .success
        }

        for delay in delays {
            await sleep(delay)
            guard !isCancelled() else { return .cancelled }
            if await checkSucceeded() {
                return .success
            }
        }

        return isCancelled() ? .cancelled : .failed
    }
}
