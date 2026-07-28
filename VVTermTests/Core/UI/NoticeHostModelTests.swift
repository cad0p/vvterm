import Testing
@testable import VVTerm

@MainActor
struct NoticeHostModelTests {
    @Test
    func bottomOperationsStackAndUpdateByIdentifier() {
        let host = NoticeHostModel()
        host.show(operation(id: "first", message: "Starting"))
        host.show(operation(id: "second", message: "Waiting"))

        host.update(id: "first", message: "Uploading")

        #expect(host.bottomOperations.count == 2)
        #expect(host.bottomOperations.map(\.id) == ["first", "second"])
        #expect(host.bottomOperations[0].message == "Uploading")
        #expect(host.bottomOperations[1].message == "Waiting")
    }

    @Test
    func dismissRemovesOnlyTheMatchingOperation() {
        let host = NoticeHostModel()
        host.show(operation(id: "first", message: "Starting"))
        host.show(operation(id: "second", message: "Waiting"))

        host.dismiss(id: "first")

        #expect(host.bottomOperations.map(\.id) == ["second"])
    }

    @Test
    func replacingPersistentOperationWithCompletionAutoDismisses() async throws {
        let host = NoticeHostModel()
        host.show(operation(id: "download", message: "Ready to export"))
        host.show(
            NoticeItem(
                id: "download",
                lane: .bottomOperation,
                level: .success,
                title: "Downloading",
                message: "Export complete",
                lifetime: .autoDismiss(.milliseconds(20))
            )
        )

        // Poll instead of a fixed sleep: the dismissal is Task.sleep(20ms) +
        // a MainActor hop, which can exceed a fixed 100ms wait on a loaded CI
        // runner (observed flake in GitHub Actions).
        let deadline = ContinuousClock.now + .seconds(3)
        while !host.bottomOperations.isEmpty {
            if ContinuousClock.now > deadline {
                Issue.record("auto-dismiss did not fire within 3s")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(host.bottomOperations.isEmpty)
    }

    private func operation(id: String, message: String) -> NoticeItem {
        NoticeItem(
            id: id,
            lane: .bottomOperation,
            level: .info,
            title: "Uploading",
            message: message
        )
    }
}
