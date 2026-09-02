import XCTest
@testable import Agent_Notch

final class ConversationReconciliationTests: XCTestCase {
    func testNativeMessageReplacesEquivalentOptimisticMessage() async {
        let timestamp = Date()
        let optimistic = ChatHistoryItem(
            id: "cli-user-test",
            type: .user("continue"),
            timestamp: timestamp
        )
        let native = ChatHistoryItem(
            id: "native-user-test",
            type: .user("continue"),
            timestamp: timestamp.addingTimeInterval(1)
        )

        let result = await MainActor.run {
            ChatHistoryManager.shared.reconcile(
                nativeHistory: [native],
                optimisticHistory: [optimistic]
            )
        }

        XCTAssertEqual(result.map(\.id), ["native-user-test"])
    }

    func testUnmatchedOptimisticMessageSurvivesReconciliation() async {
        let optimistic = ChatHistoryItem(
            id: "cli-assistant-test",
            type: .assistant("streamed reply"),
            timestamp: Date()
        )

        let result = await MainActor.run {
            ChatHistoryManager.shared.reconcile(
                nativeHistory: [],
                optimisticHistory: [optimistic]
            )
        }

        XCTAssertEqual(result.map(\.id), ["cli-assistant-test"])
    }
}
