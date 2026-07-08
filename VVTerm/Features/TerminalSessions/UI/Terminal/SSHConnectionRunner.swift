import Foundation
import os.log

enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        terminal: GhosttyTerminalView,
        logger: Logger,
        onAttempt: @MainActor @escaping (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Void,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: GhosttyTerminalView) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping () -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: GhosttyTerminalView) -> Void
    ) async {
        let maxAttempts = 3
        var lastError: Error?
        var titleParser = TerminalTitleSequenceParser()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                onAttempt(attempt)
            }

            do {
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                _ = try await sshClient.connect(to: server, credentials: credentials)
                guard !Task.isCancelled else { return }

                let size = terminal.terminalSize()
                let cols = Int(size?.columns ?? 80)
                let rows = Int(size?.rows ?? 24)

                await onBeforeShellStart(cols, rows)
                let startup = await startupPlan()
                let shell = try await sshClient.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startup.command
                )

                guard !Task.isCancelled else {
                    await sshClient.closeShell(shell.id)
                    return
                }

                await registerShell(shell, startup.skipTmuxLifecycle)

                guard !Task.isCancelled else { return }
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    for title in titleParser.parse(data) {
                        await MainActor.run {
                            onTitleChange(title)
                        }
                    }
                    let shouldContinue = await MainActor.run {
                        shouldContinueStreaming(data, terminal)
                    }
                    if !shouldContinue { break }
                }

                guard !Task.isCancelled else { return }
                logger.info("SSH shell ended")
                await MainActor.run {
                    onProcessExit()
                }
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await sshClient.disconnect()
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            await MainActor.run {
                onFailure(lastError, terminal)
            }
        }
    }
}
