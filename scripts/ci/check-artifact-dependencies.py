#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""check-artifact-dependencies.py — artifact-dependency gate (issue #316).

RULE
----
Every in-workflow artifact downloader must have a `needs:` path to the job
that uploads the artifact it downloads. Artifacts are run-scoped, so the
producer must be in the same workflow file; the only exclusion is a
recognized cross-run `run-id:` handoff (e.g. `${{ env.SOURCE_RUN_ID }}`).
A `run-id:` that the same file statically assigns the current run's id is
NOT a cross-run handoff: it is same-run, so the rule still applies.

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
  * reconciliation: every line in the blanked text matching an artifact
    action token must be a parsed artifact step, so a construct the parser
    failed to model can never pass;
  * a scan floor so a typo'd `--root` cannot masquerade as a pass.

Refusals include: tabs in indentation; an unterminated quoted scalar; a
backslash escape in a double-quoted scalar that only YAML's full decoder
resolves (`\\uXXXX`, `\\xXX`, …); a block-scalar header as the value of a
semantic key (step `uses`; job `needs`; `with.name`, `with.run-id`,
`with.pattern`, `with.artifact-ids`); `{`/`&`/`*`/`<<` in a parsed position;
duplicate mapping keys; duplicate `steps:`; duplicate `with.name`; a `uses:`
job that also has `steps:`; `pattern:`/`artifact-ids:`; a download without a
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
cross-run exclusion; static in-file `env:` assignments are resolved, and one
the gate cannot classify is refused. Reconciliation deliberately skips
single-line `run:` bodies and `env:` values (they are data, not steps), so
an artifact-action token there is not a refusal; in any other scalar (e.g. a
step `name:`) it still is. Multi-document streams, U+2028/U+2029 line
breaks, `%YAML` directives, a mid-file BOM and `!!` tags are outside the
subset grammar and unverified against GitHub's parser.

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
EXPECTED_MANIFEST_CASES = 73

# The scan floor. A typo'd `--root` (or a truncated checkout) must not look
# like a pass; update this constant only when workflows are intentionally
# removed (and then update the pin suite too).
MIN_SCANNED_WORKFLOW_FILES = 12

UPLOAD_ACTION = "actions/upload-artifact"
DOWNLOAD_ACTION = "actions/download-artifact"
ARTIFACT_TOKEN_RE = re.compile(r"(?:upload|download)-artifact", re.IGNORECASE)
BLOCK_HEADER_RE = re.compile(r"^(?:[|>][+-]?\d*|[|>]\d*[+-]?)$")
LITERAL_INT_RE = re.compile(r"^\d+$")
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
    name: str | None = None
    name_line: int | None = None
    name_is_literal: bool = False
    run_id: str | None = None
    run_id_line: int | None = None
    run_id_cross_run: bool = False
    has_pattern: bool = False
    pattern_line: int | None = None
    has_artifact_ids: bool = False
    artifact_ids_line: int | None = None
    has_with: bool = False


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


def split_key_value(s: str) -> tuple[str, str, str] | None:
    """Split `key: value` at the start of `s` (no leading whitespace).

    Returns `(key_text, value_text, kind)` where kind is `plain` or
    `quoted`, or None when `s` is not a mapping entry."""
    if not s:
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
    value = value.strip()
    if not value:
        return ""
    if value[0] in ("'", '"'):
        _, decoded = _scan_quoted(value, 0)
        return decoded
    return value


