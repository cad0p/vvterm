// SPDX-License-Identifier: MIT
//
//  GhosttyProcessEnvironmentTripwireTests.swift
//  VVTermTests
//
//  Source-level tripwires for issue #225. libghostty captures the process
//  environment by pointer inside `ghostty_init` (the Zig global
//  `std.os.environ` is a (pointer, count) slice into libc's `environ`), and a
//  later `setenv` that adds a variable replaces the environment table, leaving
//  that capture pointing at unowned memory that `getenv` then walks — the
//  intermittent NULL/garbage dereference in the config loader. `unsetenv`
//  after init is dead code today but a latent hazard for the same reason.
//  Two invariants keep the crash out:
//
//  1. Environment mutations live only in `Ghostty.App.ensureProcessEnvironment`,
//     which is called before `ghostty_init`.
//  2. The generated config is loaded by absolute path via
//     `ghostty_config_load_file`, never through `ghostty_config_load_default_files`
//     (which merges environment/XDG-resolved config directories).
//
//  These are FORMATTING HEURISTICS, NOT PROOFS — see the notes on each test.
//

import XCTest

final class GhosttyProcessEnvironmentTripwireTests: XCTestCase {

    /// Every `setenv(`/`unsetenv(` call in `Ghostty.App.swift` must live inside
    /// the `ensureProcessEnvironment` body, and that function must be invoked
    /// before `ghostty_init`.
    ///
    /// HEURISTIC, NOT A PROOF: it matches raw text, so it is defeated by a
    /// multi-line call, by an alias/wrapper (`let mutate = setenv`), by
    /// `Darwin.setenv(`, or by moving the mutation behind a helper in another
    /// file. The behavioural evidence is the crash-repro run in the PR, not
    /// this test.
    func testEnvironmentMutationsStayInsidePreInitBootstrap() throws {
        let source = try ghosttyAppSource()
        let lines = source.components(separatedBy: .newlines)

        let allowedRange = try functionBodyLineRange(
            named: "ensureProcessEnvironment",
            in: lines
        )
        let mutations = lines.enumerated().filter { _, line in
            line.contains("setenv(") || line.contains("unsetenv(")
        }
        let offenders = mutations
            .filter { !allowedRange.contains($0.offset) }
            .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        XCTAssertTrue(
            offenders.isEmpty,
            "environment mutation outside ensureProcessEnvironment (a post-init setenv that adds a variable replaces libghostty's environ snapshot, issue #225): \(offenders)"
        )

        // The body check above is only safe because the call precedes init.
        let callLine = try XCTUnwrap(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "ensureProcessEnvironment()" },
            "ensureProcessEnvironment() is never called"
        )
        let initLine = try XCTUnwrap(
            lines.firstIndex { $0.contains("ghostty_init(0, nil)") },
            "ghostty_init(0, nil) call site not found"
        )
        XCTAssertLessThan(
            callLine,
            initLine,
            "ensureProcessEnvironment() must run before ghostty_init so its mutations are part of the captured environment"
        )
    }

    /// The app must load its generated config by absolute path instead of the
    /// default-file loader, which resolves config directories through the
    /// environment (`XDG_CONFIG_HOME`) and the user's home.
    ///
    /// HEURISTIC, NOT A PROOF: it pins the call spelling, not the linker
    /// symbol; a differently spelled call to the same function would slip past.
    func testGeneratedConfigIsLoadedByAbsolutePath() throws {
        let source = try ghosttyAppSource()

        XCTAssertFalse(
            source.contains("ghostty_config_load_default_files"),
            "ghostty_config_load_default_files consults the environment; load the generated config with ghostty_config_load_file (issue #225)"
        )
        XCTAssertTrue(
            source.contains("ghostty_config_load_file(config, configFilePath)"),
            "the generated config must be loaded by absolute path via ghostty_config_load_file(config, configFilePath)"
        )
    }

    // MARK: - Helpers

    private func ghosttyAppSource() throws -> String {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("VVTerm/GhosttyTerminal/Ghostty.App.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// The repository root, derived from this file's location
    /// (`VVTermTests/GhosttyProcessEnvironmentTripwireTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhosttyProcessEnvironmentTripwireTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }

    /// The line range of a function body, located by naive brace counting from
    /// its declaration. Good enough for the plain, non-nested declarations in
    /// `Ghostty.App.swift`.
    private func functionBodyLineRange(
        named functionName: String,
        in lines: [String]
    ) throws -> ClosedRange<Int> {
        let start = try XCTUnwrap(
            lines.firstIndex { $0.contains("func \(functionName)(") },
            "could not find func \(functionName)() in the source"
        )

        var depth = 0
        var end: Int?
        for index in start..<lines.count {
            let line = lines[index]
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if depth == 0 {
                end = index
                break
            }
        }

        let endIndex = try XCTUnwrap(end, "could not find the end of func \(functionName)()")
        return start...endIndex
    }
}
