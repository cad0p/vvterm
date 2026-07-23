import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}

@MainActor
enum RemoteFileDownloadExportCancellationHandler {
    static func handle(
        noticeID: UUID?,
        cleanup: () -> Void,
        dismissNotice: (String) -> Void
    ) {
        cleanup()

        if let noticeID {
            dismissNotice(noticeID.uuidString)
        }
    }
}

struct RemoteFileShareItem: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let title: String
}

struct RemoteFileDragPayload: Codable, Sendable {
    let serverId: UUID
    let entries: [RemoteFileEntry]

    init(serverId: UUID, entry: RemoteFileEntry) {
        self.init(serverId: serverId, entries: [entry])
    }

    init(serverId: UUID, entries: [RemoteFileEntry]) {
        self.serverId = serverId
        self.entries = entries
    }
}

extension UTType {
    static let vvtermRemoteFileEntry = UTType(exportedAs: "app.vivy.vvterm.remote-file-entry")
}