def unterminated_quote_violation(line: str) -> str | None:
    """Return a refusal message when a quoted scalar opened at a scalar-start
    position does not close on its own line. The same-line policy is what
    kills the multi-line quoted scalar that would otherwise fabricate a
    `needs:` edge (plan B2). Runs after block-scalar blanking, so an
    unbalanced `'` in a `run: |` shell body is opaque text."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
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


def quoted_escape_violation(line: str) -> str | None:
    """Refuse a double-quoted scalar at a key or value position that uses an
    escape outside the decoder's set. Runs after the unterminated-quote check
    (which names an unclosed scalar more precisely) and after block-scalar
    blanking (so shell bodies stay opaque)."""
    stripped = line.lstrip(" ")
    if starts_item(stripped):
        stripped = stripped[1:].lstrip(" ")
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
            if value.startswith('"'):
                return _escaped_quoted_scalar_violation(value, 0)
        return None
    kv = split_key_value(stripped)
    if kv is None:
        return None
    _, value, _ = kv
    if value.startswith('"'):
        return _escaped_quoted_scalar_violation(value, 0)
    return None


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
        key, value, _ = kv
        key = decode_scalar(key)
        if key == "env" and not value:
            env_columns.append(key_col)
            continue
        if key == "run" or (env_columns and value):
            out[index] = " " * len(line)
    return out


def blank_block_scalars(lines: list[str]) -> list[str]:
    """Blank block-scalar bodies (full header grammar `[|>][+-]?\\d*` /
    `[|>]\\d*[+-]?`). A body line is any subsequent line indented deeper than
    the key whose value is the scalar; the scalar ends when a line dedents to
    or above that key."""
    out = list(lines)
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
        if not BLOCK_HEADER_RE.match(value):
            continue
        key_indent = indent + prefix
        j = i + 1
        while j < len(out):
            body = out[j]
            if is_blank(body):
                out[j] = ""
                j += 1
                continue
            if indent_of(body) > key_indent:
                out[j] = ""
                j += 1
                continue
            break
    return out


# ---------------------------------------------------------------------------
# Workflow parser
# ---------------------------------------------------------------------------


def _refuse_block_scalar_header(index: int, key: str, value: str) -> None:
    """A block-scalar header where a semantic key's value belongs would make
    the gate read the header as the value while the real value is blanked
    (B2), so it is a refusal, not an opaque scalar."""
    if BLOCK_HEADER_RE.match(value):
        raise Refusal(
            index + 1,
            f"block scalar header '{value}' as the value of '{key}:' — this key decides the artifact "
            "graph and must be an inline scalar (refusing rather than guessing the folded value)",
        )


class WorkflowParser:
    def __init__(self, relpath: str, lines: list[str]) -> None:
        self.relpath = relpath
        self.lines = lines
        self.jobs: list[Job] = []
        self.artifact_step_lines: set[int] = set()

    # -- small helpers -----------------------------------------------------

    def _indent(self, index: int) -> int:
        return indent_of(self.lines[index])

    def _body(self, index: int) -> str:
        return self.lines[index][self._indent(index) :]

    def _kv(self, index: int, text: str) -> tuple[str, str]:
        kv = split_key_value(text)
        if kv is None:
            raise Refusal(index + 1, UNCONSUMED_REFUSAL)
        key, value, _ = kv
        return decode_scalar(key), value

    def _next_non_blank(self, body: list[int], start: int) -> int | None:
        for i in range(start, len(body)):
            if not is_blank(self.lines[body[i]]):
                return i
        return None

    # -- top level ---------------------------------------------------------

    def parse(self) -> list[Job]:
        self._scan_top_level_duplicates()
        jobs_index = self._find_jobs_key()
        end = self._jobs_region_end(jobs_index)
        self._parse_job_region(list(range(jobs_index + 1, end)), jobs_index + 1)
        return self.jobs

    def _top_level_keys(self) -> list[tuple[str, int]]:
        keys: list[tuple[str, int]] = []
        for index, line in enumerate(self.lines):
            if is_blank(line) or self._indent(index) != 0:
                continue
            kv = split_key_value(line)
            if kv is None:
                continue
            keys.append((decode_scalar(kv[0]), index + 1))
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
            if key == "needs":
                _refuse_block_scalar_header(index, key, value)
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
        step = ArtifactStep(kind="", uses_line=0)
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
        return pos + 1 if value else self._consume_opaque(body, pos, col)

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
        stripped = step.run_id.strip()
        if not stripped:
            raise Refusal(
                step.run_id_line or step.uses_line,
                "empty 'run-id:' — a download with a run-id must name a run",
            )
        if LITERAL_INT_RE.match(stripped):
            step.run_id_cross_run = True
            return
        expression = _extract_expression(stripped)
        if expression is not None:
            normalized = re.sub(r"[\s'\"]", "", expression).lower()
            if SAME_RUN_RE.search(normalized):
                return  # same run: the rule applies
            if CROSS_RUN_RE.match(normalized):
                step.run_id_cross_run = True
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


def _collect_static_env(lines: list[str]) -> dict[str, list[tuple[str, int]]]:
    """Index static `env:` assignments (workflow-, job- and step-level) so a
    `run-id: ${{ env.NAME }}` can be resolved against the same file (B3).
    Names are matched case-insensitively (fail-closed: a case variant must not
    launder a same-run value). Values written to `$GITHUB_ENV` at runtime are
    invisible here and stay unresolved."""
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
        key, value, _ = kv
        key = decode_scalar(key)
        if key == "env" and not value:
            env_columns.append(key_col)
            continue
        if env_columns and value:
            index.setdefault(key.lower(), []).append((decode_scalar(value), number))
    return index


def _normalize_expression(value: str) -> str:
    return re.sub(r"[\s'\"]", "", value).lower()


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
    text = value.strip()
    if not text:
        return "unknown"
    if LITERAL_INT_RE.match(text):
        return "cross-run"
    expression = _extract_expression(text)
    if expression is None:
        return "unknown"
    normalized = _normalize_expression(expression)
    if SAME_RUN_RE.search(normalized):
        return "same-run"
    if CROSS_RUN_RE.match(normalized):
        if normalized.startswith("env."):
            return _classify_env_name(normalized[4:], static_env, seen)
        return "cross-run"
    return "unknown"


def _apply_static_env_run_id_resolution(jobs: list[Job], lines: list[str]) -> None:
    """Resolve every cross-run-classified `run-id:` against the file's static
    `env:` index: a same-run assignment turns the cross-run exclusion off (so
    the rule applies), and a static value the gate cannot classify is refused
    rather than excluded (B3)."""
    static_env = _collect_static_env(lines)
    for job in jobs:
        for step in job.artifact_steps:
            if not step.run_id_cross_run or step.run_id is None:
                continue
            resolution = _classify_static_value(step.run_id, static_env, set())
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


def _parse_inline_needs(line: int, value: str) -> list[str]:
    text = value.strip()
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


def reconcile(lines: list[str], artifact_step_lines: set[int]) -> list[tuple[int, str]]:
    diagnostics: list[tuple[int, str]] = []
    for index, line in enumerate(lines, start=1):
        if is_blank(line):
            continue
        if ARTIFACT_TOKEN_RE.search(line) and index not in artifact_step_lines:
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
    lines = normalize_text(raw)
    try:
        lines = blank_comments(lines)
        lines = blank_block_scalars(lines)
        for index, line in enumerate(lines, start=1):
            if is_blank(line):
                continue
            leading = re.match(r"^[ \t]*", line)
            if leading and "\t" in leading.group(0):
                raise Refusal(
                    index,
                    "tab in indentation — YAML forbids tabs for indentation; use spaces",
                )
        for index, line in enumerate(lines, start=1):
            if is_blank(line):
                continue
            message = unterminated_quote_violation(line)
            if message:
                raise Refusal(index, message)
            message = quoted_escape_violation(line)
            if message:
                raise Refusal(index, message)
            message = scalar_construct_violation(line)
            if message:
                raise Refusal(index, message)
        parser = WorkflowParser(relpath, lines)
        result.jobs = parser.parse()
        reconciliation = reconcile(blank_run_and_env_values(lines), parser.artifact_step_lines)
        if reconciliation:
            result.diagnostics.extend(reconciliation)
            return result
        _apply_static_env_run_id_resolution(result.jobs, lines)
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
