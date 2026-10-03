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
`ios-adhoc-pr.yml` shape) cannot be resolved statically; it keeps the
cross-run exclusion only when every preceding same-job `$GITHUB_ENV` write of
a name it resolves through is value-aware proven cross-run (the #342 rule
below) — static in-file `env:` assignments are resolved, and one
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
reds are documented rather than modelled, and a fourth Python-`strip()` site
is left the same way: `_extract_expression` strips a `run-id:`/`env:` value
with `value.strip()` before its `${{ … }}` fence check, so a plain raw
U+0085/U+001C-prefixed EXPRESSION is resolved as if unprefixed although
ECMAScript keeps the prefix: a same-run expression then refuses without a
`needs:` edge, while a cross-run expression keeps the exclusion and the
runtime `parseInt` is `NaN` (a 404, not a same-run fallback) —
correctness-only either way, not a fail-open; a
Windows runner's `env` context is
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
an unrelated-name write, a same-value rewrite, a write shadowed by the
download step's own `env:`, a write inside a step that `if:` skips or a
function that is never called (dead code is refused, not reasoned about),
and a body that only places `GITHUB` and `ENV`
within 64 characters without writing the env file
(`echo "$GITHUB_ACTIONS" > "$ENV_FILE"`) all refuse (accepted costs, each
pinned or named); in the last case the "writes to `$GITHUB_ENV`" diagnostic
is an unobserved assertion, which is accepted rather than narrowing the
detector — softening the diagnostic is deferred. A `uses:`/composite action
that writes `$GITHUB_ENV` stays invisible, and a name assembled from pieces not both present in the body's
text (shell-level hex/base64 assembly, read from a file, or produced by a
called script) is not detected — the documented boundary of a text-based
detector.

THE RUN-ID `$GITHUB_ENV` WRITE RULE (#342)
-------------------------------------------
The invariant that closes this class rather than its instances has two
halves. The first: every shell construct the run-id write depends on must
be fully modelled, and anything the extractor cannot model refuses rather
than guessing — never "the last assignment wins" when the resolution is
ambiguous. The second is DETECTION COMPLETENESS: for every traced name (a
flip target, an alias, a body assignment, or a redirect-target variable),
every occurrence of that name as a shell word in a preceding same-job body
must be accounted for by the model — a modelled assignment, a classified
redirect target, an extracted env-write payload, an `export NAME` marker,
or a test command's read operand. An occurrence the model cannot account
for refuses, so a write mechanism whose spelling no mechanism table lists
still refuses because it names the variable (`mapfile -t n`, `readarray -t
n`, `read 'NAME[0]'`, `eval 'read NAME'`, `eval 'printf -v NAME …'`,
`declare -n ref=NAME`, `let NAME=…`, `(( NAME=… ))`, `NAME[0]=…`, and an
assembled carrier string). The refusals
cover the branch-dependent (`&&`/`||`/`|` lists, including a `||` that
continues across a physical line), prefix-position, multi-assignment,
unset, indirect, nested/group-assignment, cross-step, and
line-continuation cases, plus the unmodelled variable-writing mechanisms
and carriers named in `_UNMODELLED_WRITE_VERBS` (`read`/`mapfile`/
`readarray`, `printf -v`, `declare`/`local`/`typeset`/`readonly`, `unset`,
`getopts`, `for`/`select` loop variables, and the command strings of
`trap`/`eval`/`bash -c`/`sh -c`): when such a mechanism names a variable
the rule traces (a flip target, an alias, an assignment, or a redirect
target), the download refuses. The mechanisms this text extractor still
does not see are the named residuals at the end of this section. The #339
rule above is token-chain-only, because a
name-blind rule is measurably wrong: it refuses the real `ios-adhoc-pr.yml`
`workflow_run.id` handoff at the writing step's `run:` line. The run-id
chain therefore gets a VALUE-AWARE rule (`_refuse_github_env_run_id_write`),
gated on `_env_reference(step.run_id)`: a direct `run-id:` expression cannot
be affected by an env-file write and is a no-op here.

Flip-target names are the chain head plus every `env.` link, minus any name
the download step's own `env:` assigns (a step's own `env:` wins over a
`$GITHUB_ENV` write, so such a write cannot flip it). A workflow- or
job-level `A: ${{ env.B }}` link is frozen at job start, so refusing a write
of `B` there is a fail-closed over-approximation; a step-level link
genuinely re-evaluates per step, so writing its target is a real flip.
Names are matched case-insensitively (the #341 Windows `OrdinalIgnoreCase`
stance) and a non-ASCII written name refuses. A write of a flip-target name
keeps the exclusion only when its value is provably cross-run under
`_classify_static_value`'s own predicates (`${{ github.event.workflow_run.id }}`,
`inputs.*`, `vars.*`, an in-chain `env.*` link that classifies
cross-run, or a `parseInt` literal); `${{ github.run_id }}`, an empty value,
a command substitution, `needs.*.outputs.*`, or any other unclassifiable
value refuses. A value that is a body-local `${NAME}`/`$NAME` expansion is
traced in program order: every statement-position `NAME=VALUE` on every
body line (`;`, `&&`, `||`, `|`, `&` separated, `export` allowed) is indexed
with its column, and the reaching assignment is the last one STRICTLY
before the write's expansion position — a command-prefix assignment in the
write's own segment (`n=/tmp/foo echo … >> "$n"`) is expanded with the
previous value, so it does not count; a later same-line reassignment is
visible, and a same-line reassignment after the write is after it. A
statement reached only through an `&&`/`||`/`|` list — on the same line or
on a physical line that continues one — is indexed as conditional and a
trace that reaches it refuses: the assignment may never execute, so the
value is ambiguous (`m=1; n="$GITHUB_ENV" || n=/tmp/foo` then `>> "$n"`
writes the env file at runtime while the dead-code trace reads `other`).
A statement that runs in a subshell is indexed the same way: the left side
of a `|`/`|&` pipeline, the command of a `&` background list, and an
assignment inside a `$( … )` command substitution carried across physical
lines never propagate to the parent shell that runs the write, so a trace
that reaches one refuses rather than reading the dead assignment (issue
#342, F2; a single-line `( … )` group is refused by the out-of-statement
detector instead).
Unset-at-write, a reassignment after the write, `+=`, an assignment inside
a nested control block, and an unclassifiable RHS all refuse. This is the rule that keeps the real
`${CI_RUN_ID}` -> `${{ inputs.ci_run_id }}` dispatch branch green while
refusing a guarded same-run local.

