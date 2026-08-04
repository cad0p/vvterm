#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# teleport-webauthn.py — software WebAuthn (FIDO2) signer for the VVTerm
# Teleport CI harness (scripts/ci/teleport-server.sh).
#
# M3: a `second_factor: webauthn` cluster cannot complete its invite,
# login, or headless-approval ceremonies without a WebAuthn authenticator.
# The simulator has no Secure Enclave and the browser is not automated in
# CI, so this script plays the authenticator role in software, mirroring
# how Teleport's own e2e tests seed credentials (bootstrap users with a
# pre-generated key, then sign real challenges with it — no fake server).
#
# It is a pure client-side implementation: it never verifies server
# responses beyond what the ceremony requires, and it produces the exact
# JSON shapes Teleport's webapi expects:
#
#   registration (webauthnCreationResponse):
#     {id, rawId, type: "public-key",
#      response: {clientDataJSON, attestationObject}}
#   assertion (webauthnAssertionResponse):
#     {id, rawId, type: "public-key",
#      response: {clientDataJSON, authenticatorData, signature, userHandle?}}
#
# Details matched to Teleport v16 (verified against branch/v16 source):
#   - attestation "none" (empty attStmt, AAGUID = 16 zero bytes) — accepted
#     by default (lib/auth/webauthn/config.go PreferNoAttestation; no
#     attestation_allowed_cas configured in CI)
#   - ECDSA P-256 / SHA-256 (alg -7), DER-encoded signature over
#     authenticatorData || SHA256(clientDataJSON)
#     (go-webauthn protocol/assertion.go)
#   - clientDataJSON origin host must equal the cluster's webauthn rp_id
#     (lib/auth/webauthn/origin.go validateOrigin); the HTTP Host is never
#     cross-checked, so rp_id 127.0.0.1 + origin https://127.0.0.1:8443
#     works (or rp_id localhost + origin https://localhost:8443)
#   - userVerification "discouraged" (MFA/headless) => UP flag only;
#     "required" (passwordless) => UP | UV
#
# State: the generated P-256 key + credential ID persist in STATE_DIR so a
# registered credential can sign later assertions (login, headless approve).
#
# Commands (one verb per invocation):
#   register --options <file> --out <file> [--origin <url>] [--state <dir>]
#       Parse Teleport's registerchallenge JSON (accepts the full envelope
#       {"webauthn":{"publicKey":{...}}} or the bare publicKey object),
#       create a fresh credential, write the webauthnCreationResponse JSON.
#   assert --options <file> --out <file> [--origin <url>] [--state <dir>]
#       Parse an assertion options JSON ({"webauthn_challenge":{"publicKey":
#       {...}}} or bare), sign with the stored credential, write the
#       webauthnAssertionResponse JSON.
#   headless-id --pubkey <file>
#       Compute the deterministic headless authentication ID for a pubkey
#       file (authorized_keys format, with or without trailing newline).
#       Port of Teleport's services.NewHeadlessAuthenticationID, matching
#       VVTerm/Features/Teleport/Infrastructure/HeadlessID.swift.
#
# Exit codes: 0 success, 1 error (usage, crypto, malformed options).
#
# Requires: python3 + `pip install fido2 cryptography` (pure Python).

import argparse
import base64
import hashlib
import json
import os
import sys
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from fido2 import cbor
from fido2.cose import ES256
from fido2.webauthn import (
    AttestationObject,
    AuthenticatorData,
    CollectedClientData,
)


# ---------------------------------------------------------------------------
# Base64 helpers
# ---------------------------------------------------------------------------

