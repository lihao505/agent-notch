//
//  Modified by lihao505 for Agent Notch, 2026.
//  JSONLInterruptWatcher.swift
//  ClaudeIsland
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

/// Logger for interrupt watcher
private let logger = Logger(subsystem: "com.claudeisland", category: "Interrupt")

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionId: String, observedAt: Date)
}

/// Buffers only complete JSONL records. File-system callbacks can split one
/// row in the middle of a UTF-8 scalar, so decoding each callback directly is
/// lossy. Oversized malformed rows are discarded without unbounded growth.
struct JSONLLineBuffer {
    private(set) var pending = Data()
    private var discardingOversizedLine = false
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 1_048_576) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var incoming = data

        if discardingOversizedLine {
            guard let newline = incoming.firstIndex(of: 0x0A) else {
                return []
            }
            incoming.removeSubrange(incoming.startIndex...newline)
            discardingOversizedLine = false
        }

        pending.append(incoming)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = Data(pending[..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            guard lineData.count <= maximumLineBytes,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        if pending.count > maximumLineBytes {
            pending.removeAll(keepingCapacity: false)
            discardingOversizedLine = true
        }
        return lines
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
    }
}

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
final class JSONLInterruptWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var retryWorkItem: DispatchWorkItem?
    private var lastOffset: UInt64 = 0
    private var lineBuffer = JSONLLineBuffer()
    private var isRequested = false
    private var retryAttempt = 0
    private let sessionId: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.claudeisland.interruptwatcher", qos: .userInteractive)

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    nonisolated private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user"
    ]

    init(sessionId: String, cwd: String) {
        self.sessionId = sessionId
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ".", with: "-")
        self.filePath = ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
    }

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRequested = true
            self.retryAttempt = 0
            self.openWatcher(seekToEnd: true)
        }
    }

    private func openWatcher(seekToEnd: Bool) {
        closeCurrentSource()
        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open file: \(self.filePath, privacy: .public)")
            scheduleOpenRetry()
            return
        }

        fileHandle = handle

        do {
            lastOffset = seekToEnd ? try handle.seekToEnd() : 0
            if !seekToEnd {
                try handle.seek(toOffset: 0)
            }
            lineBuffer.reset()
            retryAttempt = 0
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            fileHandle = nil
            scheduleOpenRetry()
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )

        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self, let newSource else { return }
            let events = newSource.data
            if events.contains(.delete) ||
                events.contains(.rename) ||
                events.contains(.revoke) {
                self.closeCurrentSource()
                self.scheduleOpenRetry()
            } else {
                self.checkForInterrupt()
            }
        }

        newSource.setCancelHandler {
            try? handle.close()
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching: \(self.sessionId.prefix(8), privacy: .public)...")
    }

    private func scheduleOpenRetry() {
        guard isRequested, retryWorkItem == nil else { return }
        let exponent = min(retryAttempt, 3)
        let delay = min(0.25 * pow(2.0, Double(exponent)), 2.0)
        retryAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            guard self.isRequested else { return }
            self.openWatcher(seekToEnd: false)
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        if currentSize < lastOffset {
            lastOffset = 0
            lineBuffer.reset()
        }
        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd() else {
            return
        }

        lastOffset = currentSize

        for line in lineBuffer.append(newData) {
            let detectedAt = Date()
            if let observedAt = Self.interruptObservedAt(
                in: line,
                detectedAt: detectedAt
            ) {
                logger.info("Detected interrupt in session: \(self.sessionId.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.didDetectInterrupt(
                        sessionId: self.sessionId,
                        observedAt: observedAt
                    )
                }
                return
            }
        }
    }

    nonisolated static func interruptObservedAt(
        in line: String,
        detectedAt: Date
    ) -> Date? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              isInterruptPayload(json) else {
            return nil
        }

        guard let value = json["timestamp"] as? String else {
            return detectedAt
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
        guard let parsed,
              parsed <= detectedAt.addingTimeInterval(5 * 60) else {
            return detectedAt
        }
        return parsed
    }

    nonisolated private static func isInterruptPayload(
        _ json: [String: Any]
    ) -> Bool {
        if containsInterruptedFlag(json) {
            return true
        }

        if json["type"] as? String == "user",
           containsInterruptText(json) {
            return true
        }

        return containsErroredToolResult(json)
    }

    nonisolated private static func containsInterruptedFlag(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["interrupted"] as? Bool == true { return true }
            return dictionary.values.contains(where: containsInterruptedFlag)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsInterruptedFlag)
        }
        return false
    }

    nonisolated private static func containsErroredToolResult(
        _ value: Any
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "tool_result",
               dictionary["is_error"] as? Bool == true,
               containsInterruptText(dictionary) {
                return true
            }
            return dictionary.values.contains(where: containsErroredToolResult)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsErroredToolResult)
        }
        return false
    }

    nonisolated private static func containsInterruptText(_ value: Any) -> Bool {
        if let string = value as? String {
            return interruptContentPatterns.contains {
                string.localizedCaseInsensitiveContains($0)
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: containsInterruptText)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsInterruptText)
        }
        return false
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRequested = false
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.closeCurrentSource()
        }
    }

    private func closeCurrentSource() {
        if source != nil {
            logger.debug("Stopped watching: \(self.sessionId.prefix(8), privacy: .public)...")
        }
        let oldSource = source
        source = nil
        fileHandle = nil
        oldSource?.cancel()
    }

    deinit {
        retryWorkItem?.cancel()
        source?.cancel()
        if source == nil {
            try? fileHandle?.close()
        }
    }
}

// MARK: - Interrupt Watcher Manager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    static let shared = InterruptWatcherManager()

    private var watchers: [String: JSONLInterruptWatcher] = [:]
    weak var delegate: JSONLInterruptWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, cwd: String) {
        guard watchers[sessionId] == nil else { return }

        let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionId] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionId: String) -> Bool {
        watchers[sessionId] != nil
    }
}
