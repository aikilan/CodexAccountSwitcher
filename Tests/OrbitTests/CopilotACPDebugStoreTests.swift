import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CopilotACPDebugStoreTests: XCTestCase {
    func testRingBuffersAndClear() {
        let store = CopilotACPDebugStore(requestLimit: 2, eventLimit: 3)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()

        store.recordRequestStarted(
            id: firstID,
            bridgeBaseURL: "http://127.0.0.1:1",
            path: "/responses",
            model: "gpt-4.1",
            reasoningEffort: "medium",
            workingDirectoryPath: "/tmp/one",
            configDirectoryPath: "/tmp/config",
            payloadPreview: "first"
        )
        store.recordRequestStarted(
            id: secondID,
            bridgeBaseURL: "http://127.0.0.1:2",
            path: "/responses",
            model: "gpt-4.1",
            reasoningEffort: "medium",
            workingDirectoryPath: "/tmp/two",
            configDirectoryPath: "/tmp/config",
            payloadPreview: "second"
        )
        store.recordRequestStarted(
            id: thirdID,
            bridgeBaseURL: "http://127.0.0.1:3",
            path: "/responses",
            model: "gpt-4.1",
            reasoningEffort: "high",
            workingDirectoryPath: "/tmp/three",
            configDirectoryPath: "/tmp/config",
            payloadPreview: "third"
        )

        XCTAssertEqual(store.requests.map(\.id), [secondID, thirdID])
        XCTAssertEqual(store.activeRequestCount, 2)
        XCTAssertEqual(store.latestBridgeBaseURL, "http://127.0.0.1:3")
        XCTAssertEqual(store.events.count, 3)

        store.recordACPCommand(requestID: thirdID, commandLine: "copilot --acp", processID: 123)
        store.appendEvent(requestID: thirdID, title: "extra", detail: "detail", payloadPreview: "payload")

        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.latestCommandLine, "copilot --acp")

        store.recordRequestFinished(id: secondID, status: .completed, httpStatus: 200, errorMessage: nil)
        XCTAssertEqual(store.activeRequestCount, 1)

        store.clear()
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
    }
}
