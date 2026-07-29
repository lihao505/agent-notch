//
//  UsageLimitMonitor.swift
//  ClaudeIsland
//
//  Reads subscription rate-limit snapshots emitted by local coding agents.
//  No credentials or network requests are required.
//

import Combine
import Foundation

struct UsageLimitWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct UsageLimitSnapshot: Equatable, Sendable {
    let source: AgentSource
    let planType: String?
    let primary: UsageLimitWindow?
    let secondary: UsageLimitWindow?
    let updatedAt: Date
}

@MainActor
final class UsageLimitMonitor: ObservableObject {
    static let shared = UsageLimitMonitor()

    @Published private(set) var snapshot: UsageLimitSnapshot?

    private var timer: Timer?
    private var isRefreshing = false

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) {
            _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            let latest = await Task.detached(priority: .utility) {
                Self.loadLatestCodexSnapshot()
            }.value
            snapshot = latest
            isRefreshing = false
        }
    }

    private nonisolated static func loadLatestCodexSnapshot()
        -> UsageLimitSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > newestDate else {
                continue
            }
            newestURL = url
            newestDate = modified
        }

        guard let newestURL,
              let rateLimits = lastRateLimits(in: newestURL) else {
            return nil
        }

        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])
        guard primary != nil || secondary != nil else {
            return nil
        }

        return UsageLimitSnapshot(
            source: .codex,
            planType: rateLimits["plan_type"] as? String,
            primary: primary,
            secondary: secondary,
            updatedAt: newestDate
        )
    }

    private nonisolated static func lastRateLimits(
        in url: URL
    ) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let maximumTailBytes: UInt64 = 1_048_576
        let offset = fileSize > maximumTailBytes
            ? fileSize - maximumTailBytes
            : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst() // The tail may begin in the middle of a row.
        }

        for line in lines.reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else {
                continue
            }
            return limits
        }
        return nil
    }

    private nonisolated static func parseWindow(
        _ value: Any?
    ) -> UsageLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = number(dictionary["used_percent"]),
              let windowMinutes = number(dictionary["window_minutes"]),
              let resetsAt = number(dictionary["resets_at"]) else {
            return nil
        }

        return UsageLimitWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: Int(windowMinutes),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
