import Foundation
import Testing
@testable import VVTerm

struct RemoteEnvironmentTests {
    actor FakeExecutor {
        private var outputs: [Result<String, Error>]
        private var commands: [String] = []

        init(outputs: [Result<String, Error>]) {
            self.outputs = outputs
        }

        func run(command: String, timeout _: Duration?) throws -> String {
            commands.append(command)
            guard !outputs.isEmpty else {
                Issue.record("Unexpected extra command: \(command)")
                return ""
            }
            return try outputs.removeFirst().get()
        }

        func recordedCommands() -> [String] {
            commands
        }
    }

    @Test
    func windowsPlatformDetectionRecognizesCmdVerOutput() {
        let output = "Microsoft Windows [Version 10.0.20348.2522]"
        #expect(RemotePlatform.detect(from: output) == .windows)
    }

    @Test
    func windowsPowerShellEnvironmentSupportsTmuxButNotMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell"),
            activeShellName: "powershell",
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsCmdEnvironmentSupportsTmuxButNotMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsDefaultShellParserPrefersPwshExecutable() {
        let output = #"""
        HKEY_LOCAL_MACHINE\SOFTWARE\OpenSSH
            DefaultShell    REG_SZ    C:\Program Files\PowerShell\7\pwsh.exe
        """#

        #expect(RemoteEnvironmentResolver.powerShellExecutableName(inWindowsShellOutput: output) == "pwsh")
    }

    @Test
    func windowsPowerShellExecutableCandidatesPreferActiveShell() {
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: "pwsh.exe") == ["pwsh", "powershell"])
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: "powershell.exe") == ["powershell", "pwsh"])
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: nil) == ["powershell", "pwsh"])
    }

    @Test
    func posixEnvironmentSupportsTmuxAndMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "zsh"),
            activeShellName: "zsh",
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == true)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func posixEnvironmentProbeRunsInNonLoginShell() {
        let command = RemoteEnvironmentResolver.posixEnvironmentProbeCommand()

        // Login hooks must not fire inside the connect-time environment probe.
        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.contains("sh -lc"))
        #expect(!command.contains("/bin/sh -lc"))
        // The body still exports PATH and reports platform + shell markers.
        #expect(command.contains("export PATH="))
        #expect(command.contains("__VVTERM_PLATFORM__="))
        #expect(command.contains("__VVTERM_SHELL__="))
    }

    @Test
    func posixEnvironmentUsesOneCombinedProbe() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_PLATFORM__=Linux\n__VVTERM_SHELL__=zsh")
        ])

        let environment = await RemoteEnvironmentResolver.resolve { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }

        #expect(environment.platform == .linux)
        #expect(environment.shellProfile.family == .posix)
        #expect(environment.activeShellName == "zsh")
        #expect(await executor.recordedCommands().count == 1)
    }

    @Test
    func nushellProfileStillCountsAsPOSIXRuntime() {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "nu"),
            activeShellName: "nu",
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == true)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsUnknownShellDisablesTmuxRuntimeEvenWithPowerShellAvailable() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == false)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == false)
    }

    @Test
    func windowsUnknownShellWithoutPowerShellDisablesTmuxRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == false)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == false)
    }

    // MARK: - Cached-environment hop split (#276/D2a)
    //
    // The `remoteEnvironment()` reuse decision is split at the
    // `isInnerSessionReady` actor hop: a pre-hop predicate (no `innerReady`
    // input possible) and the post-hop composite kept verbatim. These tests
    // pin the split's truth table so the Teleport `.unknown` re-resolve rule
    // cannot be silently lost by the fast path.
    //
    // Counterfactual: the two predicates are new API, so reverting the
    // production change fails this target to compile rather than failing
    // behaviourally; the pre-fix `remoteEnvironment()` composite is exactly
    // the post-hop predicate, which the matrix pins.

    private func environment(platform: RemotePlatform) -> RemoteEnvironment {
        RemoteEnvironment(
            platform: platform,
            shellProfile: .posix(shellName: "zsh"),
            activeShellName: "zsh",
            powerShellExecutable: nil
        )
    }

    @Test
    func cachedEnvironmentPreHopReuseMatrix() {
        let known = environment(platform: .linux)
        let unknown = environment(platform: .unknown)

        // Cold cache never reuses, for either auth method and either force
        // value.
        for authMethod in [AuthMethod.password, .sshKey, .sshKeyWithPassphrase, .faceIDTeleport] {
            for forceRefresh in [false, true] {
                #expect(
                    !SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                        forceRefresh: forceRefresh,
                        cached: nil,
                        authMethod: authMethod
                    )
                )
            }
        }

        // Non-Teleport: any cached platform is reusable pre-hop.
        #expect(
            SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                forceRefresh: false,
                cached: known,
                authMethod: .password
            )
        )
        #expect(
            SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                forceRefresh: false,
                cached: unknown,
                authMethod: .password
            )
        )

        // Teleport + known platform: reusable pre-hop.
        #expect(
            SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                forceRefresh: false,
                cached: known,
                authMethod: .faceIDTeleport
            )
        )

        // Teleport + `.unknown`: always hops (the re-resolve rule).
        #expect(
            !SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                forceRefresh: false,
                cached: unknown,
                authMethod: .faceIDTeleport
            )
        )

        // forceRefresh discards any cache pre-hop.
        for authMethod in [AuthMethod.password, .faceIDTeleport] {
            for cached in [known, unknown] {
                #expect(
                    !SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                        forceRefresh: true,
                        cached: cached,
                        authMethod: authMethod
                    )
                )
            }
        }
    }

    @Test
    func cachedEnvironmentPostHopReuseMatrix() {
        let known = environment(platform: .linux)
        let unknown = environment(platform: .unknown)

        // Non-Teleport: reusable regardless of inner readiness.
        for innerReady in [true, false] {
            #expect(
                SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                    forceRefresh: false,
                    cached: known,
                    authMethod: .password,
                    innerReady: innerReady
                )
            )
        }

        // Teleport + known platform: reusable regardless of inner readiness.
        for innerReady in [true, false] {
            #expect(
                SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                    forceRefresh: false,
                    cached: known,
                    authMethod: .faceIDTeleport,
                    innerReady: innerReady
                )
            )
        }

        // Teleport + `.unknown` + inner ready: re-resolve (cache is a miss).
        #expect(
            !SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                forceRefresh: false,
                cached: unknown,
                authMethod: .faceIDTeleport,
                innerReady: true
            )
        )

        // Teleport + `.unknown` + inner NOT ready: still returns the cache
        // after the hop (no prepare side effect on this path).
        #expect(
            SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                forceRefresh: false,
                cached: unknown,
                authMethod: .faceIDTeleport,
                innerReady: false
            )
        )

        // Cold cache and forceRefresh never reuse post-hop either.
        for authMethod in [AuthMethod.password, .faceIDTeleport] {
            for forceRefresh in [false, true] {
                #expect(
                    !SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                        forceRefresh: forceRefresh,
                        cached: nil,
                        authMethod: authMethod,
                        innerReady: true
                    )
                )
            }
            for cached in [known, unknown] {
                #expect(
                    !SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                        forceRefresh: true,
                        cached: cached,
                        authMethod: authMethod,
                        innerReady: true
                    )
                )
            }
        }
    }

    /// The pre-hop fast path must never discard a reuse the pre-fix composite
    /// would have granted: pre-hop true implies post-hop true (for any
    /// `innerReady`). The only deliberate delta is that pre-hop-true rows now
    /// skip the actor hop.
    @Test
    func preHopReuseImpliesPostHopReuse() {
        let caches: [RemoteEnvironment?] = [nil, environment(platform: .linux), environment(platform: .unknown)]
        for cached in caches {
            for authMethod in [AuthMethod.password, .sshKey, .faceIDTeleport] {
                for forceRefresh in [false, true] {
                    let preHop = SSHClient.canReuseCachedEnvironmentBeforeInnerCheck(
                        forceRefresh: forceRefresh,
                        cached: cached,
                        authMethod: authMethod
                    )
                    guard preHop else { continue }
                    for innerReady in [true, false] {
                        #expect(
                            SSHClient.canReuseCachedEnvironmentAfterInnerCheck(
                                forceRefresh: forceRefresh,
                                cached: cached,
                                authMethod: authMethod,
                                innerReady: innerReady
                            ),
                            "pre-hop reuse must imply post-hop reuse (auth: \(authMethod), force: \(forceRefresh))"
                        )
                    }
                }
            }
        }
    }
}
