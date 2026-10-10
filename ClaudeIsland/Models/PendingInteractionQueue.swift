//
//  Modified by lihao505 for Agent Notch, 2026.
//  PendingInteractionQueue.swift
//  ClaudeIsland
//
//  Ordered storage for approval, question, and plan interactions.
//

import Foundation

/// A session may receive more than one blocking request while parallel tools or
/// subagents are active. Keep every request by its exact tool identity and show
/// them in arrival order instead of letting the latest hook overwrite the one
/// already visible to the user.
nonisolated struct PendingInteractionQueue: Equatable, Sendable {
    private(set) var items: [PermissionContext] = []

    nonisolated var current: PermissionContext? {
        items.first
    }

    nonisolated var count: Int {
        items.count
    }

    nonisolated var toolUseIds: [String] {
        items.map(\.toolUseId)
    }

    nonisolated func contains(toolUseId: String) -> Bool {
        items.contains { $0.toolUseId == toolUseId }
    }

    mutating func enqueue(_ context: PermissionContext) {
        if let index = items.firstIndex(where: {
            $0.toolUseId == context.toolUseId
        }) {
            // Preserve FIFO position, but never inherit input from a replaced
            // connection. Only a refresh of this exact request may fill gaps.
            let existing = items[index]
            let isSameRequest = existing.requestID == context.requestID
            items[index] = PermissionContext(
                toolUseId: context.toolUseId,
                toolName: context.toolName,
                toolInput: isSameRequest ? context.toolInput ?? existing.toolInput : context.toolInput,
                receivedAt: isSameRequest ? min(existing.receivedAt, context.receivedAt) : context.receivedAt,
                requestID: context.requestID
            )
        } else {
            items.append(context)
        }
    }

    @discardableResult
    mutating func remove(toolUseId: String) -> PermissionContext? {
        guard let index = items.firstIndex(where: {
            $0.toolUseId == toolUseId
        }) else {
            return nil
        }
        return items.remove(at: index)
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: false)
    }
}
