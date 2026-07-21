// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// SEP-WebAuthn spike — standalone Swift package.
//
// Ports the load-bearing parts of Teleport's lib/auth/touchid/api.go to Swift
// behind a `WebAuthnSigner` protocol, with two implementations:
//   - SoftwareSigner        (Part A — CryptoKit P256, no SEP, no biometry)
//   - SecureEnclaveSigner   (Part B — SecKey* + kSecAttrTokenIDSecureEnclave)
//
// The package builds a `sep-spike-cli` driver used by the
// `sep-webauthn-spike.yml` GitHub Actions workflow against `teleport.pcad.it`.
//
// See README.md and the parent session prompt for context:
//   2026-07-20-strategy-b-session1.5-sep-key-spike-prompt.md

import PackageDescription

let package = Package(
    name: "SEPWebAuthn",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SEPWebAuthn", targets: ["SEPWebAuthn"]),
        .executable(name: "sep-spike-cli", targets: ["sep-spike-cli"]),
    ],
    targets: [
        .target(
            name: "SEPWebAuthn",
            path: "Sources/SEPWebAuthn"
        ),
        .testTarget(
            name: "SEPWebAuthnTests",
            dependencies: ["SEPWebAuthn"],
            path: "Tests/SEPWebAuthnTests"
        ),
        .executableTarget(
            name: "sep-spike-cli",
            dependencies: ["SEPWebAuthn"],
            path: "Sources/sep-spike-cli"
        ),
    ]
)
