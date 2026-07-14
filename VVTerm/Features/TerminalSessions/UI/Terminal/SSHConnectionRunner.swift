import Foundation
import os.log

enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        terminal: GhosttyTerminalView,
        logger: Logger,
        shouldContinueConnection: @MainActor @escaping () -> Bool,
        onAttempt: @MainActor @escaping (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping () async -> TerminalShellStartupPlan,
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Void,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: GhosttyTerminalView) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping (_ shellId: UUID, _ reason: TerminalShellEndReason) -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: GhosttyTerminalView) -> Void
    ) async {
        let maxAttempts = 3
        var lastError: Error?
        var titleParser = TerminalTitleSequenceParser()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            guard shouldContinueConnection() else { return }
            onAttempt(attempt)

            do {
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                _ = try await sshClient.connect(to: server, credentials: credentials)
                guard !Task.isCancelled else { return }
                guard shouldContinueConnection() else { return }

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
                var lifecycleParser = startup.tmuxLifecycle.map {
                    TmuxLifecycleStreamParser(markerToken: $0.markerToken)
                }
                var lastLifecycleEvent: TmuxLifecycleEvent?
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    let visibleData: Data
                    if var parser = lifecycleParser {
                        let parsed = parser.consume(data)
                        lifecycleParser = parser
                        visibleData = parsed.output
                        if let event = parsed.events.last {
                            lastLifecycleEvent = event
                        }
                    } else {
                        visibleData = data
                    }

                    for title in titleParser.parse(visibleData) {
                        onTitleChange(title)
                    }
                    let shouldContinue = shouldContinueStreaming(visibleData, terminal)
                    if !shouldContinue { break }
                }

                guard !Task.isCancelled else { return }
                guard shouldContinueConnection() else { return }
                if var lifecycleParser {
                    let remaining = lifecycleParser.finish()
                    if !remaining.isEmpty {
                        _ = shouldContinueStreaming(remaining, terminal)
                    }
                }

                var sessionExists: Bool?
                if lastLifecycleEvent == nil, let lifecycle = startup.tmuxLifecycle {
                    do {
                        let output = try await sshClient.execute(
                            lifecycle.presenceProbe.command,
                            timeout: .seconds(8)
                        )
                        sessionExists = lifecycle.presenceProbe.sessionExists(in: output)
                    } catch {
                        logger.warning(
                            "Unable to verify tmux session after shell exit: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                let endReason = TerminalShellEndReason.resolve(
                    tmuxLifecycle: startup.tmuxLifecycle,
                    markerEvent: lastLifecycleEvent,
                    sessionExists: sessionExists
                )
                logger.info("SSH shell ended: \(String(describing: endReason), privacy: .public)")
                onProcessExit(shell.id, endReason)
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard shouldContinueConnection() else { return }
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

        if let lastError, shouldContinueConnection() {
            onFailure(lastError, terminal)
        }
    }
}
