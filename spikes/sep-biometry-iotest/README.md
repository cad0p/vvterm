# SEP biometry IoTest (session 1.6b Option A — iOS/Face ID)

Minimal iOS app that runs the **same SEP+biometry WebAuthn flow** as the Mac
CLI (`spikes/sep-webauthn/` with `--biometry`), but on an iPhone with Face ID.
Reuses the `SEPWebAuthn` library source files verbatim (added to the target
directly) so the wire format is byte-identical.

**Parent:** session 1.6b — Option B (Mac CLI + Touch ID) already PASSED
(2026-07-21, two Touch ID prompts observed). Option A is the production-target
confirmation on iOS/Face ID.

## What it proves

The same three 1.6b sub-questions, on iOS:

1. `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` + `.biometryAny`
   succeeds on iPhone.
2. `SecKeyCreateSignature` **blocks until Face ID** is presented.
3. Teleport accepts the attestation (register + login → cert).

Since the API is identical to macOS (Option B, passed), this is a production-
target confirmation, not a new investigation.

## Structure

```
spikes/sep-biometry-iotest/
├── sepbiometry.xcodeproj/        hand-written project, single iOS app target
├── sepbiometry/
│   ├── App/sepbiometryApp.swift  SwiftUI entry
│   ├── SEPBiometryTest/
│   │   ├── SEPBiometryTestRunner.swift  the 7-step flow (async, @MainActor)
│   │   └── SEPBiometryView.swift        SwiftUI: token input + steps + cert
│   └── Resources/Info.plist      NSFaceIDUsageDescription
└── README.md
```

The `SEPWebAuthn` library sources (`Attestation.swift`, `CBOR.swift`,
`SecureEnclaveSigner.swift`, `Signer.swift`, `SoftwareSigner.swift`,
`WebAuthn.swift`) are added to the target via a relative path group
(`../sep-webauthn/Sources/SEPWebAuthn`) so they're compiled directly into the
app — no separate Swift package, no dependency on the CLI. This keeps the
wire format provably identical to session 1.5 / 1.6b Option B.

## How to run (on your iPhone)

1. Mint a fresh invite token (single-use, ~1h TTL) — same as 1.5/1.6b:
   ```bash
   tsh ssh --user teleport-admin admin@pcad-it \
     'sudo tctl users rm pier-vvterm-test' 2>/dev/null
   tsh ssh --user teleport-admin admin@pcad-it \
     'sudo tctl users add pier-vvterm-test --roles=dev-access'
   # → capture the invite URL; the token is the last path segment
   ```
2. Open the project in Xcode, select your iPhone as the run destination,
   sign with your Apple ID (automatic signing), and run.
3. Paste the invite token into the app's text field.
4. Tap **Run register + login**.
5. Two Face ID prompts should appear (step 5 = login assertion, step 7 =
   cert request). Authenticate both.
6. The app shows each step's status + the returned cert (base64) on success.

## Out of scope

- The WKWebView-WebAuthn ceremony (1.6a) — separate app (`spikes/sep-webauthn-iotest/`).
- The production port — session 2.2.
- TestFlight distribution — for a one-off confirmation, direct Xcode install
  to your iPhone is simpler. (Can be added via the `ios-testflight.yml`
  pipeline if needed.)

## Refs

- 1.6 prompt: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-prompt.md`
- 1.6 results: `personal/github/cad0p/Goldmine/open-source/github/vvterm/2026-07-21-strategy-b-session1.6-device-de-risk-results.md`
- 1.6b Option B (PASSED): `spikes/sep-webauthn/` with `--biometry` flag (PR #18, merged)
- Wire format proven by session 1.5: `spikes/sep-webauthn/README.md`
