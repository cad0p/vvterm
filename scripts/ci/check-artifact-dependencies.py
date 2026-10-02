#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""check-artifact-dependencies.py — artifact-dependency gate (issue #316).

RULE
----
Every in-workflow artifact downloader must have a `needs:` path to the job
that uploads the artifact it downloads. Artifacts are run-scoped, so the
producer must be in the same workflow file; the only exclusion is a
recognized cross-run `run-id:` handoff (e.g. `${{ env.SOURCE_RUN_ID }}`)
carrying a `github-token:` that is provably non-empty (a literal, `secrets.*`
or `github.token`; a token that ECMAScript `trim()` empties, a statically
empty, or an unprovable expression token does not exclude).
actions/download-artifact ignores
`run-id:` when no token is set, so such a download is same-run and the rule
applies. A `run-id:` that the same file statically assigns the current run's
id is NOT a cross-run handoff either: it is same-run, so the rule still
applies.

THE RULE CLAIMS ORDERING, NOT EXISTENCE
---------------------------------------
A `needs:` path proves the producer job ran (or was skipped) before the
consumer starts; it cannot prove the artifact exists (an `if: failure()`
producer may be skipped, and a skipped intermediate with `always()` still
starts the dependent). The gate checks the declared graph, nothing more.

FAIL-CLOSED SUBSET PARSER
-------------------------
There is no YAML library guaranteed on the runner, so this is a small
YAML-subset engine. Its pass must mean something: anything it cannot fully
prove is a refusal naming `file:line`, never a pass. The anti-skip
mechanisms are:

  * a total-coverage, indentation-stack parser (no fixed columns): every
    non-blank line in the `jobs:` region is consumed by exactly one
    recognized construct, and a key's value (scalar, flow, nested mapping,
    block sequence, or block scalar) is consumed generically until dedent;
  * reconciliation: every artifact action reference in the blanked text —
    a `uses:` key line whose value carries an artifact token, or a line
    carrying the `-artifact@ref` action-ref shape — must be a parsed
    artifact step, so a step the parser failed to model can never pass; a
    bare token (a job id, a `needs:` item, an `if:` operand) is a label,
    not a step;
  * a scan floor so a typo'd `--root` cannot masquerade as a pass.

Refusals include: tabs in indentation; an unterminated quoted scalar; a
backslash escape in a double-quoted scalar that only YAML's full decoder
resolves (`\\uXXXX`, `\\xXX`, …), including behind a string tag or anchor
and inside an inline-flow item at a semantic position; a block-scalar header
as the value of a semantic key (step `uses`; job `needs`; `with.name`, `with.run-id`,
`with.pattern`, `with.artifact-ids`, `with.github-token`); a non-string YAML tag on a parsed mapping key or on a
value that decides the graph; a `github-token:` expression that cannot be
proven non-empty; `{`/`&`/`*`/`<<` in a
parsed position; duplicate mapping keys; duplicate `steps:`; duplicate
`with.name`; a `uses:` job that also has `steps:`; `pattern:`/`artifact-ids:`; a download without a
literal `name:`; duplicate literal artifact names; absent/empty `jobs:`; an
unrecognized `run-id:` expression; a same-job download that precedes its own
upload; and any unconsumed line.

