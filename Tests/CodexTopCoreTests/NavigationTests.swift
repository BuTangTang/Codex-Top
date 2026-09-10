import XCTest
@testable import CodexTopCore

final class NavigationTests: XCTestCase {
    private func task(id: String) -> CodexTask {
        CodexTask(id: id, title: "Synthetic", project: "Fixture", createdAt: .now, updatedAt: .now,
                  rolloutURL: URL(fileURLWithPath: "/fixture/rollout.jsonl"))
    }
    func testThreadLinkPreservesTheSelectedTaskID() {
        let id = "00000000-0000-4000-8000-000000000003"
        XCTAssertEqual(task(id: id).deepLink?.absoluteString, "codex://threads/\(id)")
    }
    func testInvalidIDsCannotChangeDestinationOrAddQueryParameters() {
        for id in ["", "not-an-id", "../settings/usage", "00000000-0000-4000-8000-000000000003?host=other", "https://example.com"] {
            XCTAssertNil(task(id: id).deepLink)
        }
    }
}