def b64u(data: bytes) -> str:
    """URL-safe base64 without padding (WebAuthn / URLEncodedBase64)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text: str) -> bytes:
    """Decode base64 tolerating both URL-safe and std alphabets + padding."""
    padded = text + "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(padded)


# ---------------------------------------------------------------------------
# Headless authentication ID (port of HeadlessID.swift / NewHeadlessAuthenticationID)
# ---------------------------------------------------------------------------

def headless_id(pubkey_bytes: bytes) -> str:
    """UUID v5 over SHA256(16 zero bytes || pubkey), RFC 9562 variant bits."""
    namespace = b"\x00" * 16
    digest = hashlib.sha256(namespace + pubkey_bytes).digest()
    b = bytearray(digest[:16])
    b[6] = (b[6] & 0x0F) | 0x50  # version 5
    b[8] = (b[8] & 0x3F) | 0x80  # RFC 9562 variant
    return str(uuid.UUID(bytes=bytes(b)))


# ---------------------------------------------------------------------------
# Software authenticator
# ---------------------------------------------------------------------------

class SoftCredential:
    """A resident P-256 credential backed by a software key."""

    def __init__(self, state_dir: str, private_key: ec.EllipticCurvePrivateKey,
                 credential_id: bytes):
        self.state_dir = state_dir
        self.private_key = private_key
        self.credential_id = credential_id

    @classmethod
    def create_new(cls, state_dir: str) -> "SoftCredential":
        key = ec.generate_private_key(ec.SECP256R1())
        cred_id = os.urandom(32)
        os.makedirs(state_dir, exist_ok=True)
        key_pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        with open(os.path.join(state_dir, "key.pem"), "wb") as f:
            f.write(key_pem)
        with open(os.path.join(state_dir, "credential-id.b64"), "w") as f:
            f.write(b64u(cred_id))
        return cls(state_dir, key, cred_id)

    @classmethod
    def load(cls, state_dir: str) -> "SoftCredential":
        with open(os.path.join(state_dir, "key.pem"), "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
        with open(os.path.join(state_dir, "credential-id.b64")) as f:
            cred_id = unb64u(f.read().strip())
        return cls(state_dir, key, cred_id)  # type: ignore[arg-type]

    def credential_public_key(self) -> bytes:
        """COSE_Key (CBOR) for the public key, as stored in authData."""
        return cbor.encode(dict(ES256.from_cryptography_key(self.private_key.public_key())))

    def attested_credential_data(self) -> bytes:
        """AAGUID (16 zero bytes) || credID len || credID || COSE pubkey."""
        cid = self.credential_id
        return b"\x00" * 16 + len(cid).to_bytes(2, "big") + cid + self.credential_public_key()


def _auth_data(rp_id: str, flags: int, counter: int,
               credential_data: bytes = b"") -> AuthenticatorData:
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    return AuthenticatorData.create(rp_id_hash, flags, counter, credential_data)


def registration_response(options: dict, cred: SoftCredential, origin: str) -> dict:
    """Build the webauthnCreationResponse for a registerchallenge.

    userVerification "required" (passwordless devices) => add the UV flag to
    authenticatorData; "discouraged"/absent (MFA devices) => UP|AT only.
    """
    challenge = unb64u(options["challenge"])
    rp_id = options["rp"]["id"]
    uv = ((options.get("authenticatorSelection") or {}).get("userVerification") or "").lower()
    flags = AuthenticatorData.FLAG.UP | AuthenticatorData.FLAG.ATTESTED
    if uv == "required":
        flags |= AuthenticatorData.FLAG.UV
    auth_data = _auth_data(rp_id, flags, 0, cred.attested_credential_data())
    att_obj = AttestationObject.create("none", auth_data, {})
    client_data = CollectedClientData.create(
        CollectedClientData.TYPE.CREATE, challenge, origin, cross_origin=True
    )
    return {
        "id": b64u(cred.credential_id),
        "rawId": b64u(cred.credential_id),
        "type": "public-key",
        "response": {
            "clientDataJSON": client_data.b64,
            "attestationObject": b64u(bytes(att_obj)),
        },
    }


def assertion_response(options: dict, cred: SoftCredential, origin: str,
                       user_handle: bytes | None = None) -> dict:
    """Build the webauthnAssertionResponse for an authenticate challenge.

    userVerification "required" (passwordless scope) => UP | UV flags;
    "discouraged"/absent (MFA, headless approval) => UP only, no userHandle.
    """
    challenge = unb64u(options["challenge"])
    rp_id = options["rpId"]
    uv = (options.get("userVerification") or "").lower()
    flags = AuthenticatorData.FLAG.UP | (AuthenticatorData.FLAG.UV if uv == "required" else 0)
    auth_data = _auth_data(rp_id, flags, 0)
    client_data = CollectedClientData.create(
        CollectedClientData.TYPE.GET, challenge, origin, cross_origin=True
    )
    signed = bytes(auth_data) + client_data.hash
    # ECDSA P-256 over SHA-256; cryptography's sign() returns DER, which is
    # what go-webauthn's webauthncose.VerifySignature expects.
    der = cred.private_key.sign(signed, ec.ECDSA(hashes.SHA256()))
    result = {
        "id": b64u(cred.credential_id),
        "rawId": b64u(cred.credential_id),
        "type": "public-key",
        "response": {
            "clientDataJSON": client_data.b64,
            "authenticatorData": b64u(bytes(auth_data)),
            "signature": b64u(der),
        },
    }
    if user_handle is not None:
        result["response"]["userHandle"] = b64u(user_handle)
    return result


# ---------------------------------------------------------------------------
# Options unwrapping: Teleport wraps creation options in
# {"webauthn": {"publicKey": {...}}} and assertion options in
# {"webauthn_challenge": {"publicKey": {...}}}; accept either envelope.
# ---------------------------------------------------------------------------

def unwrap_options(raw: dict) -> dict:
    if "publicKey" in raw:
        return raw["publicKey"]
    for key in ("webauthn", "webauthn_challenge"):
        if isinstance(raw.get(key), dict) and "publicKey" in raw[key]:
            return raw[key]["publicKey"]
    raise ValueError(f"unrecognized options envelope (keys: {sorted(raw.keys())})")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Software WebAuthn signer for Teleport CI")
    sub = parser.add_subparsers(dest="verb", required=True)

    p = sub.add_parser("register")
    p.add_argument("--options", required=True, help="registerchallenge JSON file")
    p.add_argument("--out", required=True, help="output webauthnCreationResponse JSON")
    p.add_argument("--origin", required=True, help="clientDataJSON origin, e.g. https://127.0.0.1:8443")
    p.add_argument("--state", default=None, help="state dir for key + credential id")

    p = sub.add_parser("assert")
    p.add_argument("--options", required=True, help="authenticate challenge JSON file")
    p.add_argument("--out", required=True, help="output webauthnAssertionResponse JSON")
    p.add_argument("--origin", required=True, help="clientDataJSON origin")
    p.add_argument("--state", default=None, help="state dir (loads stored credential)")
    p.add_argument("--user-handle", default=None,
                   help="b64url user handle; defaults to the state's persisted handle if present")
    p.add_argument("--no-user-handle", action="store_true",
                   help="force-omit userHandle (MFA/headless scopes)")

    p = sub.add_parser("headless-id")
    p.add_argument("--pubkey", required=True, help="SSH pubkey file (authorized_keys format)")

    args = parser.parse_args()

    if args.verb == "headless-id":
        with open(args.pubkey, "rb") as f:
            pub = f.read().strip() + b"\n"
        print(headless_id(pub))
        return 0

    state_dir = args.state or os.path.join(
        os.environ.get("WORK_DIR", "/tmp/vvterm-teleport"), "webauthn-state"
    )

    try:
        with open(args.options) as f:
            options = unwrap_options(json.load(f))
        if args.verb == "register":
            cred = SoftCredential.create_new(state_dir)
            response = registration_response(options, cred, args.origin)
            # Persist the user handle (registerchallenge user.id) — passwordless
            # assertions must echo it back (user_handle).
            user = options.get("user") or {}
            if user.get("id"):
                with open(os.path.join(state_dir, "user-handle.b64"), "w") as f:
                    f.write(user["id"])
        else:
            cred = SoftCredential.load(state_dir)
            handle: bytes | None = None
            if args.user_handle:
                handle = unb64u(args.user_handle)
            elif not args.no_user_handle:
                handle_path = os.path.join(state_dir, "user-handle.b64")
                if os.path.exists(handle_path):
                    with open(handle_path) as f:
                        handle = unb64u(f.read().strip())
            response = assertion_response(options, cred, args.origin, user_handle=handle)
        with open(args.out, "w") as f:
            json.dump(response, f)
        print(f"{args.verb}: wrote {args.out}")
        return 0
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"error: {args.verb} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