The write scan is PER LINE, not a body-level count: every line that
references the env file must be part of an extractable, classified write,
so one unrelated extractable write cannot launder a second, missed same-run
write (`tee`, `dd of=`, `sed -i`, `sponge`, `cp`/`mv`, a `cat >`/`cat >>`
without a heredoc payload, a `bash -c` argv, a redirect target the extractor
cannot resolve such as `$(…)`, `${!n}` or an unassigned expansion, an
unextractable payload or NAME, or a read-only `cat "$GITHUB_ENV"` all
refuse: accepted fail-closed costs of an extractor that would rather refuse
than guess). The redirect grammar models `>&word` (with a non-digit,
non-`-` word this is bash's omitted-fd stdout+stderr file redirect, so the
word is a redirect target; `>&1`/`>&-` stay fd duplications/closures),
`>|word` (a plain file redirect), and `<>word` with the fd number
immediately prefixing it (or bash's `{name}<>` dynamic allocation, which
picks a fd above 10): an explicit fd > 0 is a read-write payload
target that must resolve, while a bare `<>` (fd 0) opens stdin read-write
and provably does not write the payload, so it stays accepted. A physical
line that ends in an unescaped backslash continuation after a redirection
operator refuses, because the shell joins the next line into that command
and the redirect target (`>& \\` + newline + `"$n"`) can sit there outside
the per-line view; a continuation after a plain word (a `printf … \\`
argument split), after a `#` comment, or inside a quoted-heredoc payload is
not a redirect split and stays accepted (issue #342, F1). An unterminated
heredoc is the exception: when a line inside it ends in a continuation —
the would-be delimiter (`EOF \\`) is the common shape — bash never sees the
delimiter and consumes the rest of the body as heredoc text (`here-document
… delimited by end-of-file`), so no later line executes and the body
refuses rather than reading a swallowed write as shell (fold-6 MINOR-3). A
heredoc payload (`cat >> "$GITHUB_ENV" <<'EOF'`) is read as
literal env-file text, so its values are not shell-expanded. The env-file
spelling is exact, AND an unresolved target that extends it with identifier
characters is `unknown`, not `other`, so it
refuses: a preceding same-job step can write `GITHUB_ENV_X=$GITHUB_ENV` into
`$GITHUB_ENV`, and the runner merges that into the job environment before
the write, making the suffix name the env-file path. The genuine risk
spellings are the unquoted/braced names `$GITHUB_ENVx`/`${GITHUB_ENVx}`
and the identifier chain `$GITHUB_ENV_X`; the tokenizer also joins the
quoted concatenation `"$GITHUB_ENV"x` into one word and refuses it, but in
bash that expansion is `<env-path>x` — a different file — so that quoted
shape is a benign fail-closed false red. The alias-suffix
family (`n="$GITHUB_ENV"; … >> "$n.bak"` / `>> "${n}_x"`) refuses too —
the alias resolves to the env spelling before the literal suffix — a
documented fail-closed false red, as is the direct `$GITHUB_ENV_X`
same-run shape (the runner publishes the path only as `GITHUB_ENV` /
`%GITHUB_ENV%`, so the direct shape is a false red accepted because the
cross-step assignment cannot be ruled out). Branch identity is not
modelled: any control-flow closer between the traced assignment and the
write (`fi`, `else`, `elif`, `esac`, `;;`, `done`, `}`) is a boundary, so a
stale assignment in a non-executing branch refuses rather than being read
as reaching. The widened grammar also refuses legitimate constructs the
model cannot distinguish from a flip: a redirect to an unassigned variable
the body does not define (`>&"$LOGFILE"`, `>| "$LOGFILE"` with `LOGFILE`
in the job `env:`), an `if … fi` boundary between the traced assignment
and the write, `exec 3>&"$n"` (an ambiguous-redirect error in bash), any
assignment reached through an `&&`/`||`/`|` list even when the list
provably executes, an assignment inside a subshell context (`n=… &`,
`n=… | cat`, an assignment inside a cross-line `$( … )`; the cross-line
tracker closes with the substitution, so a later parent-shell assignment is
reaching again), a mechanism that names a traced
variable even when the body cannot reach it (a never-called function's
`declare -g`), a dynamic mechanism target (`read -r "$name"`, `declare
"$name=…"`, `printf -v "$name"`), a `for NAME in …`/`select NAME in …`
loop whose control variable is traced, and a traced-name occurrence the
detection-completeness walk cannot account for (`echo "$n"`, a bare
`NAME` argument, a `NAME=VALUE`-shaped word in an unmodelled command, a
carrier string that names the variable, and the read-only occurrences the
walk does not model — `case $NAME in`, `${NAME:-…}`, `${#NAME}`,
`${NAME%…}`, `command -v NAME`, `grep NAME`, `type NAME`, `hash NAME`,
`: NAME`, `true NAME`, `for x in "$NAME"`, every one measured to refuse
and none able to change the value; an `export NAME` marker is
accounted and does not refuse) — all fail-closed costs, as is the distinct
unresolved-redirect-target refusal, which names the target it cannot
resolve. The rule never
touches the #339 token rule, the `needs:` reconciliation, the case-collision
rule, or the trim/`parseInt` rules. Named residuals: a caller
(`workflow_call`) or dispatcher (`workflow_dispatch`) can pass its own
`github.run_id` as an `inputs.*` value (no `workflow_call` exists in this
repo, and trigger parsing is deliberately not modelled); a `$GITHUB_ENV`
write whose name pieces never appear in the body text
(`$RUNNER_TEMP/_runner_file_commands/set_env_*`, a name split past the
64-character window) is not detected, the inherited text-detector boundary;
and the write mechanisms and locations the extractor still does not see — a
`source`d or `.`-sourced script's body, a `bash script.sh` path (only the
`-c` string is inspected), a carrier whose command string is assembled
at runtime (`eval "$cmd"`: the carrier is seen, but a string that never
mentions the env file or a traced name is the inherited textual boundary),
and a `$GITHUB_ENV` write inside a `$( … )` command substitution (issue
#345): the substitution is one token, and when that token is a modelled
assignment RHS, an `echo`/`printf`/`cat` `NAME=VALUE` payload, a test
operand, an env-write payload word, or a `bash <<EOF` payload line, the
detection-completeness walk accounts the whole word and does not inspect
the substitution body; a segment that already has an env redirect also
skips the reference check. The name text is present, so this is a location
boundary, not the text-detector boundary.
The detection-completeness walk therefore closes the naming family the
mechanism tables enumerate, at the cost of refusing benign occurrences the
model does not place (see the accepted-costs paragraph); a construct whose
name text is absent or assembled at runtime stays outside it.
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
EXPECTED_MANIFEST_CASES = 343

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
    # The `run:` key line, the decoded body text, and the #339 mention flag
    # (a non-empty decoded body that mentions `GITHUB_ENV`; the predicate is
    # `_mentions_github_env`).
    run_line: int | None = None
    run_body_text: str = ""
    run_mentions_github_env: bool = False


@dataclass
class RunBody:
    """A parsed `run:` step's location, its decoded body text, and whether
    the body mentions `$GITHUB_ENV`. The mention predicate is
    `_mentions_github_env` (the decoded text's case-insensitive `github_env`
    substring plus a `GITHUB`/`ENV` window conjunction, because a name
    extraction is measurably leaky and the raw substring missed
    YAML-escaped/shell-assembled spellings), and the #342 write extractor
    reads the same `body_text` so the mention and the extraction cannot see
    different text."""

    line: int  # the `run:` key line
    step_line: int  # the enclosing step's first line
    mentions_github_env: bool
    body_text: str = ""


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
    # Downloads that kept the cross-run exclusion in files without
    # diagnostics. The selftest asserts a case's `"excluded"` count against
    # this so a vacuous accept (a download that never reached the cross-run
    # path) cannot pass (#342).
    excluded: int = 0


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
                    body_text=step.run_body_text,
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
            step.run_body_text = self._run_body_text(index, value, body, pos, end)
            step.run_mentions_github_env = _mentions_github_env(step.run_body_text)
            return end
        return pos + 1 if value else self._consume_opaque(body, pos, col)

    def _run_body_text(
        self, index: int, value: str, body: list[int], pos: int, end: int
    ) -> str:
        """The decoded `run:` body text: a YAML-escape-decoded inline value,
        a captured block-scalar body (literal text, so not decoded), or the
        consumed continuation lines joined with newlines. Both the #339
        mention (`_mentions_github_env`) and the #342 write extractor read
        this one string, so they cannot see different text. A block-scalar
        header's body lives in `self.block_bodies` (the blanked lines no
        longer hold it); a bare `run:` with an indented plain scalar is the
        range `_consume_opaque` consumed. Joining the continuation lines is
        the one-decode-path rule: a `GITHUB`/`ENV` window conjunction split
        across two raw lines is a mention (the pre-#342 scan applied the
        predicate per line)."""
        if value:
            if _static_block_header(value) is not None:
                return self.block_bodies.get(index + 1, "")
            return _decode_env_scalar(value)
        block_text = self.block_bodies.get(index + 1)
        if block_text is not None:
            return block_text
        return "\n".join(self.lines[body[j]] for j in range(pos + 1, end))

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
    detector (`_mentions_github_env`) is the decoded run text's
    case-insensitive `github_env` substring plus a case-sensitive
    `GITHUB`/`ENV` conjunction inside a 64-character window, not a name
    extraction (measured leaky: single `>`, `tee`, heredocs, indirect
    names, a YAML-escaped or shell-assembled name): a
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


# ---------------------------------------------------------------------------
# #342: value-aware classification of the `$GITHUB_ENV` writes that can flip an
# env-resolved `run-id:` from a cross-run handoff to the current run.
#
# `actions/download-artifact@v8` evaluates `run-id:` per step against the
# runtime `env` context, and actions/runner merges a `$GITHUB_ENV` write into
# the job environment before a later step's `with:` is evaluated. A preceding
# same-job `run:` step that writes the name an env-resolved `run-id:` resolves
# through therefore overrides the statically assigned / runtime handoff value,
# turning the download same-run while the gate keeps the cross-run exclusion.
# The #339 rule is token-chain-only; this rule closes the run-id chain.
#
# It is VALUE-AWARE: a name-blind mention rule measurably refuses the real
# `ios-adhoc-pr.yml` `workflow_run.id` handoff, so a write of a flip-target
# name is refused only when its value is not provably a cross-run handoff.
# The scan is PER LINE, not a body-level count: one unrelated extractable
# write must not launder a second, missed same-run write.
# ---------------------------------------------------------------------------

# A `NAME=VALUE` statement at the start of its line (`export` allowed).
_ENV_ALIAS_ASSIGNMENT_RE = re.compile(
    r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)="
)
# `NAME+=VALUE` is deliberately unmodelled: the trace refuses it rather than
# pretending the first assignment's classification governs.
_ENV_APPEND_ASSIGNMENT_RE = re.compile(
    r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)\+="
)
# A whole shell word that is exactly one local expansion (`${NAME}`/`$NAME`).
_LOCAL_REFERENCE_RE = re.compile(
    r"^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$"
)
# A heredoc operator plus its delimiter (`<<EOF`, `<<'EOF'`, `<<-EOF`).
_HEREDOC_RE = re.compile(
    r"<<-?[ \t]*(?:\"([^\"]*)\"|'([^']*)'|([A-Za-z_][A-Za-z0-9_]*))"
)
# The exact env-file spellings: actions/runner sets `GITHUB_ENV` (POSIX
# shells) / `%GITHUB_ENV%` (cmd) to the env-file path. A redirect target that
# is exactly one of these IS the env file; a spelling with extra text
# (`$GITHUB_ENV.bak`, `pre$GITHUB_ENV`) is a different file and must not
# count (issue #342). The `\b` after the unbraced name keeps a longer
# variable (`$GITHUB_ENV_X`) out.
_ENV_FILE_SPELLING_RE = re.compile(
    r"\$(?:\{GITHUB_ENV\}|GITHUB_ENV\b)|%GITHUB_ENV%", re.IGNORECASE
)
# Characters that make an alias assignment's right-hand side a command (or a
# redirection, or a compound statement) rather than a pure env-file
# spelling: `x=$(echo … >> "$GITHUB_ENV")` performs the write and must not
# be skipped as "the target-resolution mechanism" (issue #342).
_ALIAS_RHS_UNMODELLED_CHARS = ("$(", "`", ">", "<", ";", "|", "&")
# A control-flow branch/closer between a traced local's assignment and the
# write means the assignment may not have executed first (fail-closed).
_CONTROL_CLOSER_RE = re.compile(r"^(?:else|elif|fi|done|esac)\b")

