# SEP-WebAuthn spike

Standalone Swift package + CLI + GitHub Actions workflow that proves a
Secure-Enclave-backed EC-P256 key can register as a Teleport passwordless MFA
device and log in via `/webapi/mfa/login/begin`+`/finish`. Runs entirely on a
GitHub Actions `macos-14` runner — **no local Mac or iOS device required**.

If this passes, Option 5 in
[`2026-07-20-sep-key-bootstrap-not-asauthorization.md`](../../../../personal/github/cad0p/Goldmine/open-source/github/vvterm/decisions/2026-07-20-sep-key-bootstrap-not-asauthorization.md)
is technically de-risked and the implementation session (1.6) can proceed.

## What this proves

The spike has three parts; only A and B run in CI:

| Part | Signer              | SEP? | Biometry? | CI? | What it proves |
|------|---------------------|------|-----------|-----|----------------|
| A    | `SoftwareSigner`    | No   | No        | Yes | Wire format accepted by Teleport (CBOR `packed` self-attestation, `clientDataJSON`, COSE EC2 key, assertion object). |
| B    | `SecureEnclaveSigner` | Yes | No        | Yes | The `SecKey*` + `kSecAttrTokenIDSecureEnclave` API call shapes compile, run, and produce accepted attestations on the same hardware (M1) the iOS app will ship on. |
| C    | `SecureEnclaveSigner` + `.biometryAny` | Yes | Yes | No  | Face ID gating works on a real iPhone. **Implementation-time smoke test, not this session.** See session 1.6. |

The load-bearing question is **wire-format acceptance**, which is CI-able
because the SEP's ES256 signature is byte-identical in format to a software
P-256 signature — the SEP only adds non-exportability and Face ID gating,
neither of which Teleport sees.

## Structure

```
spikes/sep-webauthn/
├── Package.swift
├── README.md                      ← you are here
├── Sources/
│   ├── SEPWebAuthn/               ← the ported library
│   │   ├── Signer.swift           ← WebAuthnSigner protocol
│   │   ├── SoftwareSigner.swift   ← Part A — CryptoKit P256
│   │   ├── SecureEnclaveSigner.swift ← Part B — SecKey* + SEP
│   │   ├── Attestation.swift      ← makeAttestationData + collectedClientData
│   │   ├── CBOR.swift             ← minimal canonical CTAP2 CBOR encoder
│   │   └── WebAuthn.swift         ← register() + login() builders
│   └── sep-spike-cli/
│       └── main.swift             ← CLI driver (7-step end-to-end test)
├── Tests/
│   └── SEPWebAuthnTests/
│       └── FixtureTests.swift     ← byte-comparison vs Go output
└── fixtures/
    ├── generate/main.go           ← Go fixture generator (uses Teleport's api.go)
    ├── regenerate.sh              ← regenerates fixtures/expected/*.bin
    └── expected/                 ← committed byte-exact reference outputs
```

The companion workflow is at
[`.github/workflows/sep-webauthn-spike.yml`](../../.github/workflows/sep-webauthn-spike.yml).

## Running locally (macOS only)

```bash
cd spikes/sep-webauthn
swift build
swift test                                 # fixture byte-comparison
.build/debug/sep-spike-cli --help
.build/debug/sep-spike-cli \
  --token <invite-token> \
  --host teleport.pcad.it \
  --signer software
```

The fixture tests require the Go fixtures to be present. Regenerate them with:

```bash
cd spikes/sep-webauthn
TELEPORT_SRC=/path/to/teleport ./fixtures/regenerate.sh
```

(`TELEPORT_SRC` defaults to `~/open-source/github/cad0p/teleport`, pinned
`v18.9.1`.)

## Running in CI

The workflow is `workflow_dispatch` only (no PR triggers — it spends an invite
token). Mint one on a bastion with `tctl` access:

```bash
# As teleport-admin, on a bastion:
tctl users add pier-vvterm-test
# → outputs a token like "user:pier-vvterm-test:xxxx"
```

Add the token as a GitHub Actions secret named `INVITE_TOKEN` in `cad0p/vvterm`,
then dispatch the workflow:

```
gh workflow run sep-webauthn-spike.yml \
  -f proxy_host=teleport.pcad.it \
  -f run_part=both \
  -f ttl=3600
```

The token is single-use and short-lived (~1h); mint a fresh one per run. After
the spike passes, clean up:

```bash
tctl users rm pier-vvterm-test
```

## What each step proves

The CLI runs 7 steps against `https://<host>`. If step 7 returns a cert, the
wire format is proven:

1. `POST /webapi/mfa/token/:token/registerchallenge` — gets a
   `CredentialCreation` challenge (pure HTTP, no webview).
2. `WebAuthn.register(...)` — builds the `packed` self-attestation
   (`authenticatorData` + `clientDataJSON` + COSE EC2 pubkey + signature).
3. `POST /webapi/mfa/devices` — registers the device.
4. `POST /webapi/mfa/login/begin` `{"passwordless": true}` — gets a
   `CredentialAssertion` challenge.
5. `WebAuthn.login(...)` — builds the assertion.
6. `ssh-keygen -t ed25519` — generates an SSH keypair (the cert subject).
7. `POST /webapi/mfa/login/finish` — sends the assertion + SSH pub key + TTL.
   **Returns a cert if the wire format is accepted.**

## Reference: Teleport source (pinned `v18.9.1`)

The port is based on these files:

