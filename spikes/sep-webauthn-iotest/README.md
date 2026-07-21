# SEP-WebAuthn IoTest (session 1.6a simulator smoke test)

Minimal iOS app + GitHub Actions simulator workflow that de-risks the
**scaffolding** of the 1.6a WKWebView-WebAuthn bootstrap question in CI,
**without a real device**.

Companion to `spikes/sep-webauthn/` (session 1.5 wire-format spike). This
spike does **not** reproduce the WebAuthn ceremony end-to-end — that
requires a real iPhone with Face ID and an iCloud-Keychain passkey for
`teleport.pcad.it`. What it does prove is everything *around* the ceremony
that would otherwise waste a device session:

- the iOS app target builds for `iOS Simulator`
- `WKWebView` loads `https://teleport.pcad.it/web/login`
- `window.PublicKeyCredential` is exposed in the webview JS context
- `isUserVerifyingPlatformAuthenticatorSupported()` returns a value we can log
- JS injection (`evaluateJavaScript`) round-trips a value back to Swift
- the app does not crash on load

If the simulator smoke test passes, the device session only needs to confirm
the ceremony itself (Face ID prompt → login → privilege token → extraction).
If it fails, we catch the scaffolding bugs in CI, not on-device.

## What this does NOT prove

| Question | Simulator? | Why |
|---|---|---|
| Face ID prompt appears on WebAuthn ceremony | ❌ | `simctl biometric match` doesn't integrate with WKWebView's WebAuthn stack |
| Passwordless login completes against teleport.pcad.it | ❌ | needs the real platform authenticator |
| Privilege-token re-auth works | ❌ | needs the real ceremony |
| SEP-key creation with `.biometryAny` (1.6b) | ❌ | simulator does not emulate the Secure Enclave; `kSecAttrTokenIDSecureEnclave` fails |

These remain device-only — see the session 1.6 results doc.

## Structure

```
spikes/sep-webauthn-iotest/
├── iotest.xcodeproj/         ← Xcode project (iOS app target)
├── iotest/
│   ├── App/
│   │   └── iotestApp.swift    ← app entry point
│   ├── WebAuthnProbe/
│   │   ├── ProbeView.swift    ← SwiftUI: WKWebView + log panel
│   │   └── WebAuthnProbe.swift← WKWebView wrapper + JS probe
│   └── Resources/
│       └── Info.plist
├── scripts/
│   └── simulator-smoke.sh     ← CI driver: boot sim, install, run, capture log
├── .github/workflows/
│   └── sep-webauthn-iotest-simulator.yml
└── README.md                  ← you are here
```

## The JS probe

The webview injects a small JS snippet on page load that:

1. Checks `window.PublicKeyCredential` exists.
2. Calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`
   and returns the boolean.
3. Calls `PublicKeyCredential.getClientCapabilities()` if available (iOS 26+)
   and returns the object.
4. Returns the bundle as a JSON string to Swift via the completion handler.

Swift logs the result to the on-screen log panel AND to `os_log` (captured
by `simctl spawn` / the simulator's unified log). The CI workflow greps the
log for the expected markers and fails if any are missing.

## Running locally

```bash
cd spikes/sep-webauthn-iotest
xcodebuild -project iotest.xcodeproj -scheme iotest \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Open the simulator, install the app, launch it. The log panel shows the
probe results.

## Running in CI

```bash
gh workflow run sep-webauthn-iotest-simulator.yml
```

The workflow boots a simulator, builds + installs + launches the app, captures
the log, and greps for the expected markers.

## Out of scope

- The WebAuthn ceremony itself — device-only.
- 1.6b (SEP biometry) — simulator can't emulate the Secure Enclave.
- The production port — session 2.2.
- Teleport invite tokens — not needed (the app loads the login page but does
  not attempt to log in; it only probes the JS surface).

## Refs

- Session 1.6 prompt: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-prompt.md`
- Session 1.6 results: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-results.md`
- Session 1.5 spike (wire format proven): `spikes/sep-webauthn/`
- Apple docs:
  - https://developer.apple.com/documentation/webkit/wkwebview
  - https://developer.apple.com/documentation/authenticationservices/supporting-passkeys
  - https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave
