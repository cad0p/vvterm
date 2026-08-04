#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# teleport-totp.py — TOTP helpers for the VVTerm Teleport CI cluster
# (issue #83, milestone M2).
#
# Teleport's webapi provisions TOTP devices server-side and returns the
# shared secret ONLY as a QR image (otpauth://totp/<label>?secret=BASE32…).
# CI needs the secret to compute codes non-interactively, so this helper:
#
#   qr-secret <qr.png>   — decode the otpauth:// QR from Teleport's
#                          registerchallenge response, print the base32 secret
#   code <base32-secret> — print the current RFC 6238 TOTP code (SHA1, 6
#                          digits, 30s window — pquerna/otp defaults, the
#                          same library Teleport uses)
#
# QR decoding uses OpenCV's built-in QRCodeDetector
# (opencv-python-headless) — no system zbar dependency.

import base64
import hashlib
import hmac
import json
import struct
import sys
import time
import urllib.parse


def totp_code(secret_b32: str, window: int = 30) -> str:
    """RFC 6238 TOTP (SHA1, 6 digits, 30s window)."""
    padding = "=" * ((8 - len(secret_b32) % 8) % 8)
    key = base64.b32decode(secret_b32.upper() + padding)
    counter = int(time.time()) // window
    msg = struct.pack(">Q", counter)
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


def _decode_qr(png_bytes: bytes, origin: str) -> str:
    try:
        import cv2
    except ImportError:
        raise SystemExit(
            "error: opencv-python-headless is required for QR decoding "
            "(pip3 install opencv-python-headless)"
        )
    import numpy as np
    img = cv2.imdecode(np.frombuffer(png_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit(f"error: cannot decode QR image {origin}")
    data, _, _ = cv2.QRCodeDetector().detectAndDecode(img)
    if not data:
        raise SystemExit(f"error: no QR code detected in {origin}")
    parsed = urllib.parse.urlparse(data)
    if parsed.scheme != "otpauth":
        raise SystemExit(f"error: unexpected QR content scheme {parsed.scheme!r}: {data[:120]!r}")
    params = urllib.parse.parse_qs(parsed.query)
    secret = params.get("secret", [""])[0]
    if not secret:
        raise SystemExit(f"error: no secret= in otpauth URI: {data[:120]!r}")
    return secret


def qr_secret(path: str) -> str:
    """Extract the base32 TOTP secret from a registerchallenge artifact.

    Teleport v16 returns JSON {"webauthn":null,"totp":{"qrCode":"<base64
    PNG>"}} — handle that envelope as well as a raw PNG for older versions.
    """
    raw = open(path, "rb").read()
    try:
        envelope = json.loads(raw)
        qr = envelope.get("totp", {}).get("qrCode")
        if qr:
            return _decode_qr(base64.b64decode(qr), path)
    except (ValueError, UnicodeDecodeError):
        pass  # not JSON — treat as raw image
    return _decode_qr(raw, path)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "qr-secret" and len(sys.argv) == 3:
        print(qr_secret(sys.argv[2]))
    elif cmd == "code" and len(sys.argv) == 3:
        print(totp_code(sys.argv[2]))
    else:
        print(__doc__)
        sys.exit(1)