| Go file / function | Swift target | Go lines |
|---|---|---|
| `lib/auth/touchid/api.go` `Register` (`:228`) | `WebAuthn.register(...)` | ~126 |
| `lib/auth/touchid/api.go` `Login` (`:444`) | `WebAuthn.login(...)` | ~89 |
| `lib/auth/touchid/api.go` `makeAttestationData` (`:387`) | `makeAttestationData(...)` | ~57 |
| `lib/auth/touchid/api.go` `collectedClientData` (`:379-385`) | `CollectedClientData` struct | ~8 |
| `lib/auth/touchid/api.go` `pickCredential` (`:533`) | inlined (single-cred, no picker UI) | ~20 |
| `lib/auth/touchid/register.m` (`:34-61`) | `SecureEnclaveSigner.createKey()` | (ObjC, ~30 lines) |
| `lib/darwin/pub_key.go` `ECDSAPublicKeyFromRaw` | `coseEC2PublicKeyCBOR(...)` (inline) | ~45 |
| `lib/web/apiserver.go:992,999,1001` | CLI steps 1, 3 (register endpoints) | — |
| `lib/web/apiserver.go:3112,3168` | CLI steps 4, 7 (login endpoints) | — |

## Key wire-format details (the subtle bits)

These are the load-bearing details that, if wrong, cause silent server
rejection. Each is reproduced byte-for-byte from the Go source:

- **`collectedClientData` has only 3 fields** (`type`, `challenge`, `origin`).
  Teleport omits the W3C-mandated `crossOrigin`/`topOrigin` fields — see
  `api.go:379-385`. The Swift `CollectedClientData.toJSONBytes()` emits
  exactly `{"type":"...","challenge":"...","origin":"..."}` with no
  whitespace, matching Go's `encoding/json` output for the 3-field struct.
- **`challenge` is base64url without padding** (`base64.RawURLEncoding`).
  `URLEncodedBase64.MarshalJSON` in go-webauthn uses RawURLEncoding.
- **`authenticatorData` layout**: `rpIdHash(32) || flags(1) || signCount(4, BE, 0) || [attestedCredentialData]`.
  Flags for create = `0x01|0x04|0x40` (UP|UV|AT); for get = `0x01|0x04` (UP|UV).
- **AAGUID is 16 zero bytes** (not a real AAGUID — `api.go:428` writes `make([]byte, 16)`).
  This is why the SEP-key attestation looks identical to a `tsh mfa add --type TOUCHID` attestation.
- **COSE EC2 public key CBOR** uses integer keys: `{1:2, 3:-7, -1:1, -2:<x>, -3:<y>}`
  (`kty=EC2`, `alg=ES256`, `crv=P-256`). See `coseEC2PublicKeyCBOR` in
  `Attestation.swift`. The x and y coordinates MUST be exactly 32 bytes
  (zero-padded on the left if the high bytes are zero — `FillBytes` semantics).
- **`packed` attestation object CBOR** is a map with string keys:
  `{"fmt":"packed", "attStmt":{"alg":-7, "sig":<bytes>}, "authData":<bytes>}`.
  Canonical CTAP2 CBOR sorts keys by encoded-byte length first, then
  bytewise — so the wire order is `attStmt`, `authData`, `fmt` (7, 8, 3
  bytes). `CBOR.encodeMap` handles this.
- **Signature is DER-encoded ASN.1** (`SEQUENCE { r INTEGER, s INTEGER }`),
  not fixed-width 64-byte r||s. This is what `SecKeyCreateSignature` returns
  and what `api.go` sends. (go-webauthn's verifier accepts both.)
- **The digest is double-hashed.** `api.go:445` computes
  `digest = sha256(authData || sha256(clientDataJSON))` and passes `digest`
  to `native.Authenticate`, which calls
  `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256, digest, ...)`.
  The SEP's `.ecdsaSignatureMessageX962SHA256` algorithm **hashes the input
  again** internally — so the actual signed bytes are
  `sha256(authData || sha256(clientDataJSON))`, hashed twice. The Swift port
  reproduces this exactly (see `SecureEnclaveSigner.sign` for the note).
- **`credentialID` is a string** (UUID in production, opaque string in the
  spike). `id` in the JSON response is the string itself; `rawId` is
  `[]byte(credentialID)` base64url-encoded. See `api_darwin.go:204` +
  `api.go:517-520`.

## Out of scope

- The WKWebView-WebAuthn question (session 1.6).
- The full VVTerm integration (session 1.6 rewrites `TeleportWebAuthn.swift`).
- Part C — Face ID gating on a real iPhone (implementation-time smoke test).
- Cert refresh-before-expiry UX (session 3).
- The SSH-connect transport blocker — TLS+ALPN + ProxyJump double-handshake
  (session 2's item 5 / session 3).

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Teleport rejects the `packed` self-attestation | Low | Mac `tsh mfa add --type TOUCHID` already produces one. If rejected, `tsh --debug` to capture a known-good attestation and byte-diff. |
| CBOR encoding mismatch (map key ordering / int encoding) | Medium | The Go fixture generator + `FixtureTests.swift` byte-comparison catches this before any server call. |
| `kSecAttrTokenIDSecureEnclave` behaves differently on macOS vs iOS | Very low | Same hardware, same API, same wire format. Part B is the check; if it fails, run `tsh mfa add --type TOUCHID` on the same runner (it uses the same API). |
| Invite token expired before the workflow runs | Medium | Mint fresh per run; the workflow prints the `tctl users add` command. |

## License

AGPL-3.0-or-later (matches Teleport, whose `lib/auth/touchid/api.go` is ported here).
