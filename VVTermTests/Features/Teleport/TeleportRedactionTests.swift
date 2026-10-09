// SPDX-License-Identifier: MIT
//
//  TeleportRedactionTests.swift
//  VVTermTests
//
//  Host-side source scan for public log interpolations in the remaining host
//  Teleport sources. The package owns the behavioural redaction suite
//  (`TeleportPackageTests`); the kept case here walks the two host roots that
//  still log (`VVTerm/Features/Teleport`, `VVTerm/Core/Teleport`) and fails
//  on an FQDN-ish expression interpolated with `privacy: .public`.
//
//  Split from the package-covered suite in the swift-teleport cutover: the
//  ceremony/coordinator log assertions now live in the package, and this file
//  keeps only the host-source scan (which the package cannot perform).
//

#if DEBUG
import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class TeleportRedactionTests: XCTestCase {

    /// The repository root, derived from this file's location.
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportRedactionTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    /// Every line in `relativeDirectory` (recursively, `.swift` files only)
    /// that contains at least one of `needles`, each prefixed with its
    /// repo-relative path so a failure names the exact site. Walking the tree
    /// — rather than a fixed file list — means a newly added log site inside
    /// it trips the caller's count assertion instead of passing unnoticed.
    /// Every line of every Swift file under `relativeDirectory` when
    /// `needles` is empty (no marker filter); otherwise only the lines
    /// containing at least one needle. The unfiltered form is for class-level
    /// scans that must not be hidden by an unlisted label spelling.
    private func sourceLines(
        under relativeDirectory: String,
        matching needles: [String]
    ) throws -> [String] {
        let root = repositoryRoot().appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var matches: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            matches.append(
                contentsOf: source
                    .components(separatedBy: "\n")
                    .filter { line in needles.isEmpty || needles.contains(where: { line.contains($0) }) }
                    .map { "\(relativePath): \($0)" }
            )
        }
        return matches.sorted()
    }

    // MARK: - Host-root FQDN scan

    /// No `\(expression, privacy: .public)` interpolation whose expression
    /// carries a host-ish token may remain in the host Teleport sources.
    /// Class-level, not method-level: values that identify a host, a node
    /// name, an RP ID or a protocol string must stay `.private` (the default)
    /// or be hashed.
    ///
    /// What the scan is not allowed to miss (the class of leak #236 fixed):
    /// a `\(host, privacy: .public)` added to any of these files — including
    /// values the linter has no type information for. It is a lexical pin
    /// on the source, not a runtime log read.
    ///
    /// Structural exclusions (checked before the token scan):
    ///   - `Self.…` constants (the ALPN/protocol strings) are public by
    ///     design and carry no identity;
    ///   - the literal `teleport-proxy-ssh` protocol string, not a host;
    ///   - counts (`.count`) and UUID renderings (`.uuidString`) — opaque.
    ///
    /// Reach limit, stated honestly: a value logged under a name carrying no
    /// FQDN-ish token (`\(destination, privacy: .public)`) escapes this scan
    /// exactly as it escapes the pins; the token list is the scan's reach.
    func testNoFQDNTokenExpressionIsLoggedPublicly() throws {
        let tokenPattern = try NSRegularExpression(
            pattern: #"(?i)(host|nodename|rpid|alpn|clustername|fqdn|proxyhost|servername)"#
        )
        let interpolation = try NSRegularExpression(
            pattern: #"\(([^()]*),\s*privacy:\s*\.public\)"#
        )
        // Every line of both roots — deliberately NOT marker-filtered: an
        // unlisted label spelling must not hide the line from this scan.
        let lines = try sourceLines(under: "VVTerm/Features/Teleport", matching: [])
            + sourceLines(under: "VVTerm/Core/Teleport", matching: [])

        var offenders: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in interpolation.matches(in: line, range: range) {
                guard let expressionRange = Range(match.range(at: 1), in: line) else { continue }
                let expression = String(line[expressionRange]).trimmingCharacters(in: .whitespaces)
                // Structural exclusions, checked before the token scan so a
                // constant or an opaque identifier cannot be mistaken for a
                // host by a name coincidence.
                guard !expression.hasPrefix("Self."),
                      !expression.hasSuffix(".count"),
                      !expression.hasSuffix(".uuidString")
                else { continue }
                let expressionRangeInExpression = NSRange(
                    expression.startIndex..<expression.endIndex,
                    in: expression
                )
                if tokenPattern.firstMatch(in: expression, range: expressionRangeInExpression) != nil {
                    offenders.append(line)
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "an FQDN-ish expression is logged `privacy: .public`: \(offenders)"
        )
    }
}

#endif
