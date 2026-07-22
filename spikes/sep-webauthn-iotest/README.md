# SEP-WebAuthn IoTest (session 1.6a + 1.7 ceremony)

Minimal iOS app + GitHub Actions simulator workflow that de-risks the
**scaffolding** of the WKWebView-WebAuthn bootstrap question in CI,
**without a real device**, and (session 1.7) the **ceremony** itself on a
device.

Companion to `spikes/sep-webauthn/` (session 1.5 wire-format spike). The
simulator smoke test proves everything *around* the ceremony that would
otherwise waste a device session; the device run (session 1.7) proves the
ceremony end-to-end.

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

These remain device-only — see the session 1.7 results doc.

## Session 1.7 — the Ceremony screen

The app has two tabs:

- **Probe** (1.6a): the scaffolding probe — `PublicKeyCredential` exists,
  platform authenticator available, JS round-trip.
- **Ceremony** (1.7): the end-to-end ceremony — Face ID → passwordless
  login → privilege-token re-auth → token extraction. **Device-only.**

The Ceremony tab injects JS that calls the same Teleport web-API endpoints
the web UI calls:

1. `POST /v1/webapi/mfa/login/begin` `{"passwordless": true}` — gets a
   WebAuthn challenge.
2. `navigator.credentials.get({publicKey: ...})` — triggers the Face ID
   prompt (the webview's WebAuthn stack invokes the platform authenticator).
3. `POST /v1/webapi/mfa/login/finishsession` `{"webauthnAssertionResponse": ...}`
   — completes the login, sets the `__Host-session` cookie.
4. `POST /v1/webapi/mfa/authenticatechallenge` `{"challenge_scope":"ADMIN_ACTION"}`
   — gets a fresh challenge for the privilege-token re-auth.
5. `navigator.credentials.get(...)` — Face ID prompt #2.
6. `POST /v1/webapi/users/privilege/token` `{"existingMfaResponse":{"webauthn_response":...}}`
   — returns the privilege token string.

The privilege token is read from the fetch response in JS and surfaced to
Swift via `evaluateJavaScript` (the `__Host-session` cookie stays
`HttpOnly`, but the privilege token is a response body value).

### Associated Domains prerequisite (critical)

WKWebView requires the app to declare `webcredentials:<RP-ID>` as an
Associated Domain for the platform authenticator to invoke Face ID during
`navigator.credentials.get()`. Without it, `credentials.get()` throws
`NotAllowedError` and no Face ID prompt appears.

The entitlement is in `iotest/Resources/iotest.entitlements`:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>webcredentials:teleport.pcad.it?mode=developer</string>
</array>
```

The `?mode=developer` suffix allows testing with a developer-signed build
(direct Xcode install) before the AASA file is fully propagated. The AASA
file at `https://teleport.pcad.it/.well-known/apple-app-site-association`
must list this app's Team ID + bundle ID (`TEAMID.it.pcad.vvterm.iotest`)
under `webcredentials.apps` for the association to validate.

> **NOTE:** `teleport.pcad.it` currently returns 404 for the AASA file
> (verified 2026-07-22). This is a **prerequisite** for the ceremony to
> work — the AASA file must be hosted before the device run. See the
> session 1.7 results doc.

## Structure

```
spikes/sep-webauthn-iotest/
├── iotest.xcodeproj/         ← Xcode project (iOS app target)
├── iotest/
│   ├── App/
│   │   └── iotestApp.swift    ← app entry point (TabView: Probe + Ceremony)
│   ├── WebAuthnProbe/
│   │   ├── ProbeView.swift    ← SwiftUI: WKWebView + probe summary + log
│   │   └── WebAuthnProbe.swift← WKWebView wrapper + JS probe + ceremony syntax check
│   ├── Ceremony/
│   │   ├── CeremonyRunner.swift ← drives the 4-step ceremony (login + privilege)
│   │   ├── CeremonyJS.swift     ← the injected JS (loginJS + privilegeJS)
│   │   └── CeremonyView.swift   ← SwiftUI: checklist + log panel
│   └── Resources/
│       ├── Info.plist
│       └── iotest.entitlements ← Associated Domains (webcredentials:teleport.pcad.it)
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

## Running locally (simulator — scaffolding only)

```bash
cd spikes/sep-webauthn-iotest
xcodebuild -project iotest.xcodeproj -scheme iotest \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Open the simulator, install the app, launch it. The Probe tab shows the
probe results; the Ceremony tab will fail at the Face ID step (simulator
has no real platform authenticator) but the JS syntax check confirms the
ceremony scripts are valid.

## Running on a device (the ceremony — session 1.7)

**Prerequisite:** the AASA file must be hosted at
`https://teleport.pcad.it/.well-known/apple-app-site-association` listing
the app's Team ID + bundle ID under `webcredentials.apps`. Without it, the
Face ID prompt will not appear (`NotAllowedError`).

1. Open `spikes/sep-webauthn-iotest/iotest.xcodeproj` in Xcode.
2. Select your iPhone as the run destination.
3. Sign with your Apple ID (automatic signing). The Associated Domains
   entitlement requires a paid Apple Developer account.
4. Cmd+R to install + run.
5. Open the "Ceremony" tab, tap "Start ceremony".
6. Two Face ID prompts should appear (login + privilege token). The
   checklist updates as each step completes.

## Running in CI

```bash
gh workflow run sep-webauthn-iotest-simulator.yml
```

The workflow boots a simulator, builds + installs + launches the app, captures
the log, and greps for the expected markers (including the ceremony JS syntax
check).

## Out of scope

- The WebAuthn ceremony **on the simulator** — device-only (the Ceremony
  tab's JS is syntax-checked in CI, but the Face ID/login/privilege-token
  steps require a real device).
- 1.6b (SEP biometry) — simulator can't emulate the Secure Enclave.
- The production port — session 2.2.
- Teleport invite tokens — not needed (the ceremony uses the user's existing
  iCloud-Keychain passkey, not the invite-token path).
- Hosting the AASA file on `teleport.pcad.it` — that's a Teleport-side
  prerequisite, not part of this spike.

## Refs

- Session 1.7 prompt: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-22-strategy-b-session1.7-wkwebview-ceremony-prompt.md`
- Session 1.7 results: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-22-strategy-b-session1.7-wkwebview-ceremony-results.md`
- Session 1.6 prompt: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-prompt.md`
- Session 1.6 results: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-results.md`
- Session 1.5 spike (wire format proven): `spikes/sep-webauthn/`
- Apple docs:
  - https://developer.apple.com/documentation/webkit/wkwebview
  - https://developer.apple.com/documentation/authenticationservices/supporting-passkeys
  - https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave
  - https://developer.apple.com/documentation/xcode/supporting-associated-domains
