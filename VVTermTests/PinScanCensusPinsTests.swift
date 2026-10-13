// SPDX-License-Identifier: MIT
//  PinScanCensusPinsTests.swift
//
//  The #450 census pin: every migrated helper lives in
//  `VVTermTests/PinScanSupport.swift`, the cohort still routes through
//  `PinScan.`, and the counterfactual hook is centralized. See
//  `PinScanCensus.swift` for the scan and its honest defeat list.
//
//  A failure message names the file:line and the exact remedy. Allowlisted
//  exceptions are non-empty by design (`SSHProbeShellPinsTests.strippingComments`
//  is the hash/interpolation-aware scanner that must stay local).

import Foundation
import Testing

struct PinScanCensusPinsTests {
    @Test
    func pinScanCensusIsPinned() throws {
        let root = try PinScan.repositoryRoot()
        let violations = try PinScanCensus.violations(repositoryRoot: root)
        #expect(
            violations.isEmpty,
            "the #450 pin-scan census found local copies or a stray hook use:\n\(violations.joined(separator: "\n"))"
        )
    }

    /// Change-detector: the cohort list is a deliberate record of the migrated
    /// files, so editing it must update the recorded count and digest in the
    /// same commit. Without this, dropping a cohort entry would pass silently.
    @Test
    func pinScanCohortListIsRecorded() {
        #expect(
            PinScanCensus.expectedCohort.count == PinScanCensus.expectedCohortCount,
            "the #450 census cohort changed size (\(PinScanCensus.expectedCohort.count) != \(PinScanCensus.expectedCohortCount)); update expectedCohortCount and expectedCohortDigest deliberately"
        )
        #expect(
            PinScanCensus.cohortDigest() == PinScanCensus.expectedCohortDigest,
            "the #450 census cohort list changed (digest \(PinScanCensus.cohortDigest()) != \(PinScanCensus.expectedCohortDigest)); update expectedCohortDigest deliberately"
        )
    }
}
