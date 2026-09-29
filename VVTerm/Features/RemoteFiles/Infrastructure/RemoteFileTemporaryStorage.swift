import Foundation

final class RemoteFileTemporaryStorage {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let fileManager: FileManager
    private let rootDirectory: URL

    nonisolated init(
        fileManager: FileManager = .default,
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("VVTermRemoteFiles", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Previews", suggestedName: entry.name)
    }

    func makeTransferFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Transfers", suggestedName: entry.name.isEmpty ? "download" : entry.name)
    }

    func removeItem(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func removePreviewArtifact(for payload: RemoteFileViewerPayload?) {
        guard let previewFileURL = payload?.previewFileURL else { return }
        removeItem(at: previewFileURL)
    }

    private func makeFileURL(in subdirectoryName: String, suggestedName: String) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(subdirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = URL(fileURLWithPath: suggestedName)
        let fileExtension = fileURL.pathExtension
        var url = directory.appendingPathComponent(UUID().uuidString)
        if !fileExtension.isEmpty {
            url.appendPathExtension(fileExtension)
        }
        return url
    }
}