# Unmodelled variable-writing mechanisms (issue #342, R4): bash writes a
# shell variable through each of these spellings, but the extractor's model
# is statement-position `NAME=VALUE` only. When one of them names a variable
# the run-id rule traces, the rule refuses rather than tracing through it.
# `bash`/`sh`/`zsh`/`dash`/`ksh` only count when invoked with `-c`; a
# script path is a named residual (its body is not in this file).
_UNMODELLED_WRITE_VERBS = (
    "read",
    "readarray",
    "mapfile",
    "declare",
    "local",
    "typeset",
    "readonly",
    "unset",
    "getopts",
    "printf",
    "for",
    "select",
    "trap",
    "eval",
    "bash",
    "sh",
    "zsh",
    "dash",
    "ksh",
)
# `read` options that consume the next word. `-a` is deliberately absent:
# its argument IS the array name that the rule must inspect.
_READ_OPTIONS_WITH_ARGUMENT = ("-d", "-i", "-n", "-N", "-p", "-t", "-u")
_ASSIGNMENT_OPERAND_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")
_ARRAY_OPERAND_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\[")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass
class _ShellAssignment:
    """One body-local `NAME=VALUE` statement. `value` is the first shell
    word after `=` (quotes removed), or None for an unmodelled statement
    (`NAME+=…`) or an unreadable RHS. `(index, column)` is the statement's
    position: the line and the 0-based byte offset of the assignment word,
    so a later same-line reassignment is ordered after an earlier one.
    `conditional` is True when the statement is reached only through an
    `&&`/`||`/`|` list (same line or a continued one): it may not have
    executed by the time the write runs, so a trace that reaches it
    refuses (issue #342, R1)."""

    name: str
    value: str | None
    index: int
    column: int
    indent: int
    conditional: bool = False


def _indent_width(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _consume_command_substitution(text: str, start: int) -> int:
    """The index just past the `$(…)` opened at `text[start:start + 2]`,
    with quotes, escapes and nested parentheses honoured; `len(text)` when
    the substitution is unclosed on the line (the caller's per-line scan
    refuses rather than guesses)."""
    n = len(text)
    depth = 1
    j = start + 2
    while j < n and depth:
        cj = text[j]
        if cj in "'\"":
            quote = cj
            j += 1
            while j < n and text[j] != quote:
                j += 1
            if j < n:
                j += 1
            continue
        if cj == "\\" and j + 1 < n:
            j += 2
            continue
        if cj == "(":
            depth += 1
        elif cj == ")":
            depth -= 1
        j += 1
    return j


def _shell_tokens(text: str) -> list[tuple[str, str, int, int]]:
    """Tokenise one shell command line for the #342 write extractor:
    `(kind, text, start, end)` with `kind` `"word"` or `"op"`. A word's
    quotes are removed and adjacent quoted pieces join (so
    `"GITHUB_""ENV"` is the single word `GITHUB_ENV`); `$` expansions,
    backticks and `$(…)` are kept verbatim. Operators are the command
    separators (`;`, `&&`, `||`, `|`, `&`) and the redirections (`<`, `<<`,
    `>`, `>>`, `<>`). This is a fail-closed subset of shell tokenisation, not
    a shell: anything the caller cannot model refuses rather than passes."""
    tokens: list[tuple[str, str, int, int]] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in " \t":
            i += 1
            continue
        if c == "#":
            break
        if c in ";&|":
            if i + 1 < n and text[i + 1] == c:
                tokens.append(("op", c + c, i, i + 2))
                i += 2
            else:
                tokens.append(("op", c, i, i + 1))
                i += 1
            continue
        if c in "<>":
            if i + 1 < n and text[i + 1] == c:
                tokens.append(("op", c + c, i, i + 2))
                i += 2
            elif c == "<" and i + 1 < n and text[i + 1] == ">":
                tokens.append(("op", "<>", i, i + 2))
                i += 2
            elif c == ">" and i + 1 < n and text[i + 1] == "|":
                tokens.append(("op", ">|", i, i + 2))
                i += 2
            else:
                tokens.append(("op", c, i, i + 1))
                i += 1
            continue
        start = i
        out: list[str] = []
        while i < n:
            ch = text[i]
            if ch in " \t;&|<>":
                break
            if ch == "'":
                j = text.find("'", i + 1)
                if j == -1:
                    out.append(text[i + 1 :])
                    i = n
                    break
                out.append(text[i + 1 : j])
                i = j + 1
                continue
            if ch == '"':
                j = i + 1
                buf: list[str] = []
                while j < n:
                    cj = text[j]
                    if cj == "\\" and j + 1 < n:
                        buf.append(text[j : j + 2])
                        j += 2
                        continue
                    if cj == '"':
                        break
                    if cj == "`":
                        end = text.find("`", j + 1)
                        if end == -1:
                            buf.append(text[j:])
                            j = n
                            break
                        buf.append(text[j : end + 1])
                        j = end + 1
                        continue
                    if cj == "$" and j + 1 < n and text[j + 1] == "(":
                        # A command substitution inside a double-quoted
                        # string carries its own quotes and spaces
                        # (`SHA="$(gh api "repos/…" --jq '.head_sha')"`);
                        # consuming it here keeps the word whole.
                        end = _consume_command_substitution(text, j)
                        buf.append(text[j:end])
                        j = end
                        continue
                    buf.append(cj)
                    j += 1
                out.append("".join(buf))
                i = j + 1 if j < n else n
                continue
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == "`":
                j = text.find("`", i + 1)
                out.append(text[i : (j + 1 if j != -1 else n)])
                i = j + 1 if j != -1 else n
                continue
            if ch == "$" and i + 1 < n and text[i + 1] == "(":
                j = _consume_command_substitution(text, i)
                out.append(text[i:j])
                i = j
                continue
            out.append(ch)
            i += 1
        tokens.append(("word", "".join(out), start, i))
    return tokens


def _first_shell_word(text: str) -> tuple[str | None, int]:
    """The first shell word of `text` (quotes removed) and the raw index
    just past it, or `(None, 0)` when the text does not start with a word."""
    tokens = _shell_tokens(text)
    if not tokens or tokens[0][0] != "word":
        return None, 0
    return tokens[0][1], tokens[0][3]


def _shell_segments(
    tokens: list[tuple[str, str, int, int]],
) -> list[list[tuple[str, str, int, int]]]:
    """Split a token stream at the top-level command separators, so each
    segment is one command whose redirections belong to it. An `&` that
    closes a redirection (`2>&1`, `>&-`) is not a separator."""
    segments: list[list[tuple[str, str, int, int]]] = []
    current: list[tuple[str, str, int, int]] = []
    previous: tuple[str, str, int, int] | None = None
    for token in tokens:
        is_separator = token[0] == "op" and token[1] in (";", "&&", "||", "|", "&")
        if token[0] == "op" and token[1] == "&" and previous is not None:
            previous_is_redirect = previous[0] == "op" and previous[1] in (
                ">",
                ">>",
                ">|",
                "<",
                "<<",
                "<>",
            )
            is_separator = not previous_is_redirect
        if is_separator:
            if current:
                segments.append(current)
            current = []
            previous = token
            continue
        current.append(token)
        previous = token
    if current:
        segments.append(current)
    return segments


def _segment_conditional_flags(
    tokens: list[tuple[str, str, int, int]], starts_conditional: bool
) -> tuple[list[bool], bool, bool, bool]:
    """Per-segment execution conditionality for one token stream, aligned
    1:1 with `_shell_segments(tokens)`. A segment reached through `&&`,
    `||` or `|` (or continuing a physical line that ended in one) is
    conditional: it may not have executed by the time a later write runs,
    so a trace that reaches its assignment refuses (issue #342, R1). `;`
    and `&` always execute their following segment. Returns
    `(flags, next_conditional, trailing_conditional, ends_with_separator)`:
    `next_conditional` is the state a segment after the line's last
    separator starts with, and `trailing_conditional` the state of the
    line's last segment (what a backslash continuation inherits)."""
    flags: list[bool] = []
    next_conditional = starts_conditional
    in_segment = False
    ends_with_separator = False
    previous: tuple[str, str, int, int] | None = None
    for token in tokens:
        is_separator = token[0] == "op" and token[1] in (";", "&&", "||", "|", "&")
        if token[0] == "op" and token[1] == "&" and previous is not None:
            previous_is_redirect = previous[0] == "op" and previous[1] in (
                ">",
                ">>",
                ">|",
                "<",
                "<<",
                "<>",
            )
            is_separator = not previous_is_redirect
        if is_separator:
            if in_segment:
                # A segment that is the left side of a `|` pipeline or the
                # command of a `&` background list runs in a subshell: its
                # assignments do not propagate to the parent shell, so they
                # can never be a reaching assignment (issue #342, F2).
                ends_in_subshell = token[1] in ("|", "&")
                flags.append(next_conditional or ends_in_subshell)
            if (
                token[1] == "&"
                and previous is not None
                and previous[0] == "op"
                and previous[1] == "|"
            ):
                # `|&` is `2>&1 |`: the command after it still runs in the
                # pipeline's subshell, so the pipe's conditionality stands.
                next_conditional = True
            else:
                next_conditional = token[1] in ("&&", "||", "|")
            in_segment = False
            ends_with_separator = True
        else:
            in_segment = True
            ends_with_separator = False
        previous = token
    if in_segment:
        flags.append(next_conditional)
    trailing_conditional = flags[-1] if flags else starts_conditional
    return flags, next_conditional, trailing_conditional, ends_with_separator


def _line_has_continuation(line: str) -> bool:
    """True when the physical line ends in an unescaped backslash. The
    shell joins the next physical line into this command, so a redirect
    operator at the end can take its target from a line the per-line scan
    does not read as part of the command (`>& \\` + newline + `"$n"`). An
    even run of backslashes is an escaped backslash, not a continuation
    (issue #342, R3)."""
    trailing = len(line) - len(line.rstrip("\\"))
    return trailing % 2 == 1


def _continuation_hides_redirect_target(line: str) -> bool:
    """True when the physical line ends in an unescaped backslash
    continuation after a redirection operator, so the shell joins the next
    line into that command and the redirect target can sit outside the
    per-line view (`>& \\` + newline + `"$n"`) (issue #342, R3/F1). A line
    ending a continuation after a plain word (a `printf … \\` argument
    split), inside a comment, or in heredoc payload text is not a redirect
    split and is accepted: only a trailing redirect operator can take its
    target from the joined line."""
    if not _line_has_continuation(line):
        return False
    tokens = _shell_tokens(line)
    while tokens and tokens[-1][0] == "word" and tokens[-1][1].endswith("\\"):
        tokens = tokens[:-1]
    if not tokens:
        return False
    kind, text, _start, _end = tokens[-1]
    if kind == "op" and text in (">", ">>", ">|", "<", "<<", "<>"):
        return True
    if (
        kind == "op"
        and text == "&"
        and len(tokens) >= 2
        and tokens[-2][0] == "op"
        and tokens[-2][1] == ">"
    ):
        # `>& \\` tokenizes as the op `>` then the op `&` (the omitted-fd
        # stdout+stderr file redirect), with the target on the next line.
        return True
    return False


def _command_substitution_depth(
    line: str, depth: int = 0, in_backtick: bool = False
) -> tuple[int, bool]:
    """Track the command substitutions the body leaves open across physical
    lines. The caller carries the `(depth, in_backtick)` state from the
    previous lines in, and this scan returns the state this physical line
    leaves: a line that opens a `$(` or a backtick raises the depth, and a
    line that closes one lowers it, so an assignment inside a substitution
    carried across physical lines stays subshell-local while an assignment
    after that substitution closed is not (issue #342, F2 / fold-6
    BLOCKER-1). Quotes and escapes are honoured and a `#` comment ends the
    scan; a construct this text scan cannot parse yields a positive depth,
    which refuses rather than passes."""
    quote: str | None = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and quote != "'" and i + 1 < n:
            i += 2
            continue
        if c == "'" and quote is None:
            quote = "'"
            i += 1
            continue
        if c == '"' and quote is None:
            quote = '"'
            i += 1
            continue
        if c == '"' and quote == '"':
            quote = None
            i += 1
            continue
        if c == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            break
        if c == "$" and i + 1 < n and line[i + 1] == "(":
            depth += 1
            i += 2
            continue
        if c == "`":
            if in_backtick:
                in_backtick = False
                depth -= 1
            else:
                in_backtick = True
                depth += 1
            i += 1
            continue
        if c == ")" and depth > 0 and not in_backtick:
            depth -= 1
            i += 1
            continue
        i += 1
    return depth, in_backtick


def _segment_redirects(
    segment: list[tuple[str, str, int, int]],
) -> list[tuple[str, str, int, tuple[int, int] | None, int | None]]:
    """Every redirection in one segment as `(op, target_word, op_start,
    target_span, fd)`. A file-descriptor duplication/closure (`>&1`, `>&-`)
    has the pseudo-target `&` and no span; `>&word` with any other word is
    bash's omitted-fd stdout+stderr file redirect, so the word is a real
    target, `>|word` is a plain file redirect (issue #342, BLOCKER-1), and
    `<>word` is a read-write file open whose `fd` is the number immediately
    prefixing the operator (or 0 when absent): fd 0 opens stdin read-write
    and provably does not write the payload, an explicit higher fd is a
    payload-writing target that must be resolved (issue #342, R2)."""
    redirects: list[tuple[str, str, int, tuple[int, int] | None, int | None]] = []
    index = 0
    while index < len(segment):
        kind, text, start, _end = segment[index]
        if kind == "op" and text in (">", ">>", ">|", "<>"):
            fd: int | None = None
            if text == "<>":
                previous = segment[index - 1] if index > 0 else None
                if (
                    previous is not None
                    and previous[0] == "word"
                    and previous[1].isascii()
                    and previous[1].isdigit()
                    and previous[3] == start
                ):
                    fd = int(previous[1])
                elif (
                    previous is not None
                    and previous[0] == "word"
                    and re.fullmatch(r"\{[A-Za-z_][A-Za-z0-9_]*\}", previous[1])
                    and previous[3] == start
                ):
                    # bash's `{name}<>` dynamic allocation picks a fd above
                    # 10, so it is a payload target, never the benign fd 0.
                    fd = -1
                else:
                    fd = 0
            if index + 1 < len(segment):
                next_kind, next_text, next_start, next_end = segment[index + 1]
                if next_kind == "word":
                    redirects.append(
                        (text, next_text, start, (next_start, next_end), fd)
                    )
                    index += 2
                    continue
                if next_kind == "op" and next_text == "&":
                    after = segment[index + 2] if index + 2 < len(segment) else None
                    if after is not None and after[0] == "word":
                        if after[1] == "-" or (
                            after[1].isascii() and after[1].isdigit()
                        ):
                            redirects.append((text, "&", start, None, fd))
                        else:
                            redirects.append(
                                (text, after[1], start, (after[2], after[3]), fd)
                            )
                        index += 3
                        continue
                    redirects.append((text, "&", start, None, fd))
                    index += 2
                    continue
            redirects.append((text, "", start, None, fd))
            index += 1
            continue
        index += 1
    return redirects


def _segment_reference_text(
    line: str,
    segment: list[tuple[str, str, int, int]],
    excluded_spans: list[tuple[int, int]],
) -> str:
    """The segment's source text with the redirect targets that provably do
    NOT name the env file removed, so `echo … >> "$GITHUB_ENV.bak"` does not
    read as an env-file mention while a read-only `cat "$GITHUB_ENV"`
    argument still does (issue #342, MINOR-1/F3)."""
    start = segment[0][2]
    end = segment[-1][3]
    if not excluded_spans:
        return line[start:end]
    pieces: list[str] = []
    cursor = start
    for span_start, span_end in sorted(set(excluded_spans)):
        if span_start < cursor or span_end > end:
            continue
        pieces.append(line[cursor:span_start])
        cursor = span_end
    pieces.append(line[cursor:end])
    return "".join(pieces)


def _heredoc_payload_line_indices(lines: list[str]) -> tuple[set[int], int | None]:
    """Line indices a shell heredoc consumes as literal payload, plus the
    opening-line index of the first heredoc whose delimiter never appears.
    Those lines are not shell statements: excluding them from the
    alias/assignment index keeps an env-file-looking payload line from being
    read as shell (a false-positive `<<` only drops assignments, which
    refuses rather than passes). A missing delimiter means bash consumes the
    rest of the body as heredoc text (`here-document … delimited by
    end-of-file`), so no later line is a shell statement either — the caller
    refuses a continuation-ending line in that region rather than reading
    the swallowed lines as shell (issue #342, fold-6 MINOR-3)."""
    skipped: set[int] = set()
    unterminated_at: int | None = None
    index = 0
    while index < len(lines):
        match = _HEREDOC_RE.search(lines[index])
        if match is None:
            index += 1
            continue
        delimiter = match.group(1) or match.group(2) or match.group(3)
        cursor = index + 1
        while cursor < len(lines) and lines[cursor].strip() != delimiter:
            skipped.add(cursor)
            cursor += 1
        if cursor >= len(lines):
            if unterminated_at is None:
                unterminated_at = index
            break
        index = cursor + 1
    return skipped, unterminated_at


def _alias_value_is_pure_env_spelling(text: str) -> bool:
    """True when `text` starts with one word that is a pure env-file
    spelling: no command substitution, backtick, redirection or separator
    (`x=$(echo … >> "$GITHUB_ENV")` is a command that performs the write,
    not an alias definition), and the word carries the #339 mention. This
    is what keeps the alias skip from hiding a write behind `$( )` or a
    backtick (issue #342, BLOCKER-1)."""
    word, end = _first_shell_word(text)
    if word is None or end == 0:
        return False
    if any(marker in text[:end] for marker in _ALIAS_RHS_UNMODELLED_CHARS):
        return False
    return _mentions_github_env(word)


def _env_file_alias_names(lines: list[str], skip: set[int]) -> set[str]:
    """Body-local variables whose assignment is itself a pure env-file
    spelling (`n="GITHUB_""ENV"`, `out="$GITHUB_ENV"`), so a redirect to
    `$n`/`${out}` resolves to the env file. An assignment whose first word
    computes the path (`x=$(… >> "$GITHUB_ENV")`) is not an alias: it is
    the write itself (issue #342, BLOCKER-1)."""
    names: set[str] = set()
    for index, line in enumerate(lines):
        if index in skip:
            continue
        match = _ENV_ALIAS_ASSIGNMENT_RE.match(line)
        if match is None:
            continue
        if _alias_value_is_pure_env_spelling(line[match.end() :]):
            names.add(match.group(1))
    return names


def _body_shell_assignments(lines: list[str], skip: set[int]) -> list[_ShellAssignment]:
    """Index every statement-position `NAME=VALUE` on every body line — each
    top-level segment (`;`, `&&`, `||`, `|`, `&`) can begin with one, and
    `export` may prefix it — with its line, column and left-to-right order,
    so a later same-line reassignment is visible to both traces. A statement
    the extractor cannot read (`NAME+=…`, no word after `=`) is indexed with
    a None value so a trace that reaches it refuses rather than passes; an
    assignment that is not at a statement position (`echo x=1`) is not
    indexed at all, so a reference to it refuses as unset. A `&&`/`||`/`|`
    segment — or a continuation of one across a physical line — is marked
    conditional, because it may not have executed by the time the write runs
    (issue #342, R1)."""
    assignments: list[_ShellAssignment] = []
    starts_conditional = False
    subshell_depth = 0
    in_backtick = False
    for index, line in enumerate(lines):
        if index in skip:
            continue
        in_subshell = subshell_depth > 0
        tokens = _shell_tokens(line)
        flags, next_conditional, trailing_conditional, ends_with_separator = (
            _segment_conditional_flags(tokens, starts_conditional)
        )
        for segment_index, segment in enumerate(_shell_segments(tokens)):
            if not segment or segment[0][0] != "word":
                continue
            word_index = 0
            if (
                segment[0][1] == "export"
                and len(segment) > 1
                and segment[1][0] == "word"
            ):
                word_index = 1
            _kind, _text, start, end = segment[word_index]
            conditional = (
                flags[segment_index]
                if segment_index < len(flags)
                else starts_conditional
            ) or in_subshell
            # Match the RAW word (quotes intact) so a quoted name is not
            # promoted to an assignment the shell never makes.
            word_text = line[start:end]
            match = _ENV_ALIAS_ASSIGNMENT_RE.match(word_text)
            if match is None:
                append = _ENV_APPEND_ASSIGNMENT_RE.match(word_text)
                if append is not None:
                    assignments.append(
                        _ShellAssignment(
                            append.group(1),
                            None,
                            index,
                            start,
                            _indent_width(line),
                            conditional,
                        )
                    )
                continue
            value, _value_end = _first_shell_word(line[start + match.end() :])
            assignments.append(
                _ShellAssignment(
                    match.group(1), value, index, start, _indent_width(line), conditional
                )
            )
        subshell_depth, in_backtick = _command_substitution_depth(
            line, subshell_depth, in_backtick
        )
        if not tokens:
            # A blank or comment-only line does not end a `&&`/`||` list:
            # both `a &&` + blank + `b` and `a &&` + `# x` + `b` keep `b`
            # conditional.
            continue
        if _line_has_continuation(line):
            starts_conditional = trailing_conditional
        elif ends_with_separator:
            starts_conditional = next_conditional
        else:
            starts_conditional = False
    return assignments


def _env_file_target_name_kind(
    name: str,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
    write_indent: int,
    seen: set[str],
) -> str:
    """Resolve one expanded redirect-target name to `"env"`, `"other"` or
    `"unknown"` by program order. A body-assigned name is NOT proof the
    target cannot be the env file: `n="${!x}"` is assigned and holds the env
    path, so the reaching assignment — the last one STRICTLY before the
    write's expansion position (a command-prefix assignment in the write's
    own segment is expanded with the previous value, so it is not reaching)
    — is resolved instead. Only a provably non-env literal is `"other"` (a
    plain word, or an env-file spelling plus extra literal text —
    `$GITHUB_ENV.bak` is a different file); an unassigned name is
    `"unknown"` even when it extends the spelling (`GITHUB_ENV_X`), because
    a preceding step can publish the env path under that name, and indirect,
    computed or unmodelled RHS values are `"unknown"` (issue #342,
    BLOCKER-2 / BLOCKER-3 / BLOCKER-4)."""
    if name in seen:
        return "unknown"
    if name in aliases:
        return "env"
    reaching = [
        assignment
        for assignment in assignments
        if assignment.name == name
        and (assignment.index, assignment.column) < (line_index, column_index)
    ]
    if not reaching:
        return "unknown"
    chosen = reaching[-1]
    if chosen.conditional:
        # The reaching assignment sits in an `&&`/`||`/`|` list that may not
        # have executed, so the target is ambiguous (issue #342, R1).
        return "unknown"
    if chosen.value is None or chosen.indent > write_indent:
        return "unknown"
    if _control_boundary_between(lines, chosen.index, line_index, chosen.indent):
        return "unknown"
    value = chosen.value
    if _ENV_FILE_SPELLING_RE.fullmatch(value):
        return "env"
    if "$(" in value or "`" in value or "${!" in value:
        return "unknown"
    if _ENV_FILE_SPELLING_RE.search(value):
        remainder = _ENV_FILE_SPELLING_RE.sub("", value)
        if remainder and not any(marker in remainder for marker in ("$", "`", "%")):
            return "other"
        return "unknown"
    inner = _local_reference_name(value)
    if inner is not None:
        return _env_file_target_name_kind(
            inner,
            aliases,
            assignments,
            lines,
            chosen.index,
            chosen.column,
            write_indent,
            seen | {name},
        )
    if "$" in value or "`" in value or "%" in value:
        return "unknown"
    return "other"


def _env_file_target_kind(
    target: str,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
) -> str:
    """Classify one redirect target: `"env"` when it provably names the env
    file, `"other"` when it provably does not, `"unknown"` when the
    extractor cannot resolve it (an assembled/indirect env-file target is
    not provably harmless, so the caller refuses). The env-file spelling is
    exact (`$GITHUB_ENV` / `${GITHUB_ENV}` / `%GITHUB_ENV%`, case
    insensitively): `$GITHUB_ENV.bak` names a different file and must not
    count (issue #342, MINOR-1/F3)."""
    text = target.strip()
    if not text or text.startswith("&"):
        return "other"
    if _ENV_FILE_SPELLING_RE.fullmatch(text):
        return "env"
    if "$(" in text or "`" in text or "${!" in text:
        return "unknown"
    if _ENV_FILE_SPELLING_RE.search(text):
        # A spelling plus extra literal text (`$GITHUB_ENV.bak`,
        # `pre$GITHUB_ENV`) is provably a different file; extra expansion
        # syntax could collapse onto the env path and is not provable.
        remainder = _ENV_FILE_SPELLING_RE.sub("", text)
        if remainder and not any(marker in remainder for marker in ("$", "`", "%")):
            return "other"
        return "unknown"
    names = re.findall(
        r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"
        r"|%([A-Za-z_][A-Za-z0-9_]*)%",
        text,
    )
    expanded = [a or b or c for a, b, c in names]
    if not expanded:
        # No expansion the grammar parsed. A bare `$`/`%`/backtick is an
        # expansion shape it does not model, so it is not provable.
        if "$" in text or "`" in text or "%" in text:
            return "unknown"
        return "other"
    kinds = {
        _env_file_target_name_kind(
            name,
            aliases,
            assignments,
            lines,
            line_index,
            column_index,
            _indent_width(lines[line_index]),
            set(),
        )
        for name in expanded
    }
    if "unknown" in kinds:
        return "unknown"
    if "env" in kinds:
        return "env"
    return "other"


def _segment_is_env_alias_assignment(
    segment: list[tuple[str, str, int, int]],
) -> bool:
    """A whole segment that only assigns a local from a PURE env-file
    spelling (`n="GITHUB_""ENV"`): the target-resolution mechanism, not a
    write. An RHS that computes the path or performs a write (a command
    substitution, a backtick, a redirection, a separator) is a command, not
    an alias definition, so the segment falls through to the reference check
    (issue #342, BLOCKER-1)."""
    if len(segment) != 1 or segment[0][0] != "word":
        return False
    match = _ENV_ALIAS_ASSIGNMENT_RE.match(segment[0][1])
    if match is None:
        return False
    return _alias_value_is_pure_env_spelling(segment[0][1][match.end() :])


def _segment_references_env_file(text: str, aliases: set[str]) -> bool:
    """True when the segment's text references the env file through a
    spelling, an indirect expansion (`${!name}` — the value an indirect
    expansion holds is not visible to any textual match, so every
    indirection refuses), the 64-character window conjunction, or a resolved
    alias expansion (`$n`)."""
    if "${!" in text:
        return True
    if _mentions_github_env(text):
        return True
    for name in aliases:
        if re.search(r"\$\{?" + re.escape(name) + r"\}?", text):
            return True
    return False


def _local_reference_name(text: str) -> str | None:
    """The local variable a value is exactly one expansion of, else None."""
    match = _LOCAL_REFERENCE_RE.match(text.strip())
    if match is None:
        return None
    return match.group(1) or match.group(2)


def _parse_env_payload_line(text: str) -> tuple[str, str] | None:
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", text, re.DOTALL)
    if match is None:
        return None
    return match.group(1), match.group(2)


def _control_boundary_between(
    lines: list[str], start: int, end: int, indent: int
) -> bool:
    """True when a control-flow branch or closer sits between the traced
    assignment and the write (a `then`/`else`/`fi`/`case`/loop/function
    boundary), so the assignment may not have executed. The pre-fold-3 rule
    only saw a closer SHALLOWER than the assignment, so a same-indent stale
    assignment in a non-executing branch was read as reaching; the boundary
    is now fail-closed at any indentation, and `;;` closes a `case` branch
    (issue #342, BLOCKER-2). The `indent` parameter is kept for the
    call-site signature; the boundary no longer depends on it."""
    for index in range(start + 1, end):
        line = lines[index]
        if not line.strip():
            continue
        stripped = line.strip()
        if (
            stripped == ";;"
            or _CONTROL_CLOSER_RE.match(stripped)
            or stripped.startswith("}")
        ):
            return True
    return False


def _local_trace_classification(
    name: str,
    assignments: list[_ShellAssignment],
    lines: list[str],
    limit_index: int,
    limit_column: int,
    write_indent: int,
    scoped_env: dict[str, list[tuple[str, int]]],
    seen: set[str],
) -> str:
    """Classify a `${NAME}` read by program order: the last body assignment
    STRICTLY before the read's expansion position (a command-prefix
    assignment in the reading segment is expanded with the previous value).
    Unset at the read, a reassignment after it, an assignment in a nested
    control block, `+=`, or an unclassifiable RHS refuses rather than
    guesses."""
    if name in seen:
        return "refuse"
    reaching = [assignment for assignment in assignments if assignment.name == name]
    before = [
        assignment
        for assignment in reaching
        if (assignment.index, assignment.column) < (limit_index, limit_column)
    ]
    if not before:
        return "refuse"
    if any(
        (assignment.index, assignment.column) > (limit_index, limit_column)
        for assignment in reaching
    ):
        return "refuse"
    chosen = before[-1]
    if chosen.conditional:
        # The reaching assignment sits in an `&&`/`||`/`|` list that may not
        # have executed, so the value is ambiguous (issue #342, R1).
        return "refuse"
    if chosen.value is None or chosen.indent > write_indent:
        return "refuse"
    if _control_boundary_between(lines, chosen.index, limit_index, chosen.indent):
        return "refuse"
    inner = _local_reference_name(chosen.value)
    if inner is not None:
        return _local_trace_classification(
            inner,
            assignments,
            lines,
            chosen.index,
            chosen.column,
            write_indent,
            scoped_env,
            seen | {name},
        )
    return _classify_static_value(chosen.value, scoped_env, set())


def _run_id_write_value_classification(
    value: str,
    shell_expansion: bool,
    assignments: list[_ShellAssignment],
    lines: list[str],
    write_index: int,
    write_column: int,
    scoped_env: dict[str, list[tuple[str, int]]],
) -> str:
    """The `_classify_static_value` verdict for one written value. A shell
    value that is a plain local expansion is resolved through the body's own
    program-order trace; a heredoc payload is literal env-file text, so it
    is classified directly (no shell expansion)."""
    text = value.strip()
    if not text:
        return "unknown"
    if shell_expansion:
        local = _local_reference_name(text)
        if local is not None:
            return _local_trace_classification(
                local,
                assignments,
                lines,
                write_index,
                write_column,
                _indent_width(lines[write_index]),
                scoped_env,
                set(),
            )
    return _classify_static_value(text, scoped_env, set())


def _flip_target_match(step: ArtifactStep, name: str, flip_targets: set[str]) -> str | None:
    """The flip-target name `name` matches case-insensitively (the #341
    Windows `OrdinalIgnoreCase` stance), or None. A non-ASCII name never
    reaches here: `_extract_run_id_writes` only extracts
    `[A-Za-z_][A-Za-z0-9_]*` names, so a non-ASCII written name is already
    refused by `_run_id_name_refusal` ("writes an unextractable name") —
    the plan's non-ASCII refusal is delivered there, not here."""
    folded = name.lower()
    for target in flip_targets:
        if target.isascii() and target.lower() == folded:
            return target
    return None


def _run_id_value_refusal(
    step: ArtifactStep, head: str, body: RunBody, name: str
) -> Refusal:
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' resolves through `env.{head}`, and a preceding step in "
        f"this job writes `{name}` to `$GITHUB_ENV` (line {body.line}) "
        "with a value that is not provably cross-run — that write can change the value at "
        "runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
    )


def _run_id_payload_refusal(step: ArtifactStep, body: RunBody) -> Refusal:
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job writes "
        f"to `$GITHUB_ENV` (line {body.line}) with a payload the gate cannot extract "
        "(refusing rather than guessing)",
    )