Known limits, stated honestly: GitHub's own evaluation of duplicate keys
and action-ref casing is not verifiable from here, so the gate refuses
duplicates and case-folds action refs rather than guessing; a file with a
construct the subset grammar cannot model is refused, not skipped. A
`run-id: ${{ env.NAME }}` whose NAME is only ever written at runtime (e.g.
`echo "NAME=…" >> "$GITHUB_ENV"` from a `run:` step, the real
`ios-adhoc-pr.yml` shape) cannot be resolved statically and keeps the
cross-run exclusion — the #339 `$GITHUB_ENV` mention rule below is
deliberately token-chain-only, because the run-id value chain is the real
`workflow_run.id` handoff and this repository's own publish workflow depends
on it; static in-file `env:` assignments are resolved, and one
the gate cannot classify (including `needs.*.outputs.*`) is refused rather
than guessed. Static `env:` names are matched case-sensitively —
actions/runner's `env` context is `StringComparer.Ordinal` on non-Windows
runners — so a case-variant assignment is unset at runtime and does not
resolve; a YAML-empty value (an empty block-scalar body, or a plain `~` /
`null`) is the empty string, not the header text. Reconciliation
deliberately skips single-line `run:` bodies,
`env:` values, non-semantic `name:` scalars (job- and step-level), tokens
that sit in a mapping key, and bare identifiers (a job id, a `needs:` item,
an `if:` operand — they are data/labels, not steps), so an artifact-action
token there is not a refusal; a `uses:` key line or an action-ref shape the
parser did not model (e.g. a nested `uses:` lookalike) still is.
Multi-document streams, U+2028/U+2029 line breaks, `%YAML` directives and a
mid-file BOM are outside the subset grammar and unverified against GitHub's
parser. YAML tag policy is split by position: on a semantic key's value
(`uses`, `needs`, `with.name`/`run-id`/`github-token`/`pattern`/
`artifact-ids`) any tag other than the string tag is refused, because its
resolution could change the graph; the string tag (`!!str` /
`!<tag:yaml.org,2002:str>`) is resolved to the same scalar text
actions/runner reads. On a static `env:` value the tag's argument is
resolved to the value GitHub reads, so a non-semantic `RETRIES: !!int 3`
stays legal and an empty resolved value (`!!int ""`, bare `!!int`) does not
exclude the download. A non-string-tagged value whose plain scalar continues
on a following more-indented line is resolved through that continuation:
`GH_TOKEN: !!int` / `!foo` plus a more-indented `ghp_x` is non-empty at
runtime and stays excluded, while a continuation that is empty at runtime
(`""`, `''`, a `|`/`>` header with an empty body, or a comment-only line)
does not exclude the download. A continuation that is itself tagged
(`GH_TOKEN: !!int` plus a more-indented `!!str ""`) is read by its text and
stays accepted, matching the runtime-invalid stance below; an untagged bare
key or a `!!str`/`!!null` continuation keeps its pre-existing reading — only
the header line is read — so a NON-EMPTY continuation (`ghp_x`) is refused
even though the runtime value is non-empty (a fail-closed false red,
documented, not modelled), while an empty continuation refuses for the right
reason. `blank_comments` opens a
quote only at scalar-start positions, so after a tag the quote never opens
and a `#` inside the quoted argument is blanked: `GH_TOKEN: !!int " #c"` /
`!!int ' #c'` / `!foo " #c"` is non-empty at runtime but reads empty here —
a fail-closed false red, documented, not modelled. Runtime-invalid tagged
values are accepted where GitHub's parser errors: `GH_TOKEN: !!str !!int ""`
and the flow-sequence env value `[!!int ""]` stay accepted, while
`{a: !!int ""}` is refused by the flow-mapping rule and the reversed
`GH_TOKEN: !!int !!str ""` resolves to the empty string and is refused by the
missing-edge rule — the
workflow cannot run, so there is no race, and the tag-order asymmetry is
deliberate rather than modelled. The whitespace-escape and BOM
families (#335) are fixed here, and the invariants are: a static `env:`
value's double-quoted scalar is decoded with the FULL YAML escape set
(`GH_TOKEN: "\\x20"`, `"\\u0020"`, `"\\_"` are the whitespace strings the
runner reads, so they cannot look non-empty); the token presence predicate
mirrors ECMAScript `String.prototype.trim()` — 25 code points (WhiteSpace +
LineTerminator, including U+FEFF, and NOT Python's `str.strip()`, which
keeps U+FEFF and additionally removes U+001C–U+001F/U+0085) — so a BOM-only
or otherwise JS-empty token never carries the cross-run exclusion; and a
semantic value (`uses`, `needs`, `with:` keys) is escape-checked past a
string tag or anchor and inside an inline-flow sequence (a leading
non-string tag is refused by the tag policy with its own diagnostic), so
`uses: !!str &a "…\\x61…"`, a tagged/anchored `github-token:` value and
`needs: ["\\x61"]` are refused
instead of being read through the subset decoder; one unsupported escape
anywhere in a semantic flow sequence refuses the whole file even when
another item already proves the edge (`needs: [build, "b\\u0075ild"]`), which
is the intended policy since the scalar form was already refused. Remaining
fail-closed limits, kept honestly: an INVALID escape in an env value stays
accepted
(`"\\q"`, `"\\x4"`, `"\\xZZ"`, `"\\u12"`, `"\\U00110000"` — GitHub's parser
errors on each, so the workflow cannot run); the run-id literal predicate is
`parseInt`'s — an ECMAScript trim (`js_trim`) followed by the longest
leading run of ASCII digits (`PARSEINT_PREFIX_RE`), with a `0x`/`0X` prefix
requiring at least one hex digit (`[0-9a-fA-F]`) because a bare prefix is
`NaN`, not `0` (so `0x10` stays a genuine handoff and `0x`/`0xg` are
refused) — so a `run-id:` literal
prefixed with U+0085 or U+001C–U+001F is refused (its runtime value is
`<U+0085><digits>`, `parseInt` yields `NaN`, and a `NaN` run-id requests
`/runs/NaN/artifacts` — a 404, not a same-run download, so this is a
correctness divergence, not a fail-open) while a BOM-prefixed literal (and
any digit-led literal with trailing junk, including U+0085/U+001C–U+001F
that Python `strip()` removes but ECMAScript keeps) is accepted; `+123`
and `-123` stay refused although `parseInt` honors them (fail-closed false
reds, documented rather than modelled); a PLAIN (unquoted) raw U+0085/U+001C
value is still refused even
though ECMAScript keeps it, at three Python-`strip()` sites — `env:`
(`_static_env_value`'s leading strip collapses it before the token
predicate), a direct `github-token:` (`decode_scalar`'s `value.strip()`),
and a block-scalar env body that is only U+0085/U+001C (`is_blank`'s
`line.strip()`) — while the quoted shape resolves; these fail-closed false
reds are documented rather than modelled; a Windows runner's `env` context is
case-insensitive (`OrdinalIgnoreCase`, last-wins), so a case-variant
reference is refused and a case-colliding `env:` mapping cannot make the
gate exclude a same-run download: for every name a chain resolves through,
the visible chain is merged in the runner's order (workflow, then job, then
step) and the LAST assignment among the case-variants wins under
`OrdinalIgnoreCase`, so the download is refused when the merged winner is
not the exact-case name the value references (issue #341), while a chain
whose exact-case name is assigned nowhere visible is left to the
pre-existing case-mismatch/unresolved diagnostics; a name whose
chain has a non-ASCII candidate refuses too, because the exact
`OrdinalIgnoreCase` folding is not modelled (`lower()`/`upper()` each miss a
pair); and a preceding `run:` step in the same job that mentions
`GITHUB_ENV` makes any `github-token:` that resolves through the static
`env:` chain unprovable, so the download is refused (issue #339):
actions/runner merges `$GITHUB_ENV` writes into the job environment before a
later step's `with:` is evaluated, so the write can change or empty the
token. The detector decodes the run scalar's YAML escapes with the same full
double-quoted decoder the static `env:` values use, then treats as a mention
the case-insensitive `github_env` substring (which also catches a Windows
`%github_env%`) and a case-sensitive `GITHUB`/`ENV` conjunction inside a
64-character window (which closes shell-level name assembly: the
`n="GITHUB_""ENV"` pair, a `bash -c` argv), so single `>`, `tee`, heredocs,
indirection and related spellings are all covered. It is still a deliberate
text-level fail-closed over-approximation: a read-only `cat "$GITHUB_ENV"`,
an unrelated-name write, a same-value rewrite and a write shadowed by the
download step's own `env:` all refuse (accepted costs, each pinned or
named), while a `uses:`/composite action that writes `$GITHUB_ENV` stays
invisible, and a name assembled from pieces not both present in the body's
text (base64/hex-encoded, read from a file, or produced by a called script)
is not detected — the documented boundary of a text-based detector.
Runtime values were
verified offline against the published `@actions/workflow-parser` 0.3.61
(`dist/workflows/yaml-object-reader.js` `getLiteralToken` +
`dist/templates/template-reader.js` `validate()`), its `yaml` 2.9.1
dependency, `@actions/core@3.0.0` `getInput` (ECMAScript `.trim()`), and
`actions/download-artifact@v8` (`if (inputs.token)` gates the `run-id`
filter); no live GitHub Actions run was executed, so the hosted service's
exact parser build is still assumed equal to the published package — the
same proxy every earlier round used. Already covered, not re-hunted:
`github-token: {null}` and `with: {name: x, github-token: null}` (flow
refusal); `github-token: >-` with or without a body (block-scalar-header
refusal); `github-token: &a null` (anchor refusal); a bare or
whitespace-only `github-token:`; `github-token: !!int null` (non-string-tag
refusal; the runtime value would be the text `null`); and env `!!int null`,
which is `StringToken("null")` at runtime, so reading it as present is
correct.

Usage:
    python3 scripts/ci/check-artifact-dependencies.py [--root DIR]
    python3 scripts/ci/check-artifact-dependencies.py --selftest

Exit codes: 0 = all scans passed; 1 = a violation or refusal (or a
selftest mismatch).
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS_RELPATH = Path(".github") / "workflows"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures" / "artifact-dependency"
MANIFEST_PATH = FIXTURES_DIR / "manifest.py"

# The stated manifest-length constant. `--selftest` fails if the manifest
# length differs, so deleting a fixture (or its case) without updating this
# constant and the Swift pin is a red selftest, never a silent pass.
EXPECTED_MANIFEST_CASES = 231

# The scan floor. A typo'd `--root` (or a truncated checkout) must not look
# like a pass; update this constant only when workflows are intentionally
# removed (and then update the pin suite too).
MIN_SCANNED_WORKFLOW_FILES = 12

UPLOAD_ACTION = "actions/upload-artifact"
DOWNLOAD_ACTION = "actions/download-artifact"
ARTIFACT_TOKEN_RE = re.compile(r"(?:upload|download)-artifact", re.IGNORECASE)
ACTION_REF_RE = re.compile(
    r"(?:[A-Za-z0-9_.-]+/)?(?:upload|download)-artifact@[A-Za-z0-9_.-]+",
    re.IGNORECASE,
)
BLOCK_HEADER_RE = re.compile(r"^(?:[|>][+-]?\d*|[|>]\d*[+-]?)$")
# `actions/download-artifact@v8` parses `run-id:` with
# `parseInt(core.getInput(Inputs.RunID, {required: false}))`
# (`download-artifact.ts:24`): an ECMAScript trim of the input the action
# reads, then the longest LEADING run of ASCII digits. `[0-9]+` (not
# Python's `\d`, which also matches `'\u0661\u0662\u0663'`-style Unicode
# digits `parseInt` rejects) and `.match` (not `.fullmatch`, because
# `parseInt('123abc')` is 123, so trailing junk does not change the handoff).
PARSEINT_PREFIX_RE = re.compile(r"[0-9]+")
# `parseInt`'s radix detection: a leading `0x`/`0X` switches to base 16 and
# then needs at least one hex digit. A bare prefix (or a non-hex character
# after it) is `NaN`, not `0`, so `[0-9]+` alone would read the `0` of `0xg`
# as a literal handoff while the runtime requests `/runs/NaN/artifacts`.
PARSEINT_HEX_PREFIX_RE = re.compile(r"0[xX][0-9a-fA-F]")
SAME_RUN_RE = re.compile(r"github\.run_id|github\[run_id\]")
CROSS_RUN_RE = re.compile(
    r"^(?:env\.[A-Za-z_][A-Za-z0-9_]*"
    r"|github\.event\.workflow_run\.id"
    r"|vars\.[A-Za-z_][A-Za-z0-9_]*"
    r"|inputs\.[A-Za-z_][A-Za-z0-9_]*)$"
)
FLOW_REFUSAL = (
    "flow mapping '{' in a parsed position — write a block mapping "
    "(flow syntax is refused rather than guessed)"
)
ANCHOR_REFUSAL = (
    "anchor or alias '&'/'*' in a parsed position — YAML anchors/aliases are "
    "refused (write the value explicitly)"
)
QUOTE_REFUSAL = (
    "unterminated quoted scalar — a quoted scalar must close on its own line "
    "(multi-line quoted scalars are refused rather than guessed)"
)
UNCONSUMED_REFUSAL = (
    "unconsumed line — every line in a job or step must be a mapping key the "
    "gate understands (refusing rather than skipping)"
)
RUN_SCOPED_SUFFIX = "artifacts are run-scoped; use `run-id:` for a cross-run handoff"


class Refusal(Exception):
    """A construct the subset parser cannot fully prove. Fails the scan."""

    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line
        self.message = message


@dataclass
class ArtifactStep:
    kind: str  # "upload" | "download" | ""
    uses_line: int
    # The step's first line, used for the #339 position check (a write can
    # only affect steps that start after it).
    step_line: int = 0
    name: str | None = None
    name_line: int | None = None
    name_is_literal: bool = False
    run_id: str | None = None
    run_id_line: int | None = None
    run_id_cross_run: bool = False
    has_github_token: bool = False
    github_token: str | None = None
    github_token_line: int | None = None
    has_pattern: bool = False
    pattern_line: int | None = None
    has_artifact_ids: bool = False
    artifact_ids_line: int | None = None
    has_with: bool = False
    # The step's own `env:` block, as an inclusive line range. Only this
    # range (plus the workflow's and the enclosing job's) is visible to
    # `${{ env.NAME }}` at runtime (R5-MINOR-1).
    env_range: tuple[int, int] | None = None
    # The `run:` key line and the #339 mention flag (a non-empty body that
    # contains the `GITHUB_ENV` substring).
    run_line: int | None = None
    run_mentions_github_env: bool = False


@dataclass
class RunBody:
    """A parsed `run:` step's location and whether its body mentions
    `$GITHUB_ENV`. The gate does not model run bodies otherwise; this is the
    #339 mention scan (a name extraction is measurably leaky, so the detector
    is the raw substring: redirects, `tee`, heredocs and indirection all
    count)."""

    line: int  # the `run:` key line
    step_line: int  # the enclosing step's first line
    mentions_github_env: bool


@dataclass
class Job:
    name: str
    line: int
    needs: list[str] = field(default_factory=list)
    needs_lines: list[int] = field(default_factory=list)
    has_uses: bool = False
    uses_line: int | None = None
    has_steps: bool = False
    steps_line: int | None = None
    artifact_steps: list[ArtifactStep] = field(default_factory=list)
    keys_seen: dict[str, int] = field(default_factory=dict)
    # The job's own `env:` block, as an inclusive line range (R5-MINOR-1).
    env_range: tuple[int, int] | None = None
    # Every parsed `run:` step's location/mention record, in step order
    # (the #339 same-job, preceding-position scan).
    run_bodies: list[RunBody] = field(default_factory=list)


@dataclass
class FileResult:
    relpath: str
    uploads: int = 0
    downloads: int = 0
    excluded: int = 0
    diagnostics: list[tuple[int, str]] = field(default_factory=list)
    jobs: list[Job] = field(default_factory=list)


@dataclass
class ScanResult:
    diagnostics: list[str] = field(default_factory=list)
    summary: list[str] = field(default_factory=list)
    checked_downloads: int = 0


# ---------------------------------------------------------------------------
# Lexical helpers
# ---------------------------------------------------------------------------


def normalize_text(raw: bytes) -> list[str]:
    """Decode (BOM-tolerant) and normalize CRLF/CR to LF; split into lines."""
    text = raw.decode("utf-8-sig")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.split("\n")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def is_blank(line: str) -> bool:
    return line.strip() == ""


def starts_item(text: str) -> bool:
    return text.startswith("-") and (len(text) == 1 or text[1] in (" ", "\t"))


def blank_comments(lines: list[str]) -> list[str]:
    """Blank `#` comments; quotes only open at scalar-start positions, so an
    apostrophe inside a plain scalar (`don't`) is not read as a quote and a
    comment after it is still blanked."""
    out: list[str] = []
    for line in lines:
        result: list[str] = []
        i = 0
        n = len(line)
        quote: str | None = None
        prev_significant = ""
        preceded_by_space = True
        while i < n:
            c = line[i]
            if quote is not None:
                result.append(c)
                if quote == '"':
                    if c == "\\" and i + 1 < n:
                        result.append(line[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        quote = None
                else:
                    if c == "'":
                        if i + 1 < n and line[i + 1] == "'":
                            result.append("'")
                            i += 2
                            continue
                        quote = None
                i += 1
                continue
            if c == "#" and preceded_by_space:
                result.append(" " * (n - i))
                break
            result.append(c)
            if c in ("'", '"') and prev_significant in ("", ":", "-", "[", ",", "{"):
                quote = c
            if not c.isspace():
                prev_significant = c
            preceded_by_space = c.isspace()
            i += 1
        out.append("".join(result))
    return out


def _scan_quoted(s: str, start: int) -> tuple[int, str]:
    """Scan a quoted scalar starting at `s[start]`; returns (index after the
    close, decoded text). An unterminated scalar returns the end of the
    string; the closure pass turns that into a refusal."""
    quote = s[start]
    i = start + 1
    buf: list[str] = []
    while i < len(s):
        c = s[i]
        if quote == '"':
            if c == "\\":
                if i + 1 < len(s):
                    nxt = s[i + 1]
                    buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
                    i += 2
                    continue
                buf.append(c)
                i += 1
                continue
            if c == '"':
                return (i + 1, "".join(buf))
            buf.append(c)
            i += 1
        else:
            if c == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    buf.append("'")
                    i += 2
                    continue
                return (i + 1, "".join(buf))
            buf.append(c)
            i += 1
    return (len(s), "".join(buf))


STRING_TAG = "tag:yaml.org,2002:str"


def _leading_tag(s: str) -> str | None:
    """The tag token at the very start of a plain scalar (`!...`), or None.
    A plain YAML scalar cannot start with the `!` indicator, so a leading `!`
    is necessarily a tag; the token ends at whitespace or at the quote that
    starts the tagged scalar. `!<...>` is the verbatim-tag spelling."""
    if not s.startswith("!"):
        return None
    if s.startswith("!<"):
        end = s.find(">")
        if end == -1:
            return s
        return s[: end + 1]
    end = 1
    while end < len(s) and not s[end].isspace() and s[end] not in ("'", '"'):
        end += 1
    return s[:end]


def _is_string_tag(tag: str) -> bool:
    return tag == "!!str" or tag == f"!<{STRING_TAG}>"


def _strip_str_tag(s: str) -> str:
    """Skip a leading YAML string tag (`!!str` / `!<tag:yaml.org,2002:str>`)
    so the scalar is read the way GitHub's runner reads it: the tag resolves
    to the same scalar text (actions/runner `YamlObjectReader` handles
    `tag:yaml.org,2002:str`). Only the string tag is skipped — a leading `!`
    on a plain scalar (`if: !cancelled()`) is not the string tag and is left
    alone, and any other tag is left for the callers to refuse."""
    tag = _leading_tag(s)
    if tag is not None and _is_string_tag(tag):
        return s[len(tag) :].lstrip()
    return s


def _strip_anchor(s: str) -> str:
    """Strip a leading anchor property (`&name`) from a scalar value, or
    return it unchanged. A plain YAML scalar cannot start with `&`, so a
    leading `&` is necessarily a node property, and an anchor does not change
    the value at runtime — `!!str &a foo` is the scalar `foo` (R8-BLOCKER-2).
    An anchor with no following value (`&a`) is the empty scalar."""
    if not s.startswith("&"):
        return s
    end = 1
    while end < len(s) and not s[end].isspace():
        end += 1
    if end >= len(s):
        return ""
    return s[end:].lstrip()


def _strip_node_properties(value: str) -> str:
    """A static scalar's text after every leading node property (a `!` tag, a
    verbatim `!<...>` tag, an `&name` anchor) is removed. Neither changes the
    string the runner reads for a static `env:` value, and a property-only
    value (`!!int`, `!foo &a`) has no inline scalar text of its own."""
    text = value.strip()
    while True:
        tag = _leading_tag(text)
        if tag is not None:
            text = text[len(tag) :].lstrip()
            continue
        if text.startswith("&"):
            text = _strip_anchor(text)
            continue
        break
    return text


def _static_block_header(value: str) -> str | None:
    """The block-scalar header text of a static value after any leading node
    properties (tags and anchors), or None. `GH_TOKEN: !!null |` and
    `!!str &a |` are block scalars exactly like `|`: the tag and anchor do not
    change the body, which is the value at runtime, so a tagged header is
    resolved through the captured body and refused where a semantic key
    expects an inline scalar (R8-BLOCKER-1, R8-BLOCKER-2)."""
    text = _strip_node_properties(value)
    return text if BLOCK_HEADER_RE.match(text) else None


def split_key_value(s: str) -> tuple[str, str, str] | None:
    """Split `key: value` at the start of `s` (no leading whitespace).

    Returns `(key_text, value_text, kind)` where kind is `plain` or
    `quoted`, or None when `s` is not a mapping entry."""
    if not s:
        return None
    s = _strip_str_tag(s)
    if not s:
        # A line that is only a string tag (`!!str`) strips to the empty
        # string, and `s[0]` would raise IndexError instead of letting the
        # line fall through to the gate's own unconsumed-line refusal
        # (#334-MINOR-1). A bare non-string tag (`!tag`) keeps its text —
        # there is no `:` to split on — so only the string tag can empty `s`.
        return None
    if s[0] in ("'", '"'):
        end, key = _scan_quoted(s, 0)
        i = end
        while i < len(s) and s[i] == " ":
            i += 1
        if i >= len(s) or s[i] != ":":
            return None
        if i + 1 < len(s) and s[i + 1] not in (" ", "\t"):
            return None
        value = s[i + 1 :].strip()
        return (key, value, "quoted")
    index = s.find(":")
    while index != -1:
        if index + 1 >= len(s) or s[index + 1] == " ":
            key = s[:index].strip()
            value = s[index + 1 :].strip()
            if not key:
                return None
            return (key, value, "plain")
        index = s.find(":", index + 1)
    return None


def quote_is_closed_on_line(s: str, start: int) -> bool:
    """True when the quoted scalar opened at `s[start]` closes on this line."""
    quote = s[start]
    i = start + 1
    while i < len(s):
        c = s[i]
        if quote == '"':
            if c == "\\":
                i += 2
                continue
            if c == '"':
                return True
        else:
            if c == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    i += 2
                    continue
                return True
        i += 1
    return False


def decode_scalar(value: str) -> str:
    """Decode a scalar value the way the runner reads it: a leading string
    tag and a leading anchor property are skipped (neither changes the string
    the runner gets — `!!str &a foo` is `foo`), then a quoted scalar is
    decoded and a plain scalar is its text (R8-BLOCKER-2)."""
    value = value.strip()
    while True:
        stripped = _strip_str_tag(value)
        if stripped != value:
            value = stripped
            continue
        anchor_stripped = _strip_anchor(value)
        if anchor_stripped != value:
            value = anchor_stripped
            continue
        break
    if not value:
        return ""
    if value[0] in ("'", '"'):
        _, decoded = _scan_quoted(value, 0)
        return decoded
    return value


def _decode_key(key: str, kind: str) -> str:
    """Decode a key returned by `split_key_value`. A quoted key is already
    decoded; re-decoding it could strip a literal leading `!!str` or nested
    quote pair that GitHub keeps as key text (e.g. `"!!str run-id"` is not the
    `run-id` input), so only a plain key goes through `decode_scalar`."""
    if kind == "quoted":
        return key
    return decode_scalar(key)


def unterminated_quote_violation(line: str) -> str | None:
    """Return a refusal message when a quoted scalar opened at a scalar-start
    position does not close on its own line. The same-line policy is what
    kills the multi-line quoted scalar that would otherwise fabricate a
    `needs:` edge (plan B2). Runs after block-scalar blanking, so an
    unbalanced `'` in a `run: |` shell body is opaque text."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
    stripped = _strip_str_tag(stripped)
    if not stripped:
        return None
    if stripped[0] in ("'", '"'):
        if not quote_is_closed_on_line(stripped, 0):
            return QUOTE_REFUSAL
        end, _ = _scan_quoted(stripped, 0)
        rest = stripped[end:].lstrip(" ")
        if rest.startswith(":"):
            value = rest[1:].lstrip(" ")
            if value and value[0] in ("'", '"') and not quote_is_closed_on_line(value, 0):
                return QUOTE_REFUSAL
        return None
    kv = split_key_value(stripped)
    if kv is None:
        return None
    _, value, _ = kv
    if value and value[0] in ("'", '"') and not quote_is_closed_on_line(value, 0):
        return QUOTE_REFUSAL
    return None


def _escaped_quoted_scalar_violation(text: str, start: int) -> str | None:
    """Scan the double-quoted scalar opened at `text[start]` for backslash
    escapes the subset decoder does not implement. YAML's own escape set would
    decode `\u006c` to `l`, so a value the decoder reads differently from
    GitHub must not decide whether a step is an artifact step (B1)."""
    i = start + 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            if i + 1 >= len(text):
                return None  # an unterminated scalar is its own refusal
            escape = text[i + 1]
            if escape not in ("n", "t", '"', "\\"):
                return (
                    f"unsupported backslash escape '\\{escape}' in a double-quoted scalar — the gate "
                    "decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full "
                    "escape set)"
                )
            i += 2
            continue
        if c == '"':
            return None
        i += 1
    return None


def _flow_item_texts(body: str) -> list[str]:
    """The items of an inline-flow sequence body, split on commas outside
    quoted scalars. A quote opens a scalar only at an item boundary: the text
    between the item's start and the quote must be nothing but node properties
    (`needs: [!!str &a "…"]`). A `"` inside a plain scalar is literal text,
    and treating it as an opener would swallow the following item and skip its
    escape check (#335 impl lens-1 MINOR 1: `needs: [build, a"b, "\\x61"]`
    must still refuse the escaped item, since a plain item containing `"` is
    not a valid job id and cannot be relied on to make the file unrunnable)."""
    items: list[str] = []
    start = 0
    i = 0
    while i < len(body):
        c = body[i]
        if c in ('"', "'") and _strip_node_properties(body[start:i]) == "":
            if c == '"':
                end, _ = _scan_quoted(body, i)
                i = max(end, i + 1)
                continue
            i += 1
            while i < len(body):
                if body[i] == "'":
                    if i + 1 < len(body) and body[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if c == ",":
            items.append(body[start:i])
            start = i + 1
        i += 1
    items.append(body[start:])
    return items


def _semantic_value_escape_violation(value: str) -> str | None:
    """Refuse an unsupported escape in any double-quoted scalar a semantic
    value resolves to. The value can carry node properties (`uses: !!str &a
    "…"`), and `needs:` accepts an inline-flow sequence (`needs: ["…"]`):
    both routes reach the subset decoder, so an escape YAML resolves
    differently could hide the action step or fabricate a `needs:` edge
    (#335 lens-1 BLOCKERs 1-3). Only a scalar that STARTS with `"` after its
    node properties is a YAML double-quoted scalar; a `"` inside a plain
    scalar is literal text and is not scanned, which is why this is not a
    blind segment scan. A leading non-string tag is left to the tag policy
    refusals (which already reject it) so the escape check does not change
    which refusal fires for a value both rules reject. One unsupported escape
    anywhere in a semantic flow sequence refuses the file even when another
    item already proves the edge (`needs: [build, "b\\u0075ild"]`): the scalar
    form was already refused, so that is the intended policy. A leading anchor
    plus an escape changes which refusal fires (anchor policy -> escape) with
    the exit code unchanged (impl lens-1 NITs 1-2)."""
    text = value.strip()
    tag = _leading_tag(text)
    if tag is not None and not _is_string_tag(tag):
        return None
    stripped_value = _strip_node_properties(text)
    if stripped_value.startswith('"'):
        return _escaped_quoted_scalar_violation(stripped_value, 0)
    if stripped_value.startswith("["):
        for raw_item in _flow_item_texts(stripped_value[1:]):
            item = raw_item.strip()
            item_tag = _leading_tag(item)
            if item_tag is not None and not _is_string_tag(item_tag):
                continue
            item = _strip_node_properties(item)
            if item.startswith('"'):
                message = _escaped_quoted_scalar_violation(item, 0)
                if message:
                    return message
    return None


def quoted_escape_violation(line: str, check_value: bool) -> str | None:
    """Refuse a double-quoted scalar that uses an escape outside the
    decoder's set. A double-quoted *key* is always checked (it can name the
    semantic key itself). A double-quoted *value* is checked only when
    `check_value` is set, i.e. when the line's key is `uses`/`needs` or the
    line belongs to a `with:` mapping: only those positions decide the
    artifact graph, so legal YAML escapes elsewhere (`name: "caf\\u00e9"`,
    `run: "printf '\\x1b[0m'"`) are data the gate never reads. At a semantic
    position the value is resolved past a string tag or anchor and through an
    inline-flow sequence before the check, so a tag/anchor or a flow item
    cannot smuggle the escape past it (#335 lens-1); a leading non-string tag
    is left to the tag policy refusal. Runs after the
    unterminated-quote check (which names an unclosed scalar more precisely)
    and after block-scalar blanking (so shell bodies stay opaque)."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
    stripped = _strip_str_tag(stripped)
    if not stripped:
        return None
    if stripped[0] == '"':
        message = _escaped_quoted_scalar_violation(stripped, 0)
        if message:
            return message
        end, _ = _scan_quoted(stripped, 0)
        rest = stripped[end:].lstrip(" ")
        if rest.startswith(":"):
            value = rest[1:].lstrip(" ")
            if check_value:
                return _semantic_value_escape_violation(value)
        return None
    kv = split_key_value(stripped)
    if kv is None:
        return None
    _, value, _ = kv
    value = _strip_str_tag(value)
    if check_value:
        return _semantic_value_escape_violation(value)
    return None


def semantic_value_lines(lines: list[str]) -> set[int]:
    """Line numbers whose double-quoted value decides the artifact graph:
    step `uses`, job `needs`, and every key of a `with:` mapping. The escape
    refusal is scoped to these positions (C-MINOR-2), so a legal escape in a
    label or a `run:` body is not a false red."""
    semantic: set[int] = set()
    with_columns: list[int] = []
    for index, line in enumerate(lines, start=1):
        if is_blank(line):
            continue
        indent = indent_of(line)
        stripped = line[indent:]
        prefix = 0
        item = re.match(r"^-\s+", stripped)
        if item:
            prefix = item.end()
        rest = stripped[prefix:]
        key_col = indent + prefix
        while with_columns and key_col <= with_columns[-1]:
            with_columns.pop()
        kv = split_key_value(rest)
        if kv is None:
            continue
        key, value, kind = kv
        key = _decode_key(key, kind)
        if key == "with" and not value:
            with_columns.append(key_col)
            continue
        if key in ("uses", "needs") or with_columns:
            semantic.add(index)
    return semantic


def scalar_construct_violation(line: str) -> str | None:
    """Return a refusal message for YAML constructs the subset grammar
    refuses at a parsed position, or None. Called after block-scalar
    blanking, so shell/markdown bodies are opaque text."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
    if stripped.startswith("{"):
        return FLOW_REFUSAL
    if stripped.startswith("&") or stripped.startswith("*"):
        return ANCHOR_REFUSAL
    kv = split_key_value(stripped)
    if kv is None:
        return None
    key, value, _ = kv
    if key == "<<":
        return "merge key '<<' — YAML merge keys are refused (write the keys explicitly)"
    if value.startswith("{"):
        return FLOW_REFUSAL
    if value.startswith("&") or value.startswith("*"):
        return ANCHOR_REFUSAL
    return None


def blank_run_and_env_values(lines: list[str]) -> list[str]:
    """Blank the value lines that cannot be artifact steps — a `run:` scalar
    and every scalar under an `env:` mapping — for the reconciliation scan
    (m1). A token there is data, not a step; a `uses:` line is never blanked,
    because that is exactly the spelling reconciliation exists to catch."""
    out = list(lines)
    env_columns: list[int] = []
    for index, line in enumerate(out):
        if is_blank(line):
            continue
        indent = indent_of(line)
        stripped = line[indent:]
        prefix = 0
        item = re.match(r"^-\s+", stripped)
        if item:
            prefix = item.end()
        rest = stripped[prefix:]
        key_col = indent + prefix
        while env_columns and key_col <= env_columns[-1]:
            env_columns.pop()
        kv = split_key_value(rest)
        if kv is None:
            continue
        key, value, kind = kv
        key = _decode_key(key, kind)
        if key == "env" and not value:
            env_columns.append(key_col)
            continue
        if key == "run" or (env_columns and value):
            out[index] = " " * len(line)
    return out


def blank_non_semantic_name_values(lines: list[str]) -> list[str]:
    """Blank non-semantic `name:` scalars (job- and step-level) for the
    reconciliation scan (m1). A step `name:` may mention a tool without being
    a step, and a job `name:` is a label; neither can be a `uses:` value. A
    `name:` inside a `with:` mapping is semantic (`with.name` is the artifact
    name) and is never blanked."""
    out = list(lines)
    with_columns: list[int] = []
    for index, line in enumerate(out):
        if is_blank(line):
            continue
        indent = indent_of(line)
        stripped = line[indent:]
        prefix = 0
        item = re.match(r"^-\s+", stripped)
        if item:
            prefix = item.end()
        rest = stripped[prefix:]
        key_col = indent + prefix
        while with_columns and key_col <= with_columns[-1]:
            with_columns.pop()
        kv = split_key_value(rest)
        if kv is None:
            continue
        key, value, kind = kv
        key = _decode_key(key, kind)
        if key == "with" and not value:
            with_columns.append(key_col)
            continue
        if key == "name" and not with_columns:
            out[index] = " " * len(line)
    return out


def blank_block_scalars(
    lines: list[str], source: list[str] | None = None
) -> tuple[list[str], dict[int, str]]:
    """Blank block-scalar bodies (full header grammar `[|>][+-]?\\d*` /
    `[|>]\\d*[+-]?`) and return the body text of every block scalar, keyed by
    the header's 1-based line number. A body line is any subsequent line
    indented deeper than the key whose value is the scalar; the scalar ends
    when a line dedents to or above that key. `lines` (usually comment-blanked)
    decides which headers and extents exist; the bodies are captured from
    `source` when supplied — the pre-comment-blanking text — because a `#`
    inside a block-scalar body is content, not a comment: a comment-only body
    is a NON-empty runtime value (R7-MAJOR-1). The static `env:` index must
    tell an empty body (a runtime-empty value) from a non-empty one
    (R6-BLOCKER-1). A property-only value (`GH_TOKEN: !!int`, `!foo &a`) can
    take its scalar from a following more-indented line, and that scalar can
    itself be a block header; such a header is captured the same way, keyed
    by its own line, so `_static_env_value` can resolve the continuation
    (#334 continuation resolution)."""
    out = list(lines)
    body_source = lines if source is None else source
    bodies: dict[int, str] = {}
    for i, line in enumerate(out):
        if is_blank(line):
            continue
        indent = indent_of(line)
        stripped = line[indent:]
        prefix = 0
        item = re.match(r"^-\s+", stripped)
        if item:
            prefix = item.end()
        rest = stripped[prefix:]
        kv = split_key_value(rest)
        if kv is None:
            continue
        _, value, _ = kv
        key_indent = indent + prefix
        header_index = i
        if _static_block_header(value) is None:
            # A property-only value (`GH_TOKEN: !!int`, `!foo &a`) can take
            # its scalar from a following more-indented line, and that scalar
            # can itself be a block header (`GH_TOKEN: !!int` followed by an
            # indented `|` and a body). The body is still the runtime value,
            # and a comment-only body is content, not a comment, so the
            # next-line header is captured exactly like the same-line one,
            # keyed by the header's own line — the key `_static_env_value`
            # looks up when it resolves a non-string-tag continuation
            # (#334 continuation resolution). Only a leading non-string tag
            # is followed: an untagged bare key and the string tag keep their
            # pre-existing (fail-closed) reading.
            tag = _leading_tag(value.strip())
            if tag is None or _is_string_tag(tag):
                continue
            if _strip_node_properties(value):
                continue
            j = i + 1
            while j < len(out) and is_blank(out[j]):
                j += 1
            if j >= len(out) or indent_of(out[j]) <= key_indent:
                continue
            next_indent = indent_of(out[j])
            next_stripped = out[j][next_indent:]
            next_prefix = 0
            next_item = re.match(r"^-\s+", next_stripped)
            if next_item:
                next_prefix = next_item.end()
            if _static_block_header(next_stripped[next_prefix:]) is None:
                continue
            header_index = j
        body_lines: list[str] = []
        j = header_index + 1
        while j < len(out):
            body = body_source[j]
            if is_blank(body):
                body_lines.append("")
                out[j] = ""
                j += 1
                continue
            if indent_of(body) > key_indent:
                body_lines.append(body)
                out[j] = ""
                j += 1
                continue
            break
        bodies[header_index + 1] = "\n".join(body_lines)
    return out, bodies


# ---------------------------------------------------------------------------
# Workflow parser
# ---------------------------------------------------------------------------


def _refuse_block_scalar_header(index: int, key: str, value: str) -> None:
    """A block-scalar header where a semantic key's value belongs would make
    the gate read the header as the value while the real value is blanked
    (B2), so it is a refusal, not an opaque scalar. A tag or anchor before
    the header (`!!str |`, `!!null |`, `!!str &a |`) does not change the
    construct, so the header is resolved through the node properties
    (R8-BLOCKER-1, R8-BLOCKER-2)."""
    header = _static_block_header(value)
    if header is not None:
        raise Refusal(
            index + 1,
            f"block scalar header '{header}' as the value of '{key}:' — this key decides the artifact "
            "graph and must be an inline scalar (refusing rather than guessing the folded value)",
        )


def _refuse_non_string_value_tag(index: int, key: str, value: str) -> None:
    """Refuse a leading YAML tag other than the string tag on a value that
    decides the artifact graph. The string tag resolves to the same scalar
    GitHub reads; another tag can change it (`github-token: !!null` is an
    empty input), so the gate refuses rather than guessing. Scoped to
    semantic values, so a plain scalar condition (`if: !cancelled()`) stays
    legal."""
    tag = _leading_tag(value.strip())
    if tag is None or _is_string_tag(tag):
        return
    raise Refusal(
        index + 1,
        f"YAML tag '{tag}' on the value of '{key}:' — only the string tag ('!!str') is resolved "
        "to the scalar GitHub reads; any other tag can coerce this value, so the gate refuses "
        "rather than guessing",
    )


class WorkflowParser:
    def __init__(
        self, relpath: str, lines: list[str], block_bodies: dict[int, str]
    ) -> None:
        self.relpath = relpath
        self.lines = lines
        # Block-scalar bodies by header line (`blank_block_scalars`), needed
        # for the #339 mention scan: a `run: |` body is blanked out of
        # `self.lines` and only the captured body still holds it.
        self.block_bodies = block_bodies
        self.jobs: list[Job] = []
        self.artifact_step_lines: set[int] = set()
        # The top-level `env:` block, as an inclusive line range: workflow
        # env is visible to every step, so it stays in scope everywhere.
        self.workflow_env_range: tuple[int, int] | None = None

    # -- small helpers -----------------------------------------------------

    def _indent(self, index: int) -> int:
        return indent_of(self.lines[index])

    def _body(self, index: int) -> str:
        return self.lines[index][self._indent(index) :]

    def _kv(self, index: int, text: str) -> tuple[str, str]:
        kv = split_key_value(text)
        if kv is None:
            raise Refusal(index + 1, UNCONSUMED_REFUSAL)
        key, value, kind = kv
        if kind == "plain":
            tag = _leading_tag(key)
            if tag is not None:
                raise Refusal(
                    index + 1,
                    f"YAML tag '{tag}' on a mapping key — only a single leading string tag "
                    "('!!str') is resolved to the scalar GitHub reads; a second tag or any other "
                    "tag can coerce the key, so the gate refuses rather than guessing",
                )
        return _decode_key(key, kind), value

    def _next_non_blank(self, body: list[int], start: int) -> int | None:
        for i in range(start, len(body)):
            if not is_blank(self.lines[body[i]]):
                return i
        return None

    # -- top level ---------------------------------------------------------

    def parse(self) -> list[Job]:
        self._scan_top_level_duplicates()
        self.workflow_env_range = self._find_workflow_env_range()
        jobs_index = self._find_jobs_key()
        end = self._jobs_region_end(jobs_index)
        self._parse_job_region(list(range(jobs_index + 1, end)), jobs_index + 1)
        return self.jobs

    def _top_level_block_end(self, index: int) -> int:
        """The first line index after `index` that is non-blank and back at
        column 0 — a top-level block's end (the jobs region uses the same
        rule)."""
        for i in range(index + 1, len(self.lines)):
            if is_blank(self.lines[i]):
                continue
            if indent_of(self.lines[i]) == 0:
                return i
        return len(self.lines)

    def _find_workflow_env_range(self) -> tuple[int, int] | None:
        """The top-level `env:` block's inclusive line range, or None when
        there is no block-mapping workflow env (R5-MINOR-1)."""
        for key, line in self._top_level_keys():
            if key != "env":
                continue
            index = line - 1
            kv = split_key_value(self._body(index))
            if kv is None or kv[1].strip():
                return None
            end = self._top_level_block_end(index)
            if end <= index + 1:
                return None
            return (index + 1, end)
        return None

    def _top_level_keys(self) -> list[tuple[str, int]]:
        keys: list[tuple[str, int]] = []
        for index, line in enumerate(self.lines):
            if is_blank(line) or self._indent(index) != 0:
                continue
            kv = split_key_value(line)
            if kv is None:
                continue
            keys.append((_decode_key(kv[0], kv[2]), index + 1))
        return keys

    def _scan_top_level_duplicates(self) -> None:
        seen: dict[str, int] = {}
        for key, line in self._top_level_keys():
            if key in seen:
                raise Refusal(
                    line,
                    f"duplicate top-level key '{key}' (lines {seen[key]} and {line}) — "
                    "remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
                )
            seen[key] = line

    def _find_jobs_key(self) -> int:
        jobs_lines = [line for key, line in self._top_level_keys() if key == "jobs"]
        if not jobs_lines:
            raise Refusal(
                1,
                "no top-level 'jobs:' mapping — refusing rather than passing a file the gate cannot read",
            )
        if len(jobs_lines) > 1:
            raise Refusal(
                jobs_lines[1],
                f"duplicate top-level key 'jobs:' (lines {jobs_lines[0]} and {jobs_lines[1]}) — "
                "remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
            )
        index = jobs_lines[0] - 1
        kv = split_key_value(self._body(index))
        assert kv is not None
        if kv[1].strip() not in ("", "{}"):
            raise Refusal(
                index + 1,
                "top-level 'jobs:' must be a block mapping of jobs — refusing rather than guessing",
            )
        return index

    def _jobs_region_end(self, jobs_index: int) -> int:
        for index in range(jobs_index + 1, len(self.lines)):
            if is_blank(self.lines[index]):
                continue
            if self._indent(index) == 0:
                return index
        return len(self.lines)

    def _parse_job_region(self, region: list[int], jobs_key_line: int) -> None:
        job_key_col: int | None = None
        current: list[int] = []
        blocks: list[tuple[str, int, list[int]]] = []
        for index in region:
            if is_blank(self.lines[index]):
                if current:
                    current.append(index)
                continue
            indent = self._indent(index)
            if job_key_col is None:
                job_key_col = indent
            if indent < job_key_col:
                raise Refusal(index + 1, UNCONSUMED_REFUSAL)
            if indent == job_key_col:
                if current:
                    blocks.append(self._finish_job_block(current))
                if job_key_col == 0:
                    raise Refusal(
                        index + 1,
                        "unconsumed line — a job key must be indented under 'jobs:' (refusing rather than skipping)",
                    )
                key, value = self._kv(index, self._body(index))
                if value.strip():
                    raise Refusal(
                        index + 1,
                        f"job '{key}' must be a mapping, not an inline value — write its keys on following lines (refusing rather than guessing)",
                    )
                current = [index]
                continue
            if not current:
                raise Refusal(index + 1, UNCONSUMED_REFUSAL)
            current.append(index)
        if current:
            blocks.append(self._finish_job_block(current))
        if not blocks:
            raise Refusal(
                jobs_key_line,
                "'jobs:' is empty — refusing rather than passing a workflow with no jobs",
            )
        seen: dict[str, int] = {}
        for name, line, block in blocks:
            if name in seen:
                raise Refusal(
                    line,
                    f"duplicate job '{name}' (lines {seen[name]} and {line}) — every job key must be unique",
                )
            seen[name] = line
            self.jobs.append(self._parse_job(name, line, block))

    def _finish_job_block(self, lines: list[int]) -> tuple[str, int, list[int]]:
        index = lines[0]
        key, _ = self._kv(index, self._body(index))
        return (key, index + 1, lines)

    # -- job body ----------------------------------------------------------

    def _parse_job(self, name: str, line: int, block: list[int]) -> Job:
        job = Job(name=name, line=line)
        body = list(block[1:])
        first = self._next_non_blank(body, 0)
        if first is None:
            return job
        body_col = self._indent(body[first])
        i = 0
        while i < len(body):
            index = body[i]
            if is_blank(self.lines[index]):
                i += 1
                continue
            if self._indent(index) != body_col:
                raise Refusal(index + 1, UNCONSUMED_REFUSAL)
            key, value = self._kv(index, self._body(index))
            if key in job.keys_seen:
                raise Refusal(
                    index + 1,
                    f"duplicate mapping key '{key}' (lines {job.keys_seen[key]} and {index + 1}) — "
                    "remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
                )
            job.keys_seen[key] = index + 1
            if key == "uses":
                job.has_uses = True
                job.uses_line = index + 1
                i = i + 1 if value else self._consume_opaque(body, i, body_col)
                continue
            if key == "steps":
                job.has_steps = True
                job.steps_line = index + 1
                if value:
                    raise Refusal(
                        index + 1,
                        "'steps:' must be a block sequence of step mappings — refusing rather than guessing",
                    )
                i = self._parse_steps(job, body, i, body_col)
                continue
            if key == "env":
                i, job.env_range = self._consume_env_block(body, i, body_col)
                continue
            if key == "needs":
                _refuse_block_scalar_header(index, key, value)
                _refuse_non_string_value_tag(index, key, value)
                if value:
                    for entry in _parse_inline_needs(index + 1, value):
                        job.needs.append(entry)
                    job.needs_lines.append(index + 1)
                    i += 1
                else:
                    i = self._parse_block_needs(job, body, i, body_col)
                continue
            i = i + 1 if value else self._consume_opaque(body, i, body_col)
        if job.has_uses and job.has_steps:
            assert job.uses_line is not None and job.steps_line is not None
            raise Refusal(
                max(job.uses_line, job.steps_line),
                f"job '{name}' has both 'uses:' (line {job.uses_line}) and 'steps:' "
                f"(line {job.steps_line}) — a reusable-workflow call cannot declare steps",
            )
        return job

    def _consume_opaque(self, body: list[int], key_pos: int, parent_col: int) -> int:
        """Consume a key's value: everything deeper than the key's column,
        plus a same-indent block sequence, until dedent to the key column."""
        j = key_pos + 1
        while j < len(body):
            index = body[j]
            if is_blank(self.lines[index]):
                j += 1
                continue
            indent = self._indent(index)
            if indent > parent_col:
                j += 1
                continue
            if indent == parent_col and starts_item(self._body(index)):
                j += 1
                continue
            break
        return j

    def _consume_env_block(
        self, body: list[int], pos: int, col: int
    ) -> tuple[int, tuple[int, int] | None]:
        """Consume an `env:` value block and return `(next body index, line
        range)`. The range is what the static-env index is scoped by, so it
        must cover exactly the lines the block owns (R5-MINOR-1)."""
        end = self._consume_opaque(body, pos, col)
        if end <= pos + 1:
            return end, None
        return end, (body[pos] + 1, body[end - 1] + 1)

    def _parse_block_needs(self, job: Job, body: list[int], i: int, needs_col: int) -> int:
        j = i + 1
        while j < len(body):
            index = body[j]
            if is_blank(self.lines[index]):
                j += 1
                continue
            indent = self._indent(index)
            text = self._body(index)
            if indent >= needs_col and starts_item(text):
                item = decode_scalar(text[1:].strip())
                if item:
                    job.needs.append(item)
                    job.needs_lines.append(index + 1)
                j += 1
                continue
            if indent > needs_col:
                raise Refusal(
                    index + 1,
                    "unconsumed line — a 'needs:' entry must be a block sequence item (refusing rather than skipping)",
                )
            break
        return j

    # -- steps -------------------------------------------------------------

    def _parse_steps(self, job: Job, body: list[int], i: int, steps_col: int) -> int:
        j = i + 1
        item_col: int | None = None
        while j < len(body):
            index = body[j]
            if is_blank(self.lines[index]):
                j += 1
                continue
            indent = self._indent(index)
            text = self._body(index)
            if not starts_item(text):
                break
            if item_col is None:
                item_col = indent
            elif indent != item_col:
                raise Refusal(
                    index + 1,
                    "unconsumed line — 'steps:' sequence items must all sit at one indentation (refusing rather than skipping)",
                )
            j = self._parse_step(job, body, j, item_col)
        return j

    def _parse_step(self, job: Job, body: list[int], item_pos: int, item_col: int) -> int:
        step = ArtifactStep(kind="", uses_line=0, step_line=body[item_pos] + 1)
        seen: dict[str, int] = {}
        rest = self.lines[body[item_pos]][item_col + 1 :]
        offset = 0
        while offset < len(rest) and rest[offset] == " ":
            offset += 1
        content = rest[offset:]
        content_col = item_col + 1 + offset
        j = item_pos + 1
        step_key_col: int | None = None
        if content:
            if content.startswith("{"):
                raise Refusal(body[item_pos] + 1, FLOW_REFUSAL)
            split_key_value(content)
            step_key_col = content_col
            j = self._step_key(job, step, body, item_pos, content_col, content, seen)
        else:
            nxt = self._next_non_blank(body, j)
            if nxt is None:
                raise Refusal(
                    body[item_pos] + 1,
                    "steps: item is not a step mapping — refusing rather than guessing",
                )
            nxt_indent = self._indent(body[nxt])
            nxt_text = self._body(body[nxt])
            if nxt_indent <= item_col or starts_item(nxt_text):
                raise Refusal(
                    body[item_pos] + 1,
                    "steps: item is not a step mapping — refusing rather than guessing",
                )
            step_key_col = nxt_indent
            j = nxt
        while j < len(body):
            index = body[j]
            if is_blank(self.lines[index]):
                j += 1
                continue
            text = self._body(index)
            indent = self._indent(index)
            if starts_item(text):
                break
            if indent < item_col:
                break
            if step_key_col is None:
                if indent <= item_col:
                    break
                step_key_col = indent
            if indent != step_key_col:
                raise Refusal(index + 1, UNCONSUMED_REFUSAL)
            j = self._step_key(job, step, body, j, step_key_col, text, seen)
        if step.run_line is not None:
            job.run_bodies.append(
                RunBody(
                    line=step.run_line,
                    step_line=step.step_line,
                    mentions_github_env=step.run_mentions_github_env,
                )
            )
        if step.kind:
            job.artifact_steps.append(step)
            self.artifact_step_lines.add(step.uses_line)
            if step.kind == "download":
                self._check_download(step)
        return j

    def _step_key(
        self,
        job: Job,
        step: ArtifactStep,
        body: list[int],
        pos: int,
        col: int,
        text: str,
        seen: dict[str, int],
    ) -> int:
        index = body[pos]
        if text.startswith("{"):
            raise Refusal(index + 1, FLOW_REFUSAL)
        key, value = self._kv(index, text)
        if key in seen:
            raise Refusal(
                index + 1,
                f"duplicate mapping key '{key}' in one step (lines {seen[key]} and {index + 1}) — "
                "remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
            )
        seen[key] = index + 1
        if key == "uses":
            _refuse_block_scalar_header(index, key, value)
            _refuse_non_string_value_tag(index, key, value)
            step.uses_line = index + 1
            step.kind = _artifact_action_kind(decode_scalar(value))
            return pos + 1 if value else self._consume_opaque(body, pos, col)
        if key == "with":
            if value:
                raise Refusal(
                    index + 1,
                    "'with:' must be a block mapping of input keys — refusing rather than guessing",
                )
            return self._parse_with(body, pos, col, step)
        if key == "env":
            end, step.env_range = self._consume_env_block(body, pos, col)
            return end
        if key == "run":
            step.run_line = index + 1
            end = pos + 1 if value else self._consume_opaque(body, pos, col)
            step.run_mentions_github_env = self._run_mentions_github_env(
                index, value, body, pos, end
            )
            return end
        return pos + 1 if value else self._consume_opaque(body, pos, col)

    def _run_mentions_github_env(
        self, index: int, value: str, body: list[int], pos: int, end: int
    ) -> bool:
        """The #339 scan for one `run:` step: a YAML-escape-decoded inline
        value, a block-scalar body (literal text, so not decoded), or the
        consumed continuation lines. A block-scalar header's body lives in
        `self.block_bodies` (the blanked lines no longer hold it); a bare
        `run:` with an indented plain scalar is (the raw lines of) the range
        `_consume_opaque` consumed. `_mentions_github_env` owns the mention
        predicate (the case-insensitive `github_env` substring plus the
        `GITHUB`/`ENV` window conjunction), so a YAML-escaped or
        shell-assembled name is caught."""
        if value:
            if _static_block_header(value) is not None:
                return _mentions_github_env(self.block_bodies.get(index + 1, ""))
            return _mentions_github_env(_decode_env_scalar(value))
        block_text = self.block_bodies.get(index + 1)
        if block_text is not None:
            return _mentions_github_env(block_text)
        return any(
            _mentions_github_env(self.lines[body[j]]) for j in range(pos + 1, end)
        )

    def _parse_with(self, body: list[int], pos: int, with_col: int, step: ArtifactStep) -> int:
        step.has_with = True
        j = pos + 1
        with_key_col: int | None = None
        seen: dict[str, int] = {}
        while j < len(body):
            index = body[j]
            if is_blank(self.lines[index]):
                j += 1
                continue
            text = self._body(index)
            indent = self._indent(index)
            if starts_item(text):
                break
            if with_key_col is None:
                if indent <= with_col:
                    break
                with_key_col = indent
            if indent < with_key_col:
                break
            if indent > with_key_col:
                raise Refusal(index + 1, UNCONSUMED_REFUSAL)
            if text.startswith("{"):
                raise Refusal(index + 1, FLOW_REFUSAL)
            key, value = self._kv(index, text)
            if key in seen:
                target = "with.name" if key == "name" else f"with.{key}"
                raise Refusal(
                    index + 1,
                    f"duplicate '{target}' (lines {seen[key]} and {index + 1}) — "
                    "remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
                )
            seen[key] = index + 1
            if key in ("name", "run-id", "github-token", "pattern", "artifact-ids"):
                _refuse_non_string_value_tag(index, key, value)
            if key == "name":
                _refuse_block_scalar_header(index, key, value)
                step.name = decode_scalar(value)
                step.name_line = index + 1
                step.name_is_literal = bool(step.name) and "${{" not in step.name
                j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
                continue
            if key == "run-id":
                _refuse_block_scalar_header(index, key, value)
                step.run_id = decode_scalar(value)
                step.run_id_line = index + 1
                j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
                continue
            if key == "github-token":
                # The token decides whether `run-id:` is honored at all
                # (actions/download-artifact only sets its run filter when the
                # token input is non-empty), so it is a semantic key too: a
                # block scalar here must not be mistaken for a present token.
                # A plain null spelling is the empty string at runtime
                # (#334-BLOCKER-2). The membership test is on the RAW text,
                # before decoding: a quoted `"null"` / `'null'` is the
                # literal text and stays non-empty, and `!!str null` decodes
                # to `null` only after the raw spelling has already failed to
                # match.
                _refuse_block_scalar_header(index, key, value)
                step.github_token = (
                    "" if value.strip() in YAML_NULL_SPELLINGS else decode_scalar(value)
                )
                step.github_token_line = index + 1
                step.has_github_token = bool(js_trim(step.github_token))
                j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
                continue
            if key == "pattern":
                _refuse_block_scalar_header(index, key, value)
                step.has_pattern = True
                step.pattern_line = index + 1
                j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
                continue
            if key == "artifact-ids":
                _refuse_block_scalar_header(index, key, value)
                step.has_artifact_ids = True
                step.artifact_ids_line = index + 1
                j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
                continue
            j = j + 1 if value else self._consume_opaque(body, j, with_key_col)
        return j

    def _check_download(self, step: ArtifactStep) -> None:
        """Download-step refusals that do not need the producer index."""
        if step.has_pattern:
            raise Refusal(
                step.pattern_line or step.uses_line,
                "'pattern:' on an artifact download — only one literal 'name:' can be "
                "resolved to a producer (refusing rather than guessing)",
            )
        if step.has_artifact_ids:
            raise Refusal(
                step.artifact_ids_line or step.uses_line,
                "'artifact-ids:' on an artifact download — only one literal 'name:' can be "
                "resolved to a producer (refusing rather than guessing)",
            )
        if not step.name:
            raise Refusal(
                step.uses_line,
                "download step has no 'name:' — set a literal artifact name so its producer can be resolved",
            )
        if not step.name_is_literal:
            raise Refusal(
                step.name_line or step.uses_line,
                f"download step's 'name:' is not a literal ('{step.name}') — a templated name "
                "cannot be resolved to a producer (refusing rather than guessing)",
            )
        if step.run_id is None:
            return
        stripped = js_trim(step.run_id)
        if not stripped:
            raise Refusal(
                step.run_id_line or step.uses_line,
                "empty 'run-id:' — a download with a run-id must name a run",
            )
        if _is_parseint_literal(stripped):
            # A cross-run run-id is only honored with a non-empty
            # github-token; without it the action downloads from the current
            # run, so the exclusion must not apply.
            step.run_id_cross_run = step.has_github_token
            return
        expression = _extract_expression(stripped)
        if expression is not None:
            normalized = re.sub(r"[\s'\"]", "", expression).lower()
            if SAME_RUN_RE.search(normalized):
                return  # same run: the rule applies
            if CROSS_RUN_RE.match(normalized):
                step.run_id_cross_run = step.has_github_token
                return
        raise Refusal(
            step.run_id_line or step.uses_line,
            f"unrecognized 'run-id:' value ('{stripped}') — recognized forms are a literal integer, "
            "${{ env.NAME }}, ${{ github.event.workflow_run.id }}, or the same-run "
            "${{ github.run_id }} (refusing rather than guessing)",
        )


def _artifact_action_kind(value: str) -> str:
    folded = value.strip().lower()
    if folded.startswith(UPLOAD_ACTION):
        return "upload"
    if folded.startswith(DOWNLOAD_ACTION):
        return "download"
    return ""


def _extract_expression(value: str) -> str | None:
    """Return the inside of a single `${{ ... }}` value, else None."""
    text = value.strip()
    if not text.startswith("${{") or not text.endswith("}}"):
        return None
    return text[3:-2]


# ECMAScript String.prototype.trim removes WhiteSpace + LineTerminator — the
# 25 code points below, measured by a full code-point sweep against the
# runner's own engine (node). This is NOT Python's str.strip(), which keeps
# U+FEFF and additionally removes U+001C-U+001F/U+0085. The token predicate
# must mirror what `@actions/core`'s `getInput` does to the value, because
# `actions/download-artifact` honors `run-id:` only when the trimmed token
# is non-empty (#335 Family B).
_JS_TRIM_CHARS = (
    "\t\n\v\f\r "
    "\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a"
    "\u2028\u2029\u202f\u205f\u3000\ufeff"
)


def js_trim(value: str) -> str:
    """`value` as `@actions/core`'s `getInput` sees it (ECMAScript trim)."""
    return value.strip(_JS_TRIM_CHARS)


def _is_parseint_literal(value: str) -> bool:
    """True when `parseInt(value)` yields a number from a literal integer
    prefix (the caller has already applied `js_trim`). A `0x`/`0X` prefix
    selects base 16 and needs at least one hex digit, otherwise the value is
    `NaN` and the cross-run handoff cannot be honored; without the prefix,
    the longest leading run of ASCII digits is the `parseInt` result."""
    if value[:2] in ("0x", "0X"):
        return PARSEINT_HEX_PREFIX_RE.match(value) is not None
    return PARSEINT_PREFIX_RE.match(value) is not None


# The #339 shell-assembly window: a `run:` body can build the env-file name
# from pieces (`n="GITHUB_""ENV"`, a `bash -c` argv), so a case-sensitive
# `GITHUB`/`ENV` conjunction inside this many characters counts as a mention
# even without the literal `GITHUB_ENV` substring.
GITHUB_ENV_WINDOW = 64


def _mentions_github_env(text: str) -> bool:
    """The #339 mention test for one decoded `run:` scalar or block body.
    The case-insensitive `github_env` substring closes `$GITHUB_ENV`,
    `${GITHUB_ENV}`, a Windows `%github_env%` and every spelling whose text
    carries the joined name; the case-sensitive `GITHUB`/`ENV` conjunction
    inside a 64-character window closes shell-level name assembly
    (`n="GITHUB_""ENV"`, `bash -c ... "GITHUB_""ENV"`). A name whose pieces
    are not both present in the text (base64/hex-encoded, read from a file,
    or produced by a called script) is the documented boundary of a
    text-based detector."""
    if "github_env" in text.lower():
        return True
    start = text.find("GITHUB")
    while start != -1:
        if "ENV" in text[start + len("GITHUB") : start + GITHUB_ENV_WINDOW]:
            return True
        start = text.find("GITHUB", start + 1)
    return False


# Plain YAML null spellings (YAML 1.2 core schema: `null`, `Null`, `NULL`,
# `~`). An `env:` value spelled this way is the empty string at runtime, so it
# must not classify as a present token (R6-BLOCKER-1). A quoted `"~"` /
# `"null"` is the literal text and stays non-empty. `NULL_TAG_SPELLINGS` are
# the explicit null tags (`!!null`, `!<tag:yaml.org,2002:null>`): the public
# `@actions/workflow-parser` compiles them to `StringToken("")` too, so the
# tag text must not classify as a present token either (R7-BLOCKER-1).
YAML_NULL_SPELLINGS = ("~", "null", "Null", "NULL")
NULL_TAG_SPELLINGS = ("!!null", "!<tag:yaml.org,2002:null>")

# The YAML double-quoted escape set (`\0` `\a` `\b` `\t` `\n` `\v` `\f`
# `\r` `\e` `\ ` `\"` `\/` `\\` `\N` `\_` `\L` `\P`). `\x`/`\u`/`\U`
# are handled separately because they carry hex digits.
_YAML_ESCAPES = {
    "0": "\0",
    "a": "\x07",
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "v": "\v",
    "f": "\f",
    "r": "\r",
    "e": "\x1b",
    " ": " ",
    '"': '"',
    "/": "/",
    "\\": "\\",
    "N": "\x85",
    "_": "\xa0",
    "L": "\u2028",
    "P": "\u2029",
}
_YAML_HEX_ESCAPES = {"x": 2, "u": 4, "U": 8}
_HEX_DIGITS = "0123456789abcdefABCDEF"


def _decode_double_quoted(text: str) -> str:
    """Decode a YAML double-quoted scalar with the full escape set. Only the
    null-tag argument needs this: `!!null "\\x6eull"` decodes to `null`, so
    the tag resolves it to the empty string at runtime — the subset reader in
    `decode_scalar` leaves the escape as literal text and would read the value
    as present (R8-BLOCKER-1)."""
    out: list[str] = []
    i = 1
    while i < len(text):
        c = text[i]
        if c == '"':
            break
        if c != "\\" or i + 1 >= len(text):
            out.append(c)
            i += 1
            continue
        escape = text[i + 1]
        length = _YAML_HEX_ESCAPES.get(escape)
        if length is not None:
            digits = text[i + 2 : i + 2 + length]
            if len(digits) == length and all(ch in _HEX_DIGITS for ch in digits):
                code = int(digits, 16)
                if code <= 0x10FFFF:
                    out.append(chr(code))
                    i += 2 + length
                    continue
            out.append(escape)
            i += 2
            continue
        out.append(_YAML_ESCAPES.get(escape, escape))
        i += 2
    return "".join(out)


def _decode_scalar_argument(argument: str) -> str:
    """The decoded scalar content of a tag argument. A leading anchor is a
    node property (`!!null &a 'null'` is the same node as `!!null 'null'` and
    `!!null &a` is the empty scalar), and a double-quoted scalar is decoded
    with the full YAML escape set so a QUOTED or ESCAPED null spelling
    compares equal to the plain one (R8-BLOCKER-1, R8-BLOCKER-2)."""
    text = _strip_anchor(argument.strip())
    if not text:
        return ""
    if text[0] == '"':
        return _decode_double_quoted(text)
    return decode_scalar(text)


def _null_tag_value(text: str) -> str | None:
    """The empty string when `text` is a null-tagged scalar that is empty at
    runtime (R7-BLOCKER-1, R8-BLOCKER-1), else None. A null tag with an EMPTY
    argument (`!!null`, `!!null ""`, `!!null ~`, `!!null null` — every null
    spelling), a QUOTED null spelling (`'null'`, `"~"`, `'Null'`), an
    escape-decoded null spelling (`"\\x6eull"`), or an anchored null spelling
    (`&a null`) is empty; a null tag with a non-null argument (`!!null foo`,
    `!!null 'ghp_x'`) is that string at runtime, not empty, so it falls
    through to the literal reader."""
    tag = _leading_tag(text)
    if tag not in NULL_TAG_SPELLINGS:
        return None
    argument = _decode_scalar_argument(text[len(tag) :])
    if not argument or argument in YAML_NULL_SPELLINGS:
        return ""
    return None


def _decode_env_scalar(text: str) -> str:
    """The runtime string of a static `env:` value's scalar. Node properties
    (a `!!str` tag, an anchor) do not change the value, so they are skipped;
    a double-quoted scalar is decoded with the FULL YAML escape set — the
    same `_decode_double_quoted` the tag-argument path already uses — because
    `"\\x20"`, `"\\u0020"` and `"\\_"` are whitespace at runtime, and reading
    them as literal text made an empty token look present (#335 Family A).
    A plain or single-quoted scalar has no escapes, so `decode_scalar`'s
    subset reader is exact for it."""
    stripped = _strip_node_properties(text)
    if stripped.startswith('"'):
        return _decode_double_quoted(stripped)
    return decode_scalar(text)


def _static_env_value(
    raw: str,
    line: int,
    block_bodies: dict[int, str],
    continuation: tuple[int, str] | None,
) -> str:
    """The runtime value of a static `env:` assignment. A block-scalar header
    — with or without a tag or anchor — is not the value: the body is, so an
    empty body is the empty string and a non-empty body is its text
    (R6-BLOCKER-1, R8-BLOCKER-1). A plain YAML null is the empty string too,
    and a null-tagged scalar with a null argument is empty as well
    (R7-BLOCKER-1). A non-string tag is resolved the way the runner resolves
    it: the runtime value is the string form of the tag's resolved value
    (falling back to the raw argument text when the tag does not resolve), and
    an absent argument is the empty string — so `!!int ""`, `!!bool ""`, bare
    `!!int` and `!foo ""` are all empty at runtime (#334-BLOCKER-1). When the
    tag's value continues on a following more-indented line the continuation
    is the value (`continuation` is its 1-based line and text): a block
    header resolves through its captured body (an empty body is `""`), a
    quoted or plain scalar is decoded, and a continuation that is itself
    tagged (`!!int` + `!!str ""`) is runtime-invalid ("A node can have at
    most one tag") so it is read by its text and stays accepted
    (#334 continuation resolution). Anything else is the decoded scalar.

    Branch order is part of the contract: `_null_tag_value` must run before
    the generic non-string-tag branch, because a null tag coerces a QUOTED or
    escaped null spelling (`!!null 'null'`, `!!null "\\x6eull"`) to the empty
    string, which the generic branch would read as the literal text `null`.
    """
    text = raw.strip()
    if _static_block_header(text) is not None:
        return block_bodies.get(line, "")
    if text in YAML_NULL_SPELLINGS:
        return ""
    tagged = _null_tag_value(text)
    if tagged is not None:
        return tagged
    tag = _leading_tag(text)
    if tag is not None and not _is_string_tag(tag):
        if continuation is None:
            return _decode_scalar_argument(text[len(tag) :])
        continuation_line, continuation_text = continuation
        cont_text = continuation_text.strip()
        if _leading_tag(cont_text) is not None:
            # A continuation that is itself tagged is runtime-invalid ("A
            # node can have at most one tag"); read it by its text and stay
            # accepted, matching the runtime-invalid-tagged-values stance.
            return cont_text
        if _static_block_header(cont_text) is not None:
            return block_bodies.get(continuation_line, "")
        return _decode_scalar_argument(cont_text)
    return _decode_env_scalar(text)


def _static_env_has_name(
    static_env: dict[str, list[tuple[str, int]]], name: str
) -> bool:
    """True when the file-wide static `env:` index has an assignment for
    `name`: exact case first, then any case variant. Resolution uses the
    exact-case index only (actions/runner's `env` context is
    `StringComparer.Ordinal` on non-Windows runners, R6-BLOCKER-2); the
    case-variant check feeds the diagnostic for a name that is empty at
    runtime because of the mismatch (R6-NIT-1)."""
    if name in static_env:
        return True
    folded = name.lower()
    return any(candidate.lower() == folded for candidate in static_env)


def _collect_static_env(
    lines: list[str], block_bodies: dict[int, str]
) -> dict[str, list[tuple[str, int]]]:
    """Index static `env:` assignments (workflow-, job- and step-level) so a
    `run-id:`/`github-token: ${{ env.NAME }}` can be resolved against the same
    file (B3). Names are matched **case-sensitively**: actions/runner's `env`
    context is `CaseSensitiveDictionaryContextData` with
    `StringComparer.Ordinal` on non-Windows runners (this repo runs
    macOS/ubuntu), so a case-variant assignment is unset at runtime and must
    not resolve (R6-BLOCKER-2). A block-scalar header is not the value — an
    empty body is the empty string — and a plain YAML null is empty too
    (R6-BLOCKER-1). A BARE key (`GH_TOKEN:`) is indexed as the empty string
    rather than skipped so the most specific scope still shadows an outer
    assignment (R7-BLOCKER-2). Values written to `$GITHUB_ENV` at runtime are invisible
    here and stay unresolved. The index is file-wide; callers scope it to a
    step's visible env chain with `_scoped_static_env` (R5-MINOR-1)."""
    index: dict[str, list[tuple[str, int]]] = {}
    env_columns: list[int] = []
    for number, line in enumerate(lines, start=1):
        if is_blank(line):
            continue
        indent = indent_of(line)
        stripped = line[indent:]
        prefix = 0
        item = re.match(r"^-\s+", stripped)
        if item:
            prefix = item.end()
        rest = stripped[prefix:]
        key_col = indent + prefix
        while env_columns and key_col <= env_columns[-1]:
            env_columns.pop()
        kv = split_key_value(rest)
        if kv is None:
            continue
        key, value, kind = kv
        key = _decode_key(key, kind)
        if key == "env" and not value:
            env_columns.append(key_col)
            continue
        if env_columns:
            # A value whose plain scalar continues on the next more-indented
            # line is not the tag's own argument: the runtime value is the
            # continuation. Detect it here (the next non-blank line's
            # indentation vs. this key's column) and pass its 1-based line and
            # text so `_static_env_value` resolves a block header through its
            # captured body and any other continuation through its decoded
            # text (#334 continuation resolution).
            continuation: tuple[int, str] | None = None
            for offset, following in enumerate(lines[number:], start=number + 1):
                if is_blank(following):
                    continue
                if indent_of(following) > key_col:
                    continuation = (offset, following)
                break
            # A bare key, a `#`-only value and an empty quoted string are all
            # the empty string at runtime, and the most specific scope must
            # still shadow an outer assignment: indexing only truthy raw
            # values let the outer literal leak through (R7-BLOCKER-2).
            index.setdefault(key, []).append(
                (
                    _static_env_value(value, number, block_bodies, continuation),
                    number,
                )
            )
    return index


def _static_env_case_variant(
    static_env: dict[str, list[tuple[str, int]]], name: str
) -> str | None:
    """The file-wide assignment name that differs from `name` only in case,
    or None when `name` is assigned exactly or has no case variant. Feeds the
    case-mismatch wording of the unresolved run-id refusal (R7-NIT-1)."""
    if name in static_env:
        return None
    folded = name.lower()
    for candidate in static_env:
        if candidate.lower() == folded:
            return candidate
    return None


def _scoped_static_env(
    static_env: dict[str, list[tuple[str, int]]],
    scopes: list[tuple[int, int]],
) -> dict[str, list[tuple[str, int]]]:
    """Restrict the file-wide static `env:` index to the blocks a step can
    actually see and apply scope precedence (R5-MINOR-1, R6-MINOR-1): `scopes`
    is ordered most specific first (step -> job -> workflow), and the most
    specific scope that assigns a name wins, so a legal step-level override is
    one effective value instead of a set union. GitHub's `env` context for a
    step is that chain plus `$GITHUB_ENV` writes, so an assignment on another
    job or on another step is invisible at runtime and proves nothing."""
    if not scopes:
        return {}
    scoped: dict[str, list[tuple[str, int]]] = {}
    for name, entries in static_env.items():
        for low, high in scopes:
            visible = [
                (value, line) for value, line in entries if low <= line <= high
            ]
            if visible:
                scoped[name] = visible
                break
    return scoped


def _env_reference(value: str) -> str | None:
    """The `env.NAME` a value references (case preserved), or None. Used to
    tell the documented runtime-written form (no static assignment anywhere)
    from an assignment that exists but is not visible to this step under the
    exact name the value references."""
    expression = _extract_expression(value)
    if expression is None:
        return None
    compact = _compact_expression(expression)
    if compact.lower().startswith("env."):
        return compact[4:]
    return None


def _compact_expression(value: str) -> str:
    """An expression body with whitespace and quotes removed, case preserved
    (the `env` context lookup is case-sensitive, R6-BLOCKER-2)."""
    return re.sub(r"[\s'\"]", "", value)


def _classify_env_name(
    name: str,
    static_env: dict[str, list[tuple[str, int]]],
    seen: set[str],
) -> str:
    if name in seen:
        return "unknown"
    entries = static_env.get(name)
    if not entries:
        return "unresolved"
    results = {
        _classify_static_value(assigned, static_env, seen | {name}) for assigned, _line in entries
    }
    if "same-run" in results:
        return "same-run"
    if "unknown" in results:
        return "unknown"
    if "cross-run" in results:
        return "cross-run"
    return "unresolved"


def _classify_static_value(
    value: str,
    static_env: dict[str, list[tuple[str, int]]],
    seen: set[str],
) -> str:
    """Classify a statically assigned value: 'same-run', 'cross-run',
    'unresolved' (no static assignment) or 'unknown' (static, but neither)."""
    text = js_trim(value)
    if not text:
        return "unknown"
    if _is_parseint_literal(text):
        return "cross-run"
    expression = _extract_expression(text)
    if expression is None:
        return "unknown"
    compact = _compact_expression(expression)
    normalized = compact.lower()
    if SAME_RUN_RE.search(normalized):
        return "same-run"
    if CROSS_RUN_RE.match(normalized):
        if normalized.startswith("env."):
            return _classify_env_name(compact[4:], static_env, seen)
        return "cross-run"
    return "unknown"


def _classify_token_value(
    value: str,
    static_env: dict[str, list[tuple[str, int]]],
    seen: set[str],
) -> str:
    """Classify a `github-token:` value for action runtime emptiness:
    'present' (provably non-empty), 'empty' (statically empty), or 'unknown'
    (an expression the gate cannot prove non-empty). `@actions/core` trims
    the input and actions/download-artifact honors `run-id:` only when the
    token is set, so anything not provably non-empty must not exclude.

    Only two expression forms are provably non-empty: `github.token` and the
    exact `secrets.GITHUB_TOKEN` (R5-MINOR-2). Any other `secrets.*` may name
    an unset secret, and any expression carrying an operator (`&&`, `||`,
    `??`) may evaluate to the empty string, so both are 'unknown' (refused
    rather than excluded)."""
    text = js_trim(value)
    if not text:
        return "empty"
    expression = _extract_expression(text)
    if expression is None:
        return "present"
    compact = _compact_expression(expression)
    normalized = compact.lower()
    if normalized == "github.token" or normalized == "secrets.github_token":
        return "present"
    if normalized.startswith("env."):
        name = compact[4:]
        if name in seen:
            return "unknown"
        entries = static_env.get(name)
        if not entries:
            return "unknown"
        results = {
            _classify_token_value(assigned, static_env, seen | {name})
            for assigned, _line in entries
        }
        if len(results) == 1:
            return results.pop()
        return "unknown"
    return "unknown"


def _env_chain_names(
    value: str,
    static_env: dict[str, list[tuple[str, int]]],
    seen: set[str] | None = None,
) -> list[str]:
    """Every `env.NAME` link a value's static chain references, in walk
    order. Mirrors the classifiers' transitive walk so the #341 case check
    sees the same names; a chain cycle stops at the repeated name."""
    if seen is None:
        seen = set()
    expression = _extract_expression(js_trim(value))
    if expression is None:
        return []
    compact = _compact_expression(expression)
    if not compact.lower().startswith("env."):
        return []
    name = compact[4:]
    if name in seen:
        return [name]
    seen = seen | {name}
    names = [name]
    for assigned, _line in static_env.get(name, []):
        names.extend(_env_chain_names(assigned, static_env, seen))
    return names


def _env_case_candidates(
    name: str,
    static_env: dict[str, list[tuple[str, int]]],
    scopes: list[tuple[int, int]],
) -> list[tuple[str, int, int]]:
    """Every visible case-variant of `name` (including `name` itself) as
    `(key, assignment_line, scope_index)`, discovered with BOTH Python folds
    so the pairs neither fold alone sees stay visible (`'\u017f'.upper() ==
    'S'` but `'\u017f'.lower() == '\u017f'`; `'\u212a'.lower() == 'k'` but
    `'\u212a'.upper() == '\u212a'`). `scope_index` is most-specific first."""
    found: list[tuple[str, int, int]] = []
    for scope_index, (low, high) in enumerate(scopes):
        for key, entries in static_env.items():
            if key != name and not (
                key.upper() == name.upper() or key.lower() == name.lower()
            ):
                continue
            for _assigned, line in entries:
                if low <= line <= high:
                    found.append((key, line, scope_index))
    return found


def _refuse_env_case_collision(
    label: str,
    value: str,
    source_line: int,
    name: str,
    static_env: dict[str, list[tuple[str, int]]],
    scopes: list[tuple[int, int]],
) -> None:
    """#341: refuse when a Windows runner would resolve `name` to a different
    assignment than the exact-case lookup here. A Windows runner's `env`
    context is `OrdinalIgnoreCase` (last-wins), so a case-colliding mapping
    can leave the runtime token empty (or the run-id same-run) while the gate
    keeps the cross-run exclusion. The predicate is the winning assignment of
    the merged visible chain: actions/runner seeds the job environment with
    the workflow then the job `env:` mapping and merges the step's own `env:`
    LAST, all under one `OrdinalIgnoreCase` comparer, so the winner is the
    assignment from the most-specific scope, and the last line within a
    scope; the download is refused when that winner is not `name`. A name the
    gate cannot prove non-ASCII-safe refuses with its own diagnostic, because
    the exact `OrdinalIgnoreCase` folding is not modelled (`lower()`/`upper()`
    each miss a pair). The exact-case name must be assigned somewhere in the
    visible chain — when only a case-variant exists, the pre-existing
    case-mismatch/unresolved diagnostics own the shape."""
    candidates = _env_case_candidates(name, static_env, scopes)
    if not candidates:
        return
    if not any(candidate[0] == name for candidate in candidates):
        return
    if not name.isascii():
        raise Refusal(
            source_line,
            f"{label}: '{value}' resolves through `env.{name}`, a non-ASCII env name whose "
            "Windows `OrdinalIgnoreCase` folding is not modelled — the runtime may resolve a "
            "different value, so the cross-run exclusion cannot be proven (refusing rather "
            "than guessing)",
        )
    non_ascii = [c for c in candidates if not c[0].isascii()]
    if non_ascii:
        variant, variant_line, _scope = non_ascii[0]
        raise Refusal(
            source_line,
            f"{label}: '{value}' resolves through `env.{name}`, which has a non-ASCII case-"
            f"variant `env.{variant}` (line {variant_line}) whose Windows `OrdinalIgnoreCase` "
            "folding is not modelled — the runtime may resolve a different value, so the "
            "cross-run exclusion cannot be proven (refusing rather than guessing)",
        )
    # `scopes` is most-specific first (step, job, workflow); the runner merges
    # them least-specific first (workflow, then job, then step), so the merged
    # winner is the candidate in the most-specific scope with the last line.
    winner_key, winner_line, _scope = max(candidates, key=lambda c: (-c[2], c[1]))
    if winner_key == name:
        return
    raise Refusal(
        source_line,
        f"{label}: '{value}' resolves through `env.{name}`, and the case-variant assignment "
        f"`env.{winner_key}` (line {winner_line}) wins under a Windows runner's case-"
        "insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a "
        "different value, so the cross-run exclusion cannot be proven (refusing rather than "
        "guessing)",
    )


def _refuse_github_env_token_mention(job: Job, step: ArtifactStep) -> None:
    """#339: a preceding `run:` step in the same job whose body mentions
    `$GITHUB_ENV` can change or empty any token that resolves through the
    static `env:` chain — actions/runner merges `$GITHUB_ENV` writes into the
    job's environment before a later step's `with:` is evaluated — so the
    cross-run exclusion cannot be proven and the download is refused. The
    detector is the raw `GITHUB_ENV` substring, not a name extraction
    (measured leaky: single `>`, `tee`, heredocs, indirect names): a
    read-only `cat "$GITHUB_ENV"`, an unrelated-name write, a same-value
    rewrite and a write shadowed by the step's own `env:` all refuse too
    (accepted fail-closed costs, documented in the header). Position is the
    step's START line, so a write in the download's own step or in a later
    step proves nothing, and the scan is per job because `$GITHUB_ENV`
    writes live in the job's global environment."""
    if step.github_token is None or _env_reference(step.github_token) is None:
        return
    mention = next(
        (
            body
            for body in job.run_bodies
            if body.mentions_github_env and body.step_line < step.uses_line
        ),
        None,
    )
    if mention is None:
        return
    raise Refusal(
        step.github_token_line or step.uses_line,
        f"github-token: '{step.github_token}' resolves through the `env` context, and a "
        f"preceding step in this job writes to `$GITHUB_ENV` (line {mention.line}) — that "
        "write can change or empty the value at runtime, so the cross-run exclusion cannot "
        "be proven (refusing rather than guessing)",
    )


def _unresolved_env_link(
    name: str,
    scoped_env: dict[str, list[tuple[str, int]]],
    seen: set[str] | None = None,
) -> str | None:
    """The first `env.NAME` link in a static `env:` chain that this step's env
    scope cannot resolve — its exact name has no in-scope assignment, so the
    value is empty or runtime-written at runtime — or None when every link
    resolves (R6-NIT-1). Names are matched exactly: actions/runner's `env`
    context is case-sensitive on non-Windows runners, so a case-variant
    assignment is invisible at runtime (R6-BLOCKER-2)."""
    if seen is None:
        seen = set()
    if name in seen:
        return name
    seen = seen | {name}
    entries = scoped_env.get(name)
    if not entries:
        return name
    for assigned, _line in entries:
        expression = _extract_expression(assigned)
        if expression is None:
            continue
        compact = _compact_expression(expression)
        if compact.lower().startswith("env."):
            link = _unresolved_env_link(compact[4:], scoped_env, seen)
            if link is not None:
                return link
    return None


def _apply_static_env_run_id_resolution(
    jobs: list[Job],
    lines: list[str],
    workflow_env_range: tuple[int, int] | None,
    block_bodies: dict[int, str],
) -> None:
    """Resolve every cross-run-classified `run-id:` against the static `env:`
    index **scoped to the step's visible env chain** (workflow + enclosing job
    + the step's own `env:`, most specific first): a same-run assignment turns
    the cross-run exclusion off (so the rule applies), and a static value the
    gate cannot classify is refused rather than excluded (B3). An assignment
    that is not visible to the step under the exact name it references (a
    different job/step, or a name that differs only in case) is empty at
    runtime, so it proves nothing — the token is refused and a `run-id:` whose
    only assignments are elsewhere is refused too (R5-MINOR-1, R6-BLOCKER-2).
    The `github-token:` that the exclusion depends on is classified the same
    way: a statically empty in-scope token (including an empty block-scalar
    body or a plain YAML null, R6-BLOCKER-1) is absent (the rule applies) and
    one the gate cannot prove non-empty is refused. A token that resolves
    through the `env` context is additionally refused when a preceding step
    in the same job mentions `$GITHUB_ENV` (#339): that write can change or
    empty the token before the action reads it."""
    static_env = _collect_static_env(lines, block_bodies)
    for job in jobs:
        for step in job.artifact_steps:
            if not step.run_id_cross_run or step.run_id is None:
                continue
            scopes = [
                entry
                for entry in (step.env_range, job.env_range, workflow_env_range)
                if entry is not None
            ]
            scoped_env = _scoped_static_env(static_env, scopes)
            for name in _env_chain_names(step.run_id, scoped_env):
                _refuse_env_case_collision(
                    "run-id",
                    step.run_id,
                    step.run_id_line or step.uses_line,
                    name,
                    static_env,
                    scopes,
                )
            if step.github_token is not None:
                for name in _env_chain_names(step.github_token, scoped_env):
                    _refuse_env_case_collision(
                        "github-token",
                        step.github_token,
                        step.github_token_line or step.uses_line,
                        name,
                        static_env,
                        scopes,
                    )
            resolution = _classify_static_value(step.run_id, scoped_env, set())
            if resolution == "same-run":
                step.run_id_cross_run = False
                continue
            if resolution == "unknown":
                raise Refusal(
                    step.run_id_line or step.uses_line,
                    f"run-id: '{step.run_id}' resolves through a static assignment in this file to "
                    "a value that is neither the current run nor a recognized cross-run handoff "
                    "(refusing rather than guessing)",
                )
            if resolution == "unresolved":
                # Two cases: no static assignment anywhere (the documented
                # runtime `$GITHUB_ENV` handoff — the real ios-adhoc-pr.yml
                # shape — which keeps the cross-run exclusion), or a static
                # assignment that is not visible to this step under the exact
                # name it references (another job/step, or a name that differs
                # only in case). The second is an authoring error the gate
                # must not read as a proven cross-run handoff. The diagnostic
                # names the first unresolved link, which for a chained value is
                # the transitive `env.NAME` and not the in-scope reference
                # (R6-NIT-1).
                name = _env_reference(step.run_id)
                link = (
                    _unresolved_env_link(name, scoped_env)
                    if name is not None
                    else None
                )
                if link is not None and (
                    _static_env_has_name(static_env, link)
                    or _static_env_has_name(static_env, name)
                ):
                    variant = _static_env_case_variant(static_env, link)
                    if variant is not None:
                        raise Refusal(
                            step.run_id_line or step.uses_line,
                            f"run-id: '{step.run_id}' resolves through `env.{link}`, which is "
                            f"assigned only under a different case (`env.{variant}`) — the `env` "
                            "context lookup is case-sensitive on non-Windows runners, so the value "
                            "is empty at runtime and a cross-run handoff cannot be proven "
                            "(refusing rather than guessing)",
                        )
                    if link == name:
                        raise Refusal(
                            step.run_id_line or step.uses_line,
                            f"run-id: '{step.run_id}' resolves through a static `env:` assignment "
                            "that is outside this step's env scope (only the workflow-level, the "
                            "enclosing job's and the step's own `env:` are visible at runtime) — the "
                            "value is empty or runtime-written, so a cross-run handoff cannot be "
                            "proven (refusing rather than guessing)",
                        )
                    if _static_env_has_name(static_env, link):
                        raise Refusal(
                            step.run_id_line or step.uses_line,
                            f"run-id: '{step.run_id}' resolves through `env.{link}`, a static "
                            "`env:` assignment that is outside this step's env scope (only the "
                            "workflow-level, the enclosing job's and the step's own `env:` are "
                            "visible at runtime) — the value is empty or runtime-written, so a "
                            "cross-run handoff cannot be proven (refusing rather than guessing)",
                        )
                    raise Refusal(
                        step.run_id_line or step.uses_line,
                        f"run-id: '{step.run_id}' resolves through `env.{link}`, which has no "
                        "static `env:` assignment in this file — the value is runtime-written or "
                        "empty, so a cross-run handoff cannot be proven (refusing rather than "
                        "guessing)",
                    )
            if step.github_token is None:
                # No token at all: the parse-time gating already decided the
                # exclusion, and there is nothing to classify.
                continue
            if _extract_expression(step.github_token) is None:
                # A literal token's emptiness was decided when it was read
                # (whitespace-only is absent); only an expression can resolve
                # to an empty or unprovable runtime value.
                continue
            token = _classify_token_value(step.github_token, scoped_env, set())
            if token == "present":
                _refuse_github_env_token_mention(job, step)
                continue
            if token == "empty":
                step.has_github_token = False
                step.run_id_cross_run = False
                continue
            raise Refusal(
                step.github_token_line or step.uses_line,
                f"github-token: '{step.github_token}' cannot be proven non-empty at runtime — "
                "actions/download-artifact honors `run-id:` only when the token input is set; use "
                "a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` "
                "and add the `needs:` edge (refusing rather than guessing)",
            )


def _parse_inline_needs(line: int, value: str) -> list[str]:
    # The string tag resolves to the same scalar GitHub reads, so a tagged
    # flow collection (`needs: !!str [build]`) is a valid edge and must be
    # parsed as a collection (R5-NIT-1). A non-string tag is refused by the
    # caller rather than read as part of the name.
    text = _strip_str_tag(value.strip())
    if text.startswith("["):
        if not text.endswith("]"):
            raise Refusal(
                line,
                "'needs:' flow sequence must close on its own line — refusing rather than guessing",
            )
        inner = text[1:-1].strip()
        if not inner:
            return []
        names: list[str] = []
        for raw in inner.split(","):
            item = raw.strip()
            if not item:
                continue
            if item[0] in ("&", "*", "{", "["):
                raise Refusal(line, ANCHOR_REFUSAL)
            names.append(decode_scalar(item))
        return names
    return [decode_scalar(text)]


# ---------------------------------------------------------------------------
# Reconciliation
# ---------------------------------------------------------------------------


def _token_only_in_mapping_key(line: str) -> bool:
    """True when every artifact-action token on the line sits in a mapping
    key (`upload-artifact:` / `"upload-artifact":`). A mapping key is never a
    step's `uses:` value and steps are sequence entries, so such a line cannot
    be an unmodelled artifact step (m1). A token in a value keeps the line
    reconciled."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
    if not stripped:
        return False
    kv = split_key_value(stripped)
    if kv is None:
        return False
    key, value, kind = kv
    if not ARTIFACT_TOKEN_RE.search(_decode_key(key, kind)):
        return False
    return not ARTIFACT_TOKEN_RE.search(decode_scalar(value))


def _is_action_reference_line(line: str) -> bool:
    """True when the line can be an artifact action reference the parser did
    not model: a `uses:` key line whose value carries an artifact token (the
    key is case-folded and any spelling counts: `uses:`, `"uses":`,
    `uses :`), or any line carrying the action-ref shape (`-artifact@ref`).
    A bare token — a job id, a `needs:` item, an `if:` operand — is a label,
    not a step, and is exempt (round-3 fold)."""
    if ACTION_REF_RE.search(line):
        return True
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
    if not stripped:
        return False
    kv = split_key_value(stripped)
    if kv is None:
        return False
    key, value, kind = kv
    if _decode_key(key, kind).lower() != "uses":
        return False
    return bool(ARTIFACT_TOKEN_RE.search(decode_scalar(value)))


def reconcile(lines: list[str], artifact_step_lines: set[int]) -> list[tuple[int, str]]:
    diagnostics: list[tuple[int, str]] = []
    for index, line in enumerate(lines, start=1):
        if is_blank(line):
            continue
        if index in artifact_step_lines:
            continue
        if not _is_action_reference_line(line):
            continue
        if _token_only_in_mapping_key(line):
            continue
        diagnostics.append(
            (
                index,
                "artifact action token not parsed as an artifact step — a construct the parser "
                "cannot fully model must not pass (reconciliation failed)",
            )
        )
    return diagnostics


# ---------------------------------------------------------------------------
# File / root scan
# ---------------------------------------------------------------------------


def process_file(relpath: str, raw: bytes) -> FileResult:
    result = FileResult(relpath=relpath)
    raw_lines = normalize_text(raw)
    try:
        lines = blank_comments(raw_lines)
        lines, block_bodies = blank_block_scalars(lines, raw_lines)
        for index, line in enumerate(lines, start=1):
            if is_blank(line):
                continue
            leading = re.match(r"^[ \t]*", line)
            if leading and "\t" in leading.group(0):
                raise Refusal(
                    index,
                    "tab in indentation — YAML forbids tabs for indentation; use spaces",
                )
        semantic_lines = semantic_value_lines(lines)
        for index, line in enumerate(lines, start=1):
            if is_blank(line):
                continue
            message = unterminated_quote_violation(line)
            if message:
                raise Refusal(index, message)
            message = quoted_escape_violation(line, index in semantic_lines)
            if message:
                raise Refusal(index, message)
            message = scalar_construct_violation(line)
            if message:
                raise Refusal(index, message)
        parser = WorkflowParser(relpath, lines, block_bodies)
        result.jobs = parser.parse()
        reconciliation = reconcile(
            blank_non_semantic_name_values(blank_run_and_env_values(lines)),
            parser.artifact_step_lines,
        )
        if reconciliation:
            result.diagnostics.extend(reconciliation)
            return result
        _apply_static_env_run_id_resolution(
            result.jobs, lines, parser.workflow_env_range, block_bodies
        )
        for job in result.jobs:
            for step in job.artifact_steps:
                if step.kind == "upload":
                    result.uploads += 1
                else:
                    result.downloads += 1
                    if step.run_id_cross_run:
                        result.excluded += 1
        producers: dict[str, list[tuple[str, int]]] = {}
        for job in result.jobs:
            for step in job.artifact_steps:
                if step.kind == "upload" and step.name_is_literal and step.name:
                    producers.setdefault(step.name, []).append(
                        (job.name, step.name_line or step.uses_line)
                    )
        for name, entries in sorted(producers.items()):
            if len(entries) > 1:
                (first_job, first_line), (second_job, second_line) = entries[0], entries[1]
                raise Refusal(
                    second_line,
                    f"artifact name '{name}' is uploaded more than once (job '{first_job}' line "
                    f"{first_line}, job '{second_job}' line {second_line}) — upload-artifact v4 "
                    "requires artifact names to be unique per run",
                )
        return result
    except Refusal as refusal:
        result.diagnostics.append((refusal.line, refusal.message))
        return result


def _collect_workflow_files(root: Path) -> tuple[Path, list[Path]]:
    directory = root / WORKFLOWS_RELPATH
    files: list[Path] = []
    if directory.is_dir():
        seen: set[str] = set()
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.suffix in (".yml", ".yaml") and str(path) not in seen:
                seen.add(str(path))
                files.append(path)
    files.sort()
    return directory, files


def scan_root(root: Path, enforce_floor: bool = True) -> ScanResult:
    result = ScanResult()
    directory, files = _collect_workflow_files(root)
    if not files:
        result.diagnostics.append(
            f"no workflow files found under {WORKFLOWS_RELPATH} — refusing rather than passing a "
            "typo'd --root (expected .github/workflows/*.yml)"
        )
        return result
    if enforce_floor and len(files) < MIN_SCANNED_WORKFLOW_FILES:
        result.diagnostics.append(
            f"scan floor: only {len(files)} workflow file(s) found under {WORKFLOWS_RELPATH}; the "
            f"floor is {MIN_SCANNED_WORKFLOW_FILES} — update the floor constant only if workflows "
            "were intentionally removed (refusing rather than passing a truncated tree)"
        )
        return result
    result.summary.append(
        f"artifact-dependency gate: scanning {len(files)} workflow file(s) under {WORKFLOWS_RELPATH}"
    )
    file_results: list[FileResult] = []
    for path in files:
        relpath = str(path.relative_to(directory))
        file_result = process_file(relpath, path.read_bytes())
        file_results.append(file_result)
        for line, message in file_result.diagnostics:
            result.diagnostics.append(f"{relpath}:{line}: {message}")
    # Global producer index for cross-file diagnostics: artifacts are
    # run-scoped, so a name whose only producer lives in another file cannot
    # satisfy a `needs:` path in this file.
    global_producers: dict[str, list[tuple[str, str]]] = {}
    for file_result in file_results:
        if file_result.diagnostics:
            continue
        for job in file_result.jobs:
            for step in job.artifact_steps:
                if step.kind == "upload" and step.name_is_literal and step.name:
                    global_producers.setdefault(step.name, []).append(
                        (file_result.relpath, job.name)
                    )
    for file_result in file_results:
        if file_result.diagnostics:
            result.summary.append(
                "  " + file_result.relpath + ": refused (see diagnostics above)"
            )
            continue
        result.checked_downloads += sum(
            1
            for job in file_result.jobs
            for step in job.artifact_steps
            if step.kind == "download" and not step.run_id_cross_run
        )
        result.summary.append(
            "  "
            + file_result.relpath
            + f": {file_result.uploads} upload(s), {file_result.downloads} download(s)"
            + (f" ({file_result.excluded} cross-run run-id: excluded)" if file_result.excluded else "")
        )
        result.diagnostics.extend(_evaluate_rules(file_result, global_producers))
    return result


def _evaluate_rules(
    file_result: FileResult, global_producers: dict[str, list[tuple[str, str]]]
) -> list[str]:
    diagnostics: list[str] = []
    per_file_producers: dict[str, tuple[str, int]] = {}
    for job in file_result.jobs:
        for step in job.artifact_steps:
            if step.kind == "upload" and step.name_is_literal and step.name:
                per_file_producers[step.name] = (job.name, step.uses_line)
    needs_map = {job.name: list(job.needs) for job in file_result.jobs}
    closures: dict[str, set[str]] = {}

    def closure(job_name: str) -> set[str]:
        if job_name in closures:
            return closures[job_name]
        seen: set[str] = set()
        stack = list(needs_map.get(job_name, []))
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            stack.extend(needs_map.get(current, []))
        closures[job_name] = seen
        return seen

    for job in file_result.jobs:
        for step in job.artifact_steps:
            if step.kind != "download" or step.run_id_cross_run:
                continue
            name = step.name or ""
            producer_entry = per_file_producers.get(name)
            if producer_entry is None:
                others = [
                    entry
                    for entry in global_producers.get(name, [])
                    if entry[0] != file_result.relpath
                ]
                if others:
                    other_file, other_job = others[0]
                    diagnostics.append(
                        f"{file_result.relpath}:{step.uses_line}: {job.name} downloads artifact "
                        f'"{name}" but no needs: path reaches its producer "{other_job}" — the '
                        f"producer is in {other_file}, not this workflow ({RUN_SCOPED_SUFFIX})"
                    )
                else:
                    diagnostics.append(
                        f"{file_result.relpath}:{step.uses_line}: {job.name} downloads artifact "
                        f'"{name}" but no job in this workflow uploads that literal name '
                        f"({RUN_SCOPED_SUFFIX})"
                    )
                continue
            producer, producer_line = producer_entry
            if producer == job.name:
                if producer_line < step.uses_line:
                    continue
                diagnostics.append(
                    f"{file_result.relpath}:{step.uses_line}: {job.name} downloads artifact "
                    f'"{name}" before its own upload step (line {producer_line}) — a job\'s steps run '
                    "in source order; move the upload step earlier"
                )
                continue
            if producer not in closure(job.name):
                diagnostics.append(
                    f"{file_result.relpath}:{step.uses_line}: {job.name} downloads artifact "
                    f'"{name}" but no needs: path reaches its producer "{producer}" — add '
                    f"`needs: {producer}` to the `{job.name}` job"
                )
    return diagnostics


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------


def _load_manifest():
    if not MANIFEST_PATH.is_file():
        raise SystemExit(f"selftest: manifest not found at {MANIFEST_PATH}")
    spec = importlib.util.spec_from_file_location("artifact_dependency_manifest", MANIFEST_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_selftest() -> int:
    manifest = _load_manifest()
    cases = list(manifest.CASES)
    if len(cases) != EXPECTED_MANIFEST_CASES:
        print(
            f"selftest: FAIL — manifest has {len(cases)} case(s), the stated constant is "
            f"{EXPECTED_MANIFEST_CASES}; update the constant AND the Swift pin, or restore the case(s)"
        )
        return 1
    referenced: set[str] = set()
    for case in cases:
        referenced.update(case["files"])
    on_disk = {p.name for p in FIXTURES_DIR.glob("*.yml")} | {
        p.name for p in FIXTURES_DIR.glob("*.yaml")
    }
    unreferenced = sorted(on_disk - referenced)
    if unreferenced:
        print(f"selftest: FAIL — unreferenced fixture file(s): {', '.join(unreferenced)}")
        return 1
    failures: list[str] = []
    started = time.monotonic()
    for case in cases:
        case_id = case["id"]
        tempdir = Path(tempfile.mkdtemp(prefix="artifact-dependency-selftest."))
        try:
            workflows = tempdir / WORKFLOWS_RELPATH
            workflows.mkdir(parents=True)
            for filename in case["files"]:
                source = FIXTURES_DIR / filename
                if not source.is_file():
                    failures.append(f"{case_id}: fixture file missing: {filename}")
                    break
                shutil.copyfile(source, workflows / filename)
            else:
                scan = scan_root(tempdir, enforce_floor=case.get("floor", False))
                actual_lines = list(scan.diagnostics)
                expected_exit = int(case["exit"])
                actual_exit = 1 if scan.diagnostics else 0
                if actual_exit != expected_exit or actual_lines != list(case["diagnostics"]):
                    failures.append(
                        f"{case_id}: expected exit {expected_exit} with "
                        f"{len(case['diagnostics'])} diagnostic(s), got exit {actual_exit} with "
                        f"{len(actual_lines)}:\n    expected: "
                        + "\n    expected: ".join(case["diagnostics"])
                        + (
                            "\n    actual:   " + "\n    actual:   ".join(actual_lines)
                            if actual_lines
                            else "\n    actual:   <none>"
                        )
                    )
        finally:
            shutil.rmtree(tempdir, ignore_errors=True)
    elapsed = time.monotonic() - started
    if failures:
        for failure in failures:
            print(f"selftest: {failure}")
        print(f"selftest: {len(cases) - len(failures)}/{len(cases)} cases (FAIL)")
        return 1
    print(f"selftest: {len(cases)}/{len(cases)} cases ({elapsed:.2f}s)")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Fail-closed artifact-dependency gate (issue #316)."
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root to scan (default: the repo containing this script).",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Run the fixture manifest and exit; does not scan a tree.",
    )
    args = parser.parse_args(argv)
    if args.selftest:
        return run_selftest()
    root = Path(args.root).resolve()
    started = time.monotonic()
    result = scan_root(root, enforce_floor=True)
    elapsed = time.monotonic() - started
    for line in result.summary:
        print(line)
    for diagnostic in result.diagnostics:
        print(diagnostic)
    if result.diagnostics:
        print(
            f"artifact-dependency gate: FAIL — {len(result.diagnostics)} refusal(s)/violation(s) "
            f"({elapsed:.2f}s); see the file:line diagnostics above"
        )
        return 1
    print(
        f"artifact-dependency gate: OK — {result.checked_downloads} in-workflow download(s) checked, "
        f"0 refusals ({elapsed:.2f}s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
