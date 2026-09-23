#!/usr/bin/env python3
"""Phase 0b Teleport seam-boundary check.

Verifies that the explicit package-movable Teleport file list contains no
host symbols/strings after the Phase 0b seam refactor. Run from the repo
root:

    python3 -B scripts/ci/teleport-seam-boundary.py
    python3 -B scripts/ci/teleport-seam-boundary.py --selftest

(`-B` keeps the run from writing `__pycache__/`; the repo also gitignores
it.)

The movable list is the one pinned in the Phase 0b plan
(`Features/Teleport/Domain/*`, the named Application files, the named
Infrastructure files + SEPWebAuthn, and the relocated transports).
`SSHProxySubsystemTransport.swift` is deliberately NOT in the list: it is
the host-side libssh2 channel bridge, and `SessionMutex` is allowed there.

Comment stripping is fail-closed: only full-line comments (`^\\s*//`,
`^\\s*\\*`) and block comments are removed. A trailing `//` after code is
NOT treated as a comment, so a `//` inside a string literal (e.g. an
`https://` URL) cannot hide a forbidden token on the same line.
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

for name in sorted(p.name for p in (REPO_ROOT / DOMAIN).glob("*.swift")):
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

for name in sorted(p.name for p in (REPO_ROOT / INFRASTRUCTURE / "SEPWebAuthn").glob("*.swift")):
    MOVABLE_FILES.append(f"{INFRASTRUCTURE}/SEPWebAuthn/{name}")

# Host symbols/strings forbidden inside the movable set. `SessionMutex` is
# listed here too: it must stay in the host-side bridge file only (the
# `\b` keeps `TeleportSessionMutex` — the movable protocol — allowed).
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
# Full-line `//` comments only (anchored at the line start after optional
# horizontal whitespace) — a trailing `//` after code may live inside a
# string literal and must not hide anything.
LINE_COMMENT = re.compile(r"^[ \t]*//[^\n]*", re.MULTILINE)
# `*` continuation lines (e.g. JSDoc style) outside a block comment.
DOC_LINE = re.compile(r"^[ \t]*\*[^\n]*", re.MULTILINE)


def strip_comments(source: str) -> str:
    without_blocks = BLOCK_COMMENT.sub("", source)
    without_line_comments = LINE_COMMENT.sub("", without_blocks)
    return DOC_LINE.sub("", without_line_comments)


def check_text(relative: str, source: str) -> list[str]:
    """Return the forbidden hits in one file's (comment-stripped) source."""
    text = strip_comments(source)
    hits: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if FORBIDDEN.search(line):
            hits.append(f"{relative}:{lineno}: {line.strip()}")
    return hits


def run_selftest() -> int:
    """Prove the checker catches planted tokens (and the stripper is safe)."""
    cases: list[tuple[str, bool]] = [
        ("let error = SSHError.connectionFailed(\"boom\")", True),
        # A `//` inside a string literal must not hide the token after it.
        ("let url = \"https://example.com\" // SSHError", True),
        ("let mutex = SessionMutex()", True),
        # Full-line + block comments are stripped.
        ("// SSHError in a full-line comment", False),
        ("/// Logger.forCategory in a doc comment", False),
        ("/* SSHError in a block comment */", False),
        ("/**\n * KeychainError in a doc block\n */", False),
        # The movable protocol is not the host `SessionMutex`.
        ("let mutex: any TeleportSessionMutex = factory()", False),
    ]
    failures: list[str] = []
    for source, should_match in cases:
        matched = bool(check_text("<selftest>", source))
        if matched != should_match:
            failures.append(
                f"  {source!r}: expected match={should_match}, got match={matched}"
            )
    if failures:
        print("Teleport seam-boundary selftest FAILED:")
        print("\n".join(failures))
        return 1
    print(f"Teleport seam-boundary selftest OK — {len(cases)} cases.")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return run_selftest()

    hits: list[str] = []
    checked = 0
    for relative in MOVABLE_FILES:
        path = REPO_ROOT / relative
        if not path.exists():
            hits.append(f"{relative}: file is missing")
            continue
        checked += 1
        hits.extend(check_text(relative, path.read_text(encoding="utf-8")))

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
    sys.exit(main(sys.argv[1:]))
