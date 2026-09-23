#!/usr/bin/env python3
"""Phase 0b Teleport seam-boundary check.

Verifies that the explicit package-movable Teleport file list contains no
host symbols/strings after the Phase 0b seam refactor. Run from the repo
root (CI: `python3 scripts/ci/teleport-seam-boundary.py`).

The movable list is the one pinned in the Phase 0b plan
(`Features/Teleport/Domain/*`, the named Application files, the named
Infrastructure files + SEPWebAuthn, and the relocated transports).
`SSHProxySubsystemTransport.swift` is deliberately NOT in the list: it is
the host-side libssh2 channel bridge, and `SessionMutex` is allowed there.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

DOMAIN = "VVTerm/Features/Teleport/Domain"
APPLICATION = "VVTerm/Features/Teleport/Application"
INFRASTRUCTURE = "VVTerm/Features/Teleport/Infrastructure"

# The explicit package-movable file set (see the plan's "Package-movable
# file set").
MOVABLE_FILES: list[str] = []

for name in sorted(
    p.name for p in (REPO_ROOT / DOMAIN).glob("*.swift")
):
    MOVABLE_FILES.append(f"{DOMAIN}/{name}")

for name in [
    "SSHCertExpiryParser.swift",
    "TeleportBootstrapCoordinator.swift",
    "TeleportInfrastructureProtocols.swift",
    "TeleportKeyRing.swift",
    "TeleportLoginCoordinator.swift",
    "TeleportRegistrationCoordinator.swift",
]:
    MOVABLE_FILES.append(f"{APPLICATION}/{name}")

for name in [
    "BrowserMFACeremony.swift",
    "BrowserMFAListener.swift",
    "GRPCClient.swift",
    "GRPCTransport.swift",
    "HeadlessID.swift",
    "HeadlessLogin.swift",
    "iotest_mfa.pb.swift",
    "MFALoginWireTypes.swift",
    "TeleportHTTPClient.swift",
    "TeleportTrustSession.swift",
    "TLSKeyPair.swift",
    "SSHTLSTransport.swift",
    "TeleportProxySubsystem.swift",
    "TeleportTLSTrust.swift",
]:
    MOVABLE_FILES.append(f"{INFRASTRUCTURE}/{name}")

for name in sorted(
    p.name for p in (REPO_ROOT / INFRASTRUCTURE / "SEPWebAuthn").glob("*.swift")
):
    MOVABLE_FILES.append(f"{INFRASTRUCTURE}/SEPWebAuthn/{name}")

# Host symbols/strings forbidden inside the movable set. `SessionMutex` is
# listed here too: it must stay in the host-side bridge file only.
FORBIDDEN = re.compile(
    r"SSHError"
    r"|KeychainError"
    r"|Logger\.forCategory"
    r"|UserDefaults\.standard"
    r"|UIApplication\.shared"
    r"|NSApp"
    r"|AuthMethod"
    r"|TeleportKeyRing\.shared"
    r"|app\.vivy\.vvterm"
    r"|\bSessionMutex\b"
)

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT = re.compile(r"//[^\n]*")


def strip_comments(source: str) -> str:
    without_blocks = BLOCK_COMMENT.sub("", source)
    return LINE_COMMENT.sub("", without_blocks)


def main() -> int:
    hits: list[str] = []
    checked = 0
    for relative in MOVABLE_FILES:
        path = REPO_ROOT / relative
        if not path.exists():
            hits.append(f"{relative}: file is missing")
            continue
        checked += 1
        text = strip_comments(path.read_text(encoding="utf-8"))
        for lineno, line in enumerate(text.splitlines(), start=1):
            if FORBIDDEN.search(line):
                hits.append(f"{relative}:{lineno}: {line.strip()}")

    if hits:
        print("Teleport seam-boundary check FAILED — host symbols in movable files:")
        for hit in hits:
            print(f"  {hit}")
        return 1

    print(
        f"Teleport seam-boundary check OK — {checked} movable files, "
        f"0 forbidden host-symbol hits "
        f"({FORBIDDEN.pattern})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