def _run_id_name_refusal(step: ArtifactStep, body: RunBody) -> Refusal:
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job "
        f"writes an unextractable name to `$GITHUB_ENV` (line {body.line}) "
        "(refusing rather than guessing)",
    )


def _run_id_reference_refusal(step: ArtifactStep, body: RunBody) -> Refusal:
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job references "
        f"`$GITHUB_ENV` (line {body.line}) without an extractable write (refusing rather "
        "than guessing)",
    )


def _run_id_unresolved_target_refusal(
    step: ArtifactStep, body: RunBody, target: str
) -> Refusal:
    """A redirect target that is neither the exact env-file spelling nor a
    value the extractor can prove harmless (an unassigned expansion, an
    indirect/computed RHS, a suffix of the spelling). Distinct from
    `_run_id_reference_refusal`: the line need not reference `$GITHUB_ENV`
    at all (issue #342, NIT-2)."""
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job redirects to "
        f"`{target}`, a target the extractor cannot resolve to the env file or prove harmless "
        "(refusing rather than guessing)",
    )


def _run_id_continuation_refusal(step: ArtifactStep, body: RunBody) -> Refusal:
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job ends a line "
        "with an unescaped backslash continuation, so a redirect target or assignment can sit "
        "on the next line outside the extractor's per-line view (refusing rather than guessing)",
    )


