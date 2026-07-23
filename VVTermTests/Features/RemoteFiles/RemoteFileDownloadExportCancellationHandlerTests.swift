import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileDownloadExportCancellationHandlerTests {
    @Test
    func cancellationCleansUpAndDismissesThePersistentNotice() {
        let noticeID = UUID()
        var didCleanUp = false
        var dismissedNoticeID: String?

        RemoteFileDownloadExportCancellationHandler.handle(
            noticeID: noticeID,
            cleanup: { didCleanUp = true },
            dismissNotice: { dismissedNoticeID = $0 }
        )

        #expect(didCleanUp)
        #expect(dismissedNoticeID == noticeID.uuidString)
    }

    @Test
    func cancellationWithoutNoticeStillCleansUp() {
        var didCleanUp = false
        var didDismiss = false

        RemoteFileDownloadExportCancellationHandler.handle(
            noticeID: nil,
            cleanup: { didCleanUp = true },
            dismissNotice: { _ in didDismiss = true }
        )

        #expect(didCleanUp)
        #expect(!didDismiss)
    }
}
