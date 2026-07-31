import Foundation
import OSLog

actor RemoteClipboardTransferService {
    private let logger = Logger.forCategory("RemoteClipboardTransfer")
    private let sessionId: UUID
    private var didSweepStaleFiles = false

    init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    func uploadImage(
        _ image: ClipboardImagePayload,
        using sshClient: SSHClient
    ) async throws -> RemoteClipboardUpload {
        let environment = await sshClient.remoteEnvironment()
        logger.info(
            "Preparing remote upload [session: \(self.sessionId.uuidString, privacy: .public)] [platform: \(environment.platform.rawValue, privacy: .public)] [shell: \(environment.shellProfile.family.rawValue, privacy: .public)] [bytes: \(image.sizeBytes)]"
        )
        guard environment.platform != .windows else {
            throw TerminalRichPasteError.unsupportedRemotePlatform(environment.platform)
        }
        guard environment.shellProfile.family == .posix else {
            throw TerminalRichPasteError.unsupportedRemoteShell
        }

        let remotePath: String
        do {
            remotePath = try await createRemoteTemporaryPath(
                extension: image.suggestedExtension,
                using: sshClient
            )
        } catch {
            logger.error(
                "Remote temp path creation failed [session: \(self.sessionId.uuidString, privacy: .public)] [error: \(error.localizedDescription, privacy: .public)]"
            )
            if let sshError = error as? SSHError, case .timeout = sshError {
                throw TerminalRichPasteError.remoteUploadFailed(String(localized: "timed out while creating remote temporary file"))
            }
            throw error
        }
        let uploadStrategy: SSHUploadStrategy = {
            switch environment.platform {
            case .linux:
                return .automatic
            case .darwin, .freebsd, .openbsd, .netbsd, .windows, .unknown:
                return .execPreferred
            }
        }()
        logger.info(
            "Uploading remote clipboard image [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .public)] [strategy: \(String(describing: uploadStrategy), privacy: .public)]"
        )

        do {
            try await sshClient.upload(
                image.data,
                to: remotePath,
                permissions: Int32(0o600),
                strategy: uploadStrategy
            )
            logger.info(
                "Remote upload completed [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .public)]"
            )
            scheduleStaleFileSweepIfNeeded(using: sshClient)
            return RemoteClipboardUpload(
                remotePath: remotePath,
                mimeType: image.mimeType,
                sizeBytes: image.sizeBytes
            )
        } catch {
            logger.error(
                "Remote upload failed [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .public)] [error: \(error.localizedDescription, privacy: .public)]"
            )
            await deleteRemoteFileIfNeeded(at: remotePath, using: sshClient)
            if let sshError = error as? SSHError, case .timeout = sshError {
                throw TerminalRichPasteError.remoteUploadFailed(String(localized: "timed out while uploading image bytes"))
            }
            throw TerminalRichPasteError.remoteUploadFailed(error.localizedDescription)
        }
    }

    private func createRemoteTemporaryPath(
        extension fileExtension: String,
        using sshClient: SSHClient
    ) async throws -> String {
        let sanitizedExtension = sanitizeExtension(fileExtension)
        let mktempCommand = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            """
            tmp_base="${TMPDIR:-/tmp}";
            tmp_path="$(mktemp "${tmp_base%/}/vvterm-clipboard-XXXXXX")" || exit 1;
            target_path="${tmp_path}.\(sanitizedExtension)";
            mv "$tmp_path" "$target_path" || {
                rm -f "$tmp_path";
                exit 1;
            };
            printf '%s\n' "$target_path"
            """
        )

        let output = try await sshClient.execute(mktempCommand)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw TerminalRichPasteError.remoteTempFileCreationFailed
        }
        logger.info(
            "Created remote temp path [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(path, privacy: .public)]"
        )
        return path
    }

    private func sanitizeExtension(_ fileExtension: String) -> String {
        let filteredScalars = fileExtension.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
        return sanitized.isEmpty ? "bin" : sanitized.lowercased()
    }

    private func scheduleStaleFileSweepIfNeeded(using sshClient: SSHClient) {
        guard !didSweepStaleFiles else { return }
        didSweepStaleFiles = true

        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            """
            tmp_base="${TMPDIR:-/tmp}";
            for path in "${tmp_base%/}"/vvterm-clipboard-*; do
                [ -f "$path" ] || continue
                find "$path" -prune -mtime +1 -exec rm -f -- {} \\; >/dev/null 2>&1 || true
            done
            """
        )

        let sessionId = self.sessionId
        logger.debug("Scheduling stale clipboard temp file sweep [session: \(self.sessionId.uuidString, privacy: .public)]")

        Task(priority: .utility) {
            let logger = Logger.forCategory("RemoteClipboardTransfer")
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            logger.debug("Sweeping stale clipboard temp files [session: \(sessionId.uuidString, privacy: .public)]")
            do {
                _ = try await sshClient.execute(command, timeout: .seconds(2))
                logger.debug("Finished stale clipboard temp file sweep [session: \(sessionId.uuidString, privacy: .public)]")
            } catch {
                logger.debug(
                    "Skipping stale clipboard temp file sweep result [session: \(sessionId.uuidString, privacy: .public)] [error: \(error.localizedDescription, privacy: .public)]"
                )
            }
        }
    }

    private func deleteRemoteFileIfNeeded(
        at path: String,
        using sshClient: SSHClient
    ) async {
        guard !path.isEmpty else { return }
        let quotedPath = RemoteTerminalBootstrap.shellQuoted(path)
        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand("rm -f -- \(quotedPath)")
        logger.debug(
            "Deleting remote clipboard temp file [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(path, privacy: .public)]"
        )
        _ = try? await sshClient.execute(command)
    }
}