def _run_id_unmodelled_write_refusal(
    step: ArtifactStep, body: RunBody, match: tuple[str, str | None, bool]
) -> Refusal:
    mechanism, operand, carrier = match
    if operand is None:
        detail = (
            f"writes a variable through `{mechanism}` with a target the extractor cannot resolve"
        )
    elif carrier:
        detail = (
            f"runs `{mechanism}` with a command string that names the value the download "
            "resolves through"
        )
    else:
        detail = f"writes `{operand}` through `{mechanism}`, which the extractor does not model"
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job {detail} "
        "(refusing rather than guessing)",
    )


def _assignment_operand_name(word: str) -> str | None:
    """`NAME`, `NAME=VALUE` or `NAME[...]` as the written variable name, or
    None for a word that is not a static variable name."""
    match = _ASSIGNMENT_OPERAND_RE.match(word)
    if match is not None:
        return match.group(1)
    match = _ARRAY_OPERAND_RE.match(word)
    if match is not None:
        return match.group(1)
    if _IDENTIFIER_RE.match(word):
        return word
    return None


def _read_operands(argv: list[str]) -> list[str | None]:
    """Every variable `read`/`mapfile`/`readarray` writes: the non-option
    words, with option arguments skipped. A dynamic operand (`read -r
    "$name"`) is returned as None so the caller refuses rather than
    guessing which variable it writes (issue #342, R4)."""
    operands: list[str | None] = []
    position = 0
    while position < len(argv):
        word = argv[position]
        if word == "--":
            position += 1
            continue
        if word.startswith("-") and len(word) > 1:
            position += 2 if word in _READ_OPTIONS_WITH_ARGUMENT else 1
            continue
        if word.startswith("$"):
            operands.append(None)
        elif _IDENTIFIER_RE.match(word):
            operands.append(word)
        position += 1
    return operands


def _mechanism_operands(
    mechanism: str, argv: list[str]
) -> list[tuple[str | None, bool]]:
    """The `(operand, carrier)` pairs one unmodelled write mechanism names.
    `operand` is a variable name for name-writing mechanisms, shell text for
    carriers (`trap`/`eval`/`sh -c`), and None for an operand the extractor
    cannot resolve, which the caller refuses (issue #342, R4)."""
    if mechanism in ("read", "readarray", "mapfile"):
        return [(name, False) for name in _read_operands(argv)]
    if mechanism == "printf":
        for position, word in enumerate(argv):
            if word == "-v" and position + 1 < len(argv):
                return [(_assignment_operand_name(argv[position + 1]), False)]
            if word.startswith("-v") and len(word) > 2:
                return [(_assignment_operand_name(word[2:]), False)]
        return []
    if mechanism in ("declare", "local", "typeset", "readonly"):
        operands: list[tuple[str | None, bool]] = []
        for word in argv:
            if word.startswith("-"):
                continue
            if word.startswith("$"):
                operands.append((None, False))
                continue
            name = _assignment_operand_name(word)
            if name is not None:
                operands.append((name, False))
        return operands
    if mechanism == "unset":
        operands = []
        for word in argv:
            if word.startswith("-"):
                continue
            if word.startswith("$"):
                operands.append((None, False))
                continue
            name = _assignment_operand_name(word)
            if name is not None:
                operands.append((name, False))
        return operands
    if mechanism == "getopts":
        return [(name, False) for name in _read_operands(argv[1:])]
    if mechanism in ("for", "select"):
        if not argv:
            return []
        word = argv[0]
        if word.startswith("$"):
            return [(None, False)]
        if _IDENTIFIER_RE.match(word):
            return [(word, False)]
        return []
    if mechanism in ("trap", "eval"):
        return [(word, True) for word in argv]
    if mechanism in ("bash", "sh", "zsh", "dash", "ksh") and "-c" in argv:
        return [(word, True) for word in argv]
    return []


def _name_is_relevant(
    name: str,
    step: ArtifactStep,
    relevant: set[str],
    flip_targets: set[str],
) -> bool:
    if name in relevant:
        return True
    return _flip_target_match(step, name, flip_targets) is not None


def _text_references_names(
    text: str, relevant: set[str], flip_targets: set[str]
) -> bool:
    for name in relevant:
        if re.search(r"\$\{?" + re.escape(name) + r"\}?", text):
            return True
    for target in flip_targets:
        if target.isascii() and re.search(
            r"\$\{?" + re.escape(target) + r"\}?", text, re.IGNORECASE
        ):
            return True
    return False


def _carrier_operand_matches(
    text: str, relevant: set[str], flip_targets: set[str]
) -> bool:
    """True when a `trap`/`eval`/`sh -c` command string can carry the value
    the download resolves through: it mentions the env file, references a
    traced variable, or assigns one (issue #342, R4)."""
    if _mentions_github_env(text):
        return True
    if _text_references_names(text, relevant, flip_targets):
        return True
    for name in relevant:
        if re.search(r"(?:^|[\s;|&(){}])" + re.escape(name) + r"=", text):
            return True
    return False


def _unmodelled_write_match(
    tokens: list[tuple[str, str, int, int]],
    step: ArtifactStep,
    relevant: set[str],
    flip_targets: set[str],
) -> tuple[str, str | None, bool] | None:
    """The first unmodelled variable-writing mechanism on one line whose
    operand names a variable the run-id rule traces, or None. The walk is
    over words, not segment starts, so a mechanism inside a group or a
    function body (`f() { declare -g …; }`) is seen (issue #342, R4)."""
    index = 0
    while index < len(tokens):
        kind, text, _start, _end = tokens[index]
        if kind != "word" or text not in _UNMODELLED_WRITE_VERBS:
            index += 1
            continue
        mechanism = text
        index += 1
        argv: list[str] = []
        while index < len(tokens) and tokens[index][0] == "word":
            argv.append(tokens[index][1])
            index += 1
        for operand, carrier in _mechanism_operands(mechanism, argv):
            if operand is None:
                return (mechanism, None, carrier)
            if carrier:
                if _carrier_operand_matches(operand, relevant, flip_targets):
                    return (mechanism, operand, True)
            elif _name_is_relevant(operand, step, relevant, flip_targets):
                return (mechanism, operand, False)
    return None


def _statement_assignment_miss(
    line: str,
    segment: list[tuple[str, str, int, int]],
    index: int,
    modelled: set[tuple[int, int]],
    step: ArtifactStep,
    relevant: set[str],
    flip_targets: set[str],
) -> str | None:
    """A `NAME=VALUE` word in this segment that is not at an indexed
    statement position (`{ n="$m"; }`, `true n="$m"`, a group or subshell
    assignment) and names a traced variable, or None (issue #342, R4)."""
    for token in segment:
        if token[0] != "word":
            continue
        raw = line[token[2] : token[3]]
        match = _ENV_ALIAS_ASSIGNMENT_RE.match(raw)
        if match is None:
            continue
        if (index, token[2]) in modelled:
            continue
        name = match.group(1)
        if _name_is_relevant(name, step, relevant, flip_targets):
            return name
    return None


def _expansion_names(text: str) -> set[str]:
    """Every `$NAME`/`${NAME}`/`%NAME%` variable a redirect target
    references, so an unmodelled write of that variable is seen as able to
    change the redirect's destination (issue #342, R4)."""
    return {
        a or b or c
        for a, b, c in re.findall(
            r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"
            r"|%([A-Za-z_][A-Za-z0-9_]*)%",
            text,
        )
    }


def _relevant_shell_names(
    flip_targets: set[str],
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    skip: set[int],
) -> set[str]:
    """Every shell variable the run-id rule traces for this body: the flip
    targets, the env-file aliases, every body assignment's name, and every
    variable a redirect target expands. An unmodelled write of any of them
    can change what the download resolves through (issue #342, R4)."""
    names: set[str] = set(flip_targets) | set(aliases)
    names.update(assignment.name for assignment in assignments)
    for index, line in enumerate(lines):
        if index in skip:
            continue
        for segment in _shell_segments(_shell_tokens(line)):
            for _op, target, _start, _span, _fd in _segment_redirects(segment):
                names.update(_expansion_names(target))
    return names


def _extract_run_id_writes(
    segment: list[tuple[str, str, int, int]],
    lines: list[str],
    index: int,
    redirect_start: int,
    step: ArtifactStep,
    body: RunBody,
) -> tuple[list[tuple[str, str, bool]], int]:
    """Extract the `NAME=VALUE` writes of one modelled env-file write line
    (an `echo`/`printf` argument, or the heredoc body a `cat` feeds), or
    refuse when the verb, payload or name is outside the extractor's
    grammar. Returns `(writes, skip_until)` where each write is
    `(name, value, shell_expansion)`."""
    words = [
        token
        for token in segment
        if token[0] == "word" and token[2] < redirect_start
    ]
    while words and _ENV_ALIAS_ASSIGNMENT_RE.match(words[0][1]):
        words.pop(0)
    if not words:
        raise _run_id_payload_refusal(step, body)
    verb = words[0][1]
    if verb == "cat":
        heredoc = _HEREDOC_RE.search(lines[index])
        if heredoc is None:
            raise _run_id_payload_refusal(step, body)
        delimiter = heredoc.group(1) or heredoc.group(2) or heredoc.group(3)
        payload_lines: list[str] = []
        cursor = index + 1
        while cursor < len(lines) and lines[cursor].strip() != delimiter:
            payload_lines.append(lines[cursor].strip())
            cursor += 1
        writes: list[tuple[str, str, bool]] = []
        for payload_line in payload_lines:
            if not payload_line:
                continue
            parsed = _parse_env_payload_line(payload_line)
            if parsed is None:
                raise _run_id_payload_refusal(step, body)
            writes.append((parsed[0], parsed[1], False))
        return writes, cursor
    if verb not in ("echo", "printf"):
        raise _run_id_payload_refusal(step, body)
    writes = []
    for _kind, word, _start, _end in words[1:]:
        parsed = _parse_env_payload_line(word)
        if parsed is None:
            if "=" in word:
                raise _run_id_name_refusal(step, body)
            continue
        writes.append((parsed[0], parsed[1], True))
    if not writes:
        raise _run_id_payload_refusal(step, body)
    return writes, -1


def _segment_is_test_read(segment: list[tuple[str, str, int, int]]) -> bool:
    """True when the segment is a conditional test (`[[ … ]]`, `[ … ]`,
    `test …`, optionally behind `if`/`elif`/`while`/`until`/`!`). A test
    command reads its operands and cannot write a variable, so every word in
    it is a proven-benign read position (issue #342, F3)."""
    words = [token[1] for token in segment if token[0] == "word"]
    if not words:
        return False
    if words[0] in ("[[", "[", "test"):
        return True
    return bool(
        words[0] in ("if", "elif", "while", "until", "!")
        and len(words) > 1
        and words[1] in ("[[", "[", "test")
    )


def _word_mentions_traced_name(
    text: str, relevant: set[str], flip_targets: set[str]
) -> str | None:
    """The first traced name that appears in one shell word as a complete
    identifier (bounded by non-identifier characters), or None. Exact names
    are matched case-sensitively; flip targets get the same case-insensitive
    stance as `_flip_target_match` (issue #342, F3). The longest name wins so
    a name that is a prefix of another cannot shadow the longer occurrence."""
    for name in sorted(relevant, key=len, reverse=True):
        if re.search(
            r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", text
        ):
            return name
    for target in sorted(flip_targets, key=len, reverse=True):
        if target.isascii() and re.search(
            r"(?<![A-Za-z0-9_])" + re.escape(target) + r"(?![A-Za-z0-9_])",
            text,
            re.IGNORECASE,
        ):
            return target
    return None


def _unaccounted_traced_occurrence(
    tokens: list[tuple[str, str, int, int]],
    accounted: set[tuple[int, int]],
    relevant: set[str],
    flip_targets: set[str],
) -> str | None:
    """The first traced name that appears as a shell word the model has not
    accounted for, or None. A word covered by an accounted span is modelled:
    a statement-position or alias assignment, a classified redirect target,
    an extracted env-write payload, an `echo`/`printf`/`cat` `NAME=VALUE`
    payload in a proven-non-env segment, or a test command's read operand.
    A word starting with `-` is an option and cannot name a variable.
    Anything else that mentions a traced name at an identifier boundary
    refuses — the detection-completeness backstop that closes the whole
    naming family, including spellings no mechanism table lists (issue #342,
    F3)."""
    for kind, text, start, end in tokens:
        if kind != "word" or (start, end) in accounted:
            continue
        if text.startswith("-"):
            continue
        name = _word_mentions_traced_name(text, relevant, flip_targets)
        if name is not None:
            return name
    return None


def _run_id_unaccounted_occurrence_refusal(
    step: ArtifactStep, body: RunBody, name: str
) -> Refusal:
    """A traced name appears as a shell word the extractor cannot account
    for (issue #342, F3)."""
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job mentions "
        f"`{name}`, an occurrence the extractor cannot account for (refusing rather than "
        "guessing)",
    )


def _refuse_github_env_run_id_write(
    job: Job,
    step: ArtifactStep,
    static_env: dict[str, list[tuple[str, int]]],
    scoped_env: dict[str, list[tuple[str, int]]],
) -> None:
    """#342: a preceding same-job `run:` step that mentions `$GITHUB_ENV`
    and writes a name an env-resolved `run-id:` resolves through can flip the
    runtime value to the current run's id, so the cross-run exclusion cannot
    be proven unless every such write's value classifies cross-run. Gated on
    `_env_reference(step.run_id)`: a direct expression cannot be affected by
    an env-file write and is a no-op here. Flip-target names are the chain
    head plus every `env.` link (a job/workflow-level link is frozen at job
    start, so refusing it is a fail-closed over-approximation; a step-level
    link genuinely re-evaluates), minus names the download step's own `env:`
    assigns (its `env:` wins over a `$GITHUB_ENV` write). Every line of every
    preceding mentioning body is accounted: a line that references the env
    file must be a modelled write with an extractable, classified payload, or
    the download refuses."""
    if step.run_id is None:
        return
    head = _env_reference(step.run_id)
    if head is None:
        return
    flip_targets = set(_env_chain_names(step.run_id, scoped_env))
    if step.env_range is not None:
        low, high = step.env_range
        for name, entries in static_env.items():
            if any(low <= line <= high for _value, line in entries):
                flip_targets.discard(name)
    for body in job.run_bodies:
        if not body.mentions_github_env or body.step_line >= step.uses_line:
            continue
        lines = body.body_text.split("\n")
        payload_lines, unterminated_heredoc_at = _heredoc_payload_line_indices(lines)
        if unterminated_heredoc_at is not None and any(
            _line_has_continuation(line)
            for line in lines[unterminated_heredoc_at + 1 :]
        ):
            # The would-be delimiter ends in a continuation, so bash never
            # sees the delimiter and consumes the rest of the body as
            # heredoc text; the lines the extractor would read as shell
            # (including any write) never execute (issue #342, fold-6
            # MINOR-3). Refusing keeps the extractor from accepting a body
            # whose modelled write cannot run.
            raise _run_id_continuation_refusal(step, body)
        aliases = _env_file_alias_names(lines, payload_lines)
        assignments = _body_shell_assignments(lines, payload_lines)
        modelled_positions = {(hit.index, hit.column) for hit in assignments}
        relevant_names = _relevant_shell_names(
            flip_targets, aliases, assignments, lines, payload_lines
        )
        skip_until = -1
        for index, line in enumerate(lines):
            if index <= skip_until:
                continue
            if index not in payload_lines and _continuation_hides_redirect_target(line):
                raise _run_id_continuation_refusal(step, body)
            tokens = _shell_tokens(line)
            mechanism = _unmodelled_write_match(
                tokens, step, relevant_names, flip_targets
            )
            if mechanism is not None:
                raise _run_id_unmodelled_write_refusal(step, body, mechanism)
            accounted: set[tuple[int, int]] = set()
            for segment in _shell_segments(tokens):
                write_column = segment[0][2]
                env_redirect: int | None = None
                unknown_redirect: str | None = None
                other_target_spans: list[tuple[int, int]] = []
                for _op, target, redirect_start, target_span, redirect_fd in (
                    _segment_redirects(segment)
                ):
                    if target_span is not None:
                        # Every classified redirect target is a modelled
                        # occurrence (issue #342, F3).
                        accounted.add(target_span)
                    if _op == "<>" and redirect_fd == 0:
                        # A bare `<>` (or an explicit fd 0) opens stdin
                        # read-write: it provably does not write the payload,
                        # so its target is a provably-other redirect target
                        # (issue #342, R2).
                        if target_span is not None:
                            other_target_spans.append(target_span)
                        continue
                    kind = _env_file_target_kind(
                        target, aliases, assignments, lines, index, write_column
                    )
                    if kind == "unknown":
                        unknown_redirect = target
                    elif kind == "env":
                        if env_redirect is None:
                            env_redirect = redirect_start
                    elif target_span is not None:
                        other_target_spans.append(target_span)
                if unknown_redirect is not None:
                    raise _run_id_unresolved_target_refusal(
                        step, body, unknown_redirect
                    )
                for token in segment:
                    if token[0] == "word" and (index, token[2]) in modelled_positions:
                        # A statement-position assignment the index modelled
                        # (issue #342, F3).
                        accounted.add((token[2], token[3]))
                if env_redirect is None:
                    if _segment_is_env_alias_assignment(segment):
                        continue
                    statement = _statement_assignment_miss(
                        line,
                        segment,
                        index,
                        modelled_positions,
                        step,
                        relevant_names,
                        flip_targets,
                    )
                    if statement is not None:
                        raise _run_id_unmodelled_write_refusal(
                            step,
                            body,
                            ("an out-of-statement assignment", statement, False),
                        )
                    segment_text = _segment_reference_text(
                        line, segment, other_target_spans
                    )
                    if _segment_references_env_file(segment_text, aliases):
                        raise _run_id_reference_refusal(step, body)
                    first_word = (
                        segment[0][1]
                        if segment and segment[0][0] == "word"
                        else ""
                    )
                    if first_word in ("echo", "printf", "cat"):
                        # The segment is a modelled payload command whose
                        # redirects are all classified and which provably
                        # does not write the env file: a `NAME=VALUE` word
                        # is a payload the model has seen, not an
                        # unaccounted occurrence (issue #342, F3).
                        for token in segment:
                            if token[0] == "word" and _ASSIGNMENT_OPERAND_RE.match(
                                token[1]
                            ):
                                accounted.add((token[2], token[3]))
                    if _segment_is_test_read(segment):
                        # A test command cannot write a variable, so its
                        # operands are proven-benign read positions
                        # (issue #342, F3).
                        for token in segment:
                            if token[0] == "word":
                                accounted.add((token[2], token[3]))
                    if first_word == "export":
                        # A bare `export NAME` only marks an existing
                        # variable for export; it cannot change the value, so
                        # it is a modelled occurrence (issue #342, F3). An
                        # `export NAME=VALUE` is a statement-position
                        # assignment and is accounted above.
                        for token in segment:
                            if token[0] == "word" and _IDENTIFIER_RE.match(token[1]):
                                accounted.add((token[2], token[3]))
                    continue
                writes, consumed = _extract_run_id_writes(
                    segment, lines, index, env_redirect, step, body
                )
                if consumed >= 0:
                    skip_until = consumed
                for token in segment:
                    if token[0] == "word" and token[2] < env_redirect:
                        # The verb and every payload word the write extractor
                        # read and classified (issue #342, F3).
                        accounted.add((token[2], token[3]))
                for name, value, shell_expansion in writes:
                    if _flip_target_match(step, name, flip_targets) is None:
                        continue
                    classification = _run_id_write_value_classification(
                        value,
                        shell_expansion,
                        assignments,
                        lines,
                        index,
                        write_column,
                        scoped_env,
                    )
                    if classification != "cross-run":
                        raise _run_id_value_refusal(step, head, body, name)
            if index in payload_lines:
                # Heredoc payload lines are literal env-file text, not shell
                # words (issue #342, F3).
                continue
            occurrence = _unaccounted_traced_occurrence(
                tokens, accounted, relevant_names, flip_targets
            )
            if occurrence is not None:
                raise _run_id_unaccounted_occurrence_refusal(step, body, occurrence)


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
    empty the token before the action reads it. The `run-id:` chain gets its
    own value-aware `$GITHUB_ENV` write classification (#342,
    `_refuse_github_env_run_id_write`): a preceding same-job write of a name
    the run-id resolves through keeps the exclusion only when its value
    classifies cross-run."""
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
            _refuse_github_env_run_id_write(job, step, static_env, scoped_env)
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
        result.excluded += file_result.excluded
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
                expected_excluded = case.get("excluded")
                excluded_mismatch = (
                    expected_excluded is not None
                    and scan.excluded != int(expected_excluded)
                )
                if (
                    actual_exit != expected_exit
                    or actual_lines != list(case["diagnostics"])
                    or excluded_mismatch
                ):
                    detail = ""
                    if excluded_mismatch:
                        detail = (
                            f"\n    expected excluded: {int(expected_excluded)},"
                            f" got {scan.excluded}"
                        )
                    failures.append(
                        f"{case_id}: expected exit {expected_exit} with "
                        f"{len(case['diagnostics'])} diagnostic(s), got exit {actual_exit} with "
                        f"{len(actual_lines)}:{detail}\n    expected: "
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
