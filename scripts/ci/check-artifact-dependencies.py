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
rule, or the trim/`parseInt` rules.

THE `$( … )`/BACKTICK/`<( … )` SUBSTITUTION-BODY SCAN (#345)
------------------------------------------------------------
The #342 rule is gated on `_mentions_github_env` and walks shell words; a
`$( … )`/backtick word is one token, so an env-file write inside one was
invisible when the word was accounted (an assignment RHS, an
`echo`/`printf`/`cat` `NAME=VALUE` payload, a test operand, an `export`
identifier, an env-write payload word, or a `bash <<EOF` payload line), and
a segment that already had an env redirect skipped the reference check. The
closure re-tokenizes every such word and classifies its redirects with the
outer scope. The A4 core is four mechanisms: (i) an executing heredoc's
payload lines (`bash`/`sh`/`zsh`/`dash`/`ksh`/`source`/`.`) are no longer
skipped when the alias scan looks for a pure env-file spelling; (ii) every
body's redirects are classified — a target that resolves to `env` or
`unknown` refuses, `other` is accepted, and nested substitutions recurse to
depth 8 and refuse on overrun; (ii') inside a body, an unmodelled write
mechanism refuses only when it is a carrier (`eval`, `trap`, `sh -c`, …),
because the name-writing mechanisms (`read`, `mapfile`, `printf -v`) are
subshell-local in a `$( … )` and cannot write the env file; (ii'') a
physical line that ends in an unescaped `\\` and contains an unclosed
`$( … )`/backtick whose partial text already shows a redirection refuses.
A6 adds five widenings: (v) a carrier shell/interpreter named by basename
(`/bin/bash`, `/usr/bin/env bash`); (vi) a pure variable in command
position with `-c` (`$SHELL -c …`) is fail-closed; (vii) interpreter
programs by basename and version suffix (`python3`, `python3.12`, `perl`,
`ruby`, `node`, `php`, `awk -v`); (viii) `tee`/`dd of=` argv file targets
are classified with the alias/assignment resolver; (ix) a carrier operand
that is exactly one variable expansion (`eval "$CMD"`) cannot be proven
disjoint and refuses. A7 (fold round 1) adds four widenings: (x) a shell
command flag in a short-option cluster (`bash -ec`, `sh -lc`) is the same
carrier as the bare `-c`, for the carrier table and for the `$VAR`
command-position widening alike, while `-l`/`--noprofile` stay
non-carriers — retained for defence-in-depth only: once (xvi) exists the
cluster rule closes no malicious shape (measured: reducing it to an exact
`-c` leaves the whole corpus green), and its independent effect is the
class of benign `-Xc` cluster over-refusals whose `$`-free command string
names a traced value (`w=$(bash -ec 'SOURCE_RUN_ID=1 true')` and the
`-lc`/`-ilc`/`sh -lc`/`-xc` spellings of the same string, five measured,
all runtime benign) rather than one shape; (xi) the
substitution-body argv deferral applies only when
the enclosing segment has no env redirect of its own — when the segment's
redirect IS the env file the outer per-segment reference accounting never
runs, so a `tee`/`dd of=` target of the exact env spelling refuses with
the argv diagnostic; (xii) `<( … )`/`>( … )` are recognized as
substitution openers, and a redirect target that is the exact env
spelling plus a trailing `)` (or, for nested substitutions, several) is
the env file when the continuation-joined line carries a real opener
(the shell lexer splits an unquoted opener, gluing the substitution's
`)` to the target), while a literal filename that is not the exact env
spelling plus glued parens stays untouched — a literal `"$GITHUB_ENV))"`
target on a real-opener line refuses and is a named benign over-refusal;
the target-classification half carries the measured closures,
and the `<( … )` branch in `_substitution_bodies` is defense-in-depth for
bodies the word scan does not otherwise re-tokenize; (xiii) a
recognized interpreter invoked with an inline-program flag (`python3 -c`,
`perl -e`, `ruby -e`, `node -e`/`-p`, `php -r`) classifies the remaining
non-flag argv words as potential file targets with the `tee`/`dd of=`
resolver (`sys.argv[1]`, `$ARGV[0]`, `ARGV[0]`). A8 (fold round 2) adds
three widenings and one guard refinement: (xiv) the trailing-`)` rule
strips every glued closing parenthesis (`text.rstrip(")")`), so a nested
`<(cat <( … ))`/`>(cat >( … ))` body — whose target carries two `)`s
— is still the env file; (xv) an inline-program flag is recognized in a
short-option cluster (`python3 -uc`, `perl -we`), as an attached argument
(`-cPROG`, `-ePROG`, `-rPROG`, `--flag=value`) and as perl's alternate
`-E`; every attached spelling is dead for `node` (runtime `bad option`),
so `node -e'attached'` stays accepted as a non-carrier; and (xvi) a
recognized shell with a `$`/backtick-bearing argv word (`f=-ec; bash $f
…`, `bash -e$f …`) is fail-closed because the word may be the command
flag (for the measured A7 F1 fixtures this subsumes the (x) cluster rule,
because every POSIX env-write command string carries a `$`). A9 (fold
round 3) closes two runtime-proven inline-program spelling gaps: (xvii)
`node -pe` — node's only accepted short-option cluster (`-p` then `-e`,
program = the next word) is recognized as an inline program, while every
other node cluster (`-ep`, `-ee`, `-ie`, `-pi`, `-vpe`, `-px`, …) and
every attached node spelling stays unrecognized (runtime `bad option`);
and (xviii) php's `-B`/`-E`/`-R` inline programs (before/after/per-line
input), which take the code as the next word and can write the argv
target, are recognized next to `-r` (the attached `-B'code'` spelling
previously refused only by accident, because the `-r` cluster rule
matched an `r` inside the code text); A10 (fold round 4) extends (xviii)
to php's long spellings — `--run`/`--process-begin`/`--process-end`/
`--process-code` (php-src's CLI option table maps each short flag to
that name; the long flag takes the program as the next word or after
`=`) are recognized like the short forms, after the A9 re-lens measured
all four accepted while runtime-live. A11 (fold round 5) closes the
interpreter sibling of A8's (xvi): (xix) a recognized interpreter whose
argv carries a `$`/backtick-bearing word and no literal inline-program
flag (`F=-r; php $F 'prog'`, `php $'--run' 'prog'`, `F=-c; python3 $F
'prog'`, `F=--eval; node $F 'prog'`) is walked as a carrier: every argv
word is treated as a candidate command string / file target, and the
invocation is refused when a walked word cannot be proven harmless (it
names the env file or a traced value, or is an unresolvable value that may
be a file target). That is the same fail-closed shape as the
runtime-assembled shell command flag (D5). The walk is content-driven, so
a benign invocation with an unresolved argv word is refused only when that
word trips the content test; an unresolved *command-substitution* operand
whose remaining words are harmless is still accepted, which is the
already-named "a carrier operand that is itself a command substitution"
residual. The opener
scan is quote/comment-aware: a quoted or commented `<(` no longer counts,
so a literal `$GITHUB_ENV)` filename stays untouched (fold round 2
MINOR-1). Boundary sentence: the
gate refuses any recognized carrier invocation (shell/interpreter by
basename and version suffix, a short-option cluster containing `c`, a
pure variable with a command flag, a `$`-bearing shell argv word,
`eval`/`trap`, `awk -v`), recognized argv write verb (`tee`, `dd of=`) or
recognized inline-program interpreter — in every spelling that
interpreter accepts (exact, clustered, attached, `--flag=value`, the
long `--flag` followed by the program word, or a runtime-assembled /
ANSI-C-quoted flag word: `F=-r; php $F …`, `php $'--run' …`, `F=-c;
python3 $F …`, `F=--eval; node $F …`) —
whose carried command string or
file target cannot be proven
disjoint from the env file — it names the env machinery or a traced
value, is an unreadable pure variable, or has a non-single-resolved
target — while literal/read-only usages and non-write commands stay
accepted.

Measured scope: A7 closes every runtime-proven flip in the measured
family (A6's 382 shapes stay closed; the four new classes' eleven
runtime-proven writes refuse); A8 closes the three re-lens flips — the
nested process substitution, the inline-program flag
clusters/attached/alternate spellings, and the runtime-assembled shell
command flag (13 new closure fixtures, all runtime-proven, plus a
`python3.12 -c` corpus pin for the version-suffix mechanism); A9 closes
the two runtime-proven inline-program spelling gaps the A8 re-lenses
found — `node -pe` and php's `-B`/`-E`/`-R` (4 closure fixtures, all
runtime-proven); A10 (fold round 4) closes php's four long-option
aliases of those inline programs (5 closure fixtures — both `--run`
forms plus one each of `--process-begin`/`--process-end`/
`--process-code` — all runtime-proven); A11 (fold round 5) closes the
runtime-assembled/ANSI-C-quoted interpreter inline-program flag (4
closure fixtures — php short flag via a variable, php's ANSI-C-quoted
`--run`, python3's `-c` via a variable, node's `--eval` via a variable —
all runtime-proven, plus an over-refusal pin for the benign `F=-r; php
$F 'echo 1;'` control). At A12 the fixture corpus is 551/551, of which the 120 A12 fixtures
each declare their measured base verdict (`base_exit`);
at A11 the fixture corpus was 431/431
with zero diagnostic changes on the 426 then-pre-existing cases (`old.CASES
== new.CASES[:426]`), and the real tree stays byte-identical green
(`ios-adhoc-pr.yml`'s `gh api …`, `find …`, `${!name:-}` and continuation
bodies are untouched). The cost is fail-closed over-refusal of 24
measured benign shapes before A8: the 20 pre-A7 ones — A4's 12 (the quoted-heredoc
payload `f15`; the unquoted executing heredoc where the parent expands
the substitution before the alias exists `h01`/`h02b`/`q3` or the child
does not inherit a non-exported alias `k05`; the assembled literal target
`h10`/`h20`; the non-executing `true || n="$GITHUB_ENV"` alias `h28`; a
name-writing mechanism inside a body `fz-o6-i4/i5/i7`; the malformed
no-trailing-newline value `a7`), the lens-v2 `b1` (quoted data scanned as
code), `b2` (heredoc-payload alias then a benign outer read), `d9`/
`d10` (benign nesting depth > 8) and `t18-busybox-sh` (benign on the
probe host, where `busybox` is absent), and A6's three benign-as-stored
argv targets `t03`/`t04`/`t20` — plus A7's one new class (4 measured
shapes): an interpreter's trailing argv word that is a shell expansion
the extractor cannot resolve (`python3 -c`/`perl -e` with a `$MESSAGE`
or assembled `${x}${y}` value argument, pinned by
`reject-overrefusal-interpreter-expansion-argv`); plus A8's two new
classes / 8 measured benign shapes in the fold's own A7→A8 battery (the
A8 re-lens's independent battery found 11 instances of the same
shell-variable class): a recognized shell with an unreadable variable
operand (`bash "$script"`, `bash script.sh "$arg"`; benign, pinned by
`reject-overrefusal-shell-variable-operand`) and the attached
inline-program spelling of A7's interpreter-expansion class (`python3
-c'…' "$MESSAGE"`; pinned by
`reject-overrefusal-interpreter-attached-expansion-argv`); plus A9's two newly named pre-existing over-refusals (both refuse on A8
already): the (x) cluster rule's benign `-Xc` over-refusals — its
independent effect is the class whose `$`-free command string names a
traced value, at least the five measured `-ec`/`-lc`/`-ilc`/`sh -lc`/
`-xc` spellings, all runtime benign; the rule is retained for
defence-in-depth — and a literal target that is the exact env spelling
plus glued parens on a real-opener line (`printf … >> "$GITHUB_ENV))" <
<(true)`; runtime benign); plus A9's new benign instances of A7's
interpreter-trailing-argv class (`node -pe '1+1' "$MESSAGE"`, `php
-B`/`-E`/`-R 'echo 1;' "$MESSAGE"` and the attached
`php -B'echo 1;' "$MESSAGE"`; all runtime benign); plus A10's eight
long-alias spelling instances of the same class (the space and
`=`-attached forms of `--run`/`--process-begin`/`--process-end`/
`--process-code` with a benign program and `"$MESSAGE"`; the class is
named by `reject-overrefusal-interpreter-long-alias-expansion-argv`,
which pins the `--run` space form, and all eight measured spellings are
listed here); plus A11's new instances of the interpreter-argv
over-refusal class: the non-literal-flag spelling (`F=-r; php $F 'echo
1;' -- "${{ github.run_id }}"`, pinned by
`reject-overrefusal-interpreter-runtime-flag-expansion-argv`) and a
script/module invocation whose argv carries an unresolved word
(`python3 script.py "$HOME"`, `python3 -m module "$VAR"`, `node x.js
"$HOME"`, `perl x.pl "$HOME"`, `php x.php "$HOME"`, `python3
"$SCRIPTPATH"`; the A11 re-lens measured six such instances, none
fixture-pinned) — at least
24 + 8 + 5 + 8 + 1 = 46 measured benign shapes at A11, plus that named
script/module sub-class (≥45 at A10, ≥37 at A9); every
class is named, the pre-A8 classes are pinned by the
`reject-overrefusal-*` fixtures, and the two A9-named shapes are
documented here (they have no fixture).
A8 also removes A7's uncounted F3 false red: a quoted or commented `<(`
no longer turns a literal `$GITHUB_ENV)` filename into the env file
(pinned accepted by the quoted-process-substitution literal-target
fixture).

A12 (the #346+#347 fold) closes three families and rewrites the mention
walk. Claimed mechanisms:
(vii-a) the verb-specific argv write table (`sed`, `cp`, `mv`, `install`,
`touch`, `truncate`, added to `tee`/`dd`) with the narrow target
predicate: a target refuses only when it names the env file, carries
`$(`/backtick/`${!}`/an env spelling, or is a PURE variable (`$p`) whose
name an unmodelled assignment form (`_UNMODELLED_WRITE_VERBS`:
`read`/`readarray`/`mapfile`/`declare`/`local`/`typeset`/`readonly`/
`unset`/`getopts`/`printf`/`for`/`select`/`trap`/`eval`/the shells)
writes — the measured `printf -v`/`read`/`declare` and
`mapfile`/`readarray`/`getopts`/`readonly`/`unset` spellings all refuse;
multi-piece targets that name only unassigned variables
(`$OUT_DIR/VVTerm.ipa`) stay accepted. sed additionally classifies its
`w`/`W` script-command target for an address-prefixed (`1w`, `1 w`,
`$w`, `/re/w`, a `/regex/` address whose regex carries the standard
escaped delimiter (`/a\\/b/`, in both the raw `\\/` and the
double-quoted-source `\\\\/` spelling), a comma-separated range —
`1,+3w`, `/re/,/re2/w`, `0,/re/w`, a `!`-negated address or range
(`1!w`, `$!w`, `1,2!w`,
`/re/!W`, `1! w`), the general GNU alternate-delimiter `\\cREc`
address (`\\,re,`, `\\%re%`, `\\#re#w`, `\\|re|w`, `\\@re@w`) in
either range position and in both the raw `\\c…c` and the
double-quoted-source `\\\\c…c` spelling, or a
`{`-glued block opener — negated or not), newline-separated or
physically line-spanning quoted script, and recognizes `--in-place`/`--in-place=SUFFIX` and any
non-empty abbreviation of the option name (`--i`, `--in`, `--in=.bak`;
GNU getopt_long accepts any unambiguous prefix, and `in-place` is sed's
only long option starting with `i`), `-i`/`-iSUFFIX`, an attached `-e`
script (`-eSCRIPT`, `-nEeSCRIPT`) or a short-option cluster containing
`i` (`-ni`, `-Ei`), and the BSD `-i ''` extension word (sed's `s///w
file` flag and `-f` script bodies stay residual).
(vii-b) the carrier-substitution test (`trap`/`eval`/`sh -c`/`bash -c`/
`$SHELL -c`, and an interpreter inline-program operand) refuses an
operand containing any command substitution — including arithmetic
`$((` — or backtick, with ANSI-C `$'…'` spellings decoded for that test
only (the quoted form and the quote-stripped token form); a
substitution passed as data after a shell script path (`bash script.sh
"$(mktemp)"`) or as a positional (`bash -c 'echo "$1"' _ "$(mktemp)"`)
stays accepted. An interpreter inline program is refused fail-closed and
its diagnostic says so instead of claiming the operand names the value.
(vii-c) `_mentions_github_env`'s 64-character window walk runs over the
raw text and every text reachable by a bounded elision that combines a
quote/escape/comment-aware balanced scanner for `$(…)`/`${…}` regions
with a regex fallback for the simple spellings, backticks, backslash
continuations and unbraced `$NAME`/`$@`/`$*`/`$?`/`$!`/`$N` pads, so
any balanced `${…}`/`$(…)` pad whose interior is a comment
parenthesis, a quoted or escaped parenthesis or quote, a subshell, a
process substitution, an ANSI-C `$'…'` string (an escaped `\\'` does
not close it, and the `$` + backslash-newline + `'…'` continuation
spelling is the same string), a backtick region (opaque to the
parenthesis depth), a `}` inside a backtick or `$(…)` region of a
`${…}` pad, or a nested `$(…)` carrying its own quotes inside a
double-quoted region cannot keep the halves apart; the escaped-`\\$…` guard is pinned,
while the bare-`$GITHUB` guard is defence-in-depth (the scanner's
braced-only candidate subsumes it — `mut-F-guard-notgithub-off` reds
0); a `case`-pattern terminator `)` inside the pad and a `$(…)` body
whose heredoc hides the halves are the scanner's named residuals (the
fail-closed last-`)` rule was measured with 0 corpus flips and rejected
because it subsumed the ANSI-C/backtick lexer fixes; the block-scalar
capture keeps the raw indentation while the runner executes the dedented
text, so the ANSI-C lookahead skips spaces/tabs after a backslash-newline
to model the runner's text — the gate-text/runner-text divergence remains
a named limit, and dedenting block bodies is the principled fix); the raw
text is
always walked, so every base mention is kept (the elided-only walk
lost nine measured strings and reopened four runtime-proven flips,
pinned by
`reject-runid-github-env-write-mention-window-split-spelling`).
Measured at the fold: `--selftest` 551/551; `--root .` byte-identical
green; the 26-shape #346/#347 battery keeps the 20-closed / 6-residual
split; 45 falsifying mutants red each mechanism's own fixtures and no
others (the red-set matrix is the bleed check). Over-refusal accounting:
the fold adds at least 16 measured benign shapes (base ACCEPT -> refuse)
over nine named classes, each class pinned by at least one
`reject-overrefusal-*` fixture — `m1-long-expansion-assembly`; the pad
class (`$?`/`$0`/`$!` spellings); `eval "echo $(date +%s)"`; the six
lens-3 new-verb witnesses (`cp`/`mv`/`install`/`touch`/`truncate`/`sed
-i` with a `$(mktemp)` target); a pure target written by `printf -v`
(`printf -v p … ; cp payload "$p"`); an interpreter inline program
containing a `$(`; `eval` arithmetic `$((`; the ANSI-C quoted form in a
double-quoted operand; and a bare `$GITHUB` name the elided walk keeps.
The floor is at least 46 + 16 = 62 measured benign shapes at A12. The
fold does not close: sed's `s///w file` flag and `-f` bodies, interpreters outside the inline-program table
(`lua -e`, `tclsh`) and script files / `-m module` / stdin-fed programs
/ process-substitution script operands, the xargs wrapper/assignment/
continuation spellings (`env xargs`, `FOO=1 xargs`, `nice xargs`,
`command xargs`, `time xargs`, `xargs … < pf`, a trailing-`|` or
backslash multi-line pipeline — the bare `… | xargs cp payload {}` form
now refuses), the
no-mention job-env assembly (`s2a`), the created-or-aliased
basename, and a `$(…)` body whose unmodelled heredoc hides the halves
(a substitution-body heredoc is the scanner's named residual), and a
`case`-pattern terminator `)` inside a `$(…)` pad (the balanced
scanner counts the grammar `)`; measured ACCEPT at the fold with a
runtime FLIP, and the fail-closed last-`)` elision was measured and
rejected).

Named residuals (re-filed in #350): a caller (`workflow_call`) or dispatcher
(`workflow_dispatch`) can pass its own `github.run_id` as an `inputs.*`
value (no `workflow_call` exists in this repo, and trigger parsing is
deliberately not modelled); a `$GITHUB_ENV` write whose name pieces never
appear in the body text (`$RUNNER_TEMP/_runner_file_commands/set_env_*`)
is not detected, the inherited text-detector boundary (the padded
64-character-window class — including any balanced `${…}`/`$(…)` pad the
scanner or the bounded regex fixpoint removes (a comment, a quoted or
escaped parenthesis or quote, a subshell, a process substitution, a `}`
inside a backtick/`$(…)` region, a nested `$()` inside double quotes or
an ANSI-C continuation string inside it) — is closed by A12; the name text must still appear; a `$(…)` body
whose heredoc hides the halves, the `\\$NAME`/single-quoted-`$GITHUB`
spellings the unbraced elision deliberately skips and the NUL/`$'…'` name
concatenation spellings the bounded empty-pad elision does not cover
(`$'\\x00'`, `$'\\000'`, `$'\\u0000'`, `$'\\c@'`, `$'\\0\\000'`, `$'\\x0'`,
`""`; the `''` and `$'\\0'`-only forms now refuse) are outside the walk's
claimed text); a `source`d or
`.`-sourced script's body, a `bash script.sh` path and an interpreter
script file or `-m module` (`python3 /tmp/evil.py`, `python3 -m evilmod`;
only the inline-program string is inspected), an interpreter fed its
program on stdin with no unresolved argv word (`echo 'code' | python3 -`,
`ruby -`, `perl -`; the argv-carrying spelling is refused by A11's walk)
or a process-substitution script operand (`php -f <(code)`, `python3
<(…)`; measured ACCEPT, runtime-malicious on A11 too);
a carrier whose command
string is assembled at runtime
(`eval "$cmd"`: the carrier is seen, but a string that never mentions the
env file or a traced name is the inherited textual boundary); an argv
operand fed on stdin behind a wrapper, an assignment prefix or a
continuation (`env xargs`, `FOO=1 xargs`, `… |` newline `xargs`) sits
outside the argv verb table (the bare `… | xargs cp payload {}` form
refuses since A13);
other
argv write verbs that need verb-specific semantics are closed by A12
(sed `-i`/`--in-place` (and its abbreviations)/`w` targets,
`cp`/`mv`/`install` last operand,
`touch`/`truncate` every operand); interpreters outside the inline-program
table (`lua -e`, `tclsh`, a script file); a shell/interpreter basename
outside the mechanism tables — including one the run creates (`ln -sf
/bin/sh ash`, then `w=$(./ash -c "printf '%s\\n' SOURCE_RUN_ID=${{ github.run_id }}
>> \\$${x}${y}")`: the tables key on the basename; measured ACCEPT,
runtime-malicious); substitution nesting deeper than
8; and a heredoc opened inside a substitution body, which the inner scope
does not model. The A7, A8, A9, A10 and A11 widenings are not residuals: the cluster
spelling, the deferral with an enclosing env redirect, process
substitution, the interpreter argv file targets, the nested glued parens,
the inline-program flag cluster/attached/`--flag=value`/`-E` spellings,
the `node -pe` cluster, the php `-B`/`-E`/`-R` inline programs and their
`--run`/`--process-begin`/`--process-end`/`--process-code` long aliases,
the runtime-assembled shell command flag, the runtime-assembled /
ANSI-C-quoted interpreter inline-program flag, and the A12 argv-verb /
carrier-substitution / raw-OR-elided mention-walk mechanisms are refused
by the mechanisms above.
A13 (the #350 fold) closes the measured spellings of the array-element
write-target family — `${arr[0]}` (plain or on a backslash-continuation
line), `read 'arr[0]'`, `printf -v 'arr[0]'`, `mapfile -t arr`,
`readarray -t arr` and `read -a arr` — plus the backslash-continuation
spelling of an argv-write target. The family's bash-valid sibling
spellings stay accepted boundary pins (an offset-suffix matcher or a
literal-newline word join is a new mechanism, deferred): the array slice
`"${arr[@]:0}"`, the scalar offset `"${arr:0}"` and a target word split
by a literal newline inside a double quote (`"${arr[` + newline +
`0]}"`); an open single-quote or ANSI-C `$'…'` word does not join the
next physical line even when it ends in `\\` (bash does join it; the
continuation join exists only for the double-quote spelling — fold
round 2 MINOR-2). Claimed mechanisms:
(viii-a) `_LOCAL_REFERENCE_RE` and `_expansion_names` accept an optional
`[...]` array subscript and contribute the base name, so a target spelled
`${arr[0]}` joins the relevance set through the same narrow
pure-reference predicate that keeps a multi-piece `$OUT_DIR/x` accepted
(a nested `$i` index is dropped deliberately: the base name is what the
relevance set needs); (viii-b) the read-operand parser contributes the
base name of an array-element operand (`read 'arr[0]'`) and uses a
mapfile/readarray option table in which `-t` is a flag rather than an
option argument, so `mapfile -t arr`/`readarray -t arr` no longer lose
the array name; (viii-c) a bounded pre-pass joins a physical line ending
in an unquoted backslash, adds the joined argv-write targets' base names
to the relevance set, and skips heredoc payload lines, while the joined
segments also feed the narrow argv-target scan; the continuation test
stops at an unquoted `#` comment word (fold round 1 MAJOR-2(b): bash ends
the comment at the physical newline, so a backslash-terminated comment no
longer suppresses the real continuation on the next line), and that
comment test is escape-aware (fold round 2 MAJOR-1): whitespace the scan
skipped as the second half of a `\\X` escape pair is part of the word, so
`foo\\ #bar \\` (and its escaped-tab twin) is a real continuation, not a
comment — pinned by
`reject-runid-github-env-write-array-element-escaped-whitespace-comment-target`;
the comment-start class remains whitespace-or-line-start, so `;#`, `|#`,
`&#` and `(#` stay read as continuations (a pre-existing fail-closed
over-refusal, recorded here, not folded — fold round 2 MINOR-1), and
`_line_leaves_double_quote_open` still uses the pre-fold escape-blind
comment test (pre-existing, recorded, not folded — fold round 2 NIT-2);
a continuation
longer than 8 physical lines and a continuation inside a command
substitution (`w=$(cp payload \\` + newline + `"${arr[0]}")`) stay open
(named residuals); the comment spellings are pinned by
`reject-runid-github-env-write-array-element-comment-continuation-target` and
`reject-runid-github-env-write-array-element-escaped-whitespace-comment-target`; (viii-d) the
`_HEREDOC_RE` guard `(?<!<)<<-?(?!<)` stops a here-string (`<<<`) from
being read as a heredoc opener, so the line after it is walked as shell
(`<<<<`/`<<<<<` are bash syntax errors and `<<<-` is a here-string, so no
genuine heredoc is missed); (viii-e) an `xargs` segment refuses when its
upstream pipeline text can carry the stdin operand — it names the env
file, references a traced name, or carries a command substitution/
backtick; the per-line site also refuses a `$`-bearing upstream word the
extractor cannot resolve, while the substitution-body site (issue #350,
item 2's `$(…)`-nested spelling) drops that word catch so the real-tree
witness `name="$(echo "$raw" | xargs)"` stays accepted; the
wrapper/assignment-prefix/trailing-`|` spellings stay accepted boundary
pins (a new command-position mechanism, deferred), as does an
assignment-wrapped nested form whose upstream is a bare command
(`w=$(printenv "${x}${y}" | xargs -I{} cp payload {})`; the relaxed
substitution-body site drops the `$`-word catch, so the bare upstream is
not refused — fold round 1 MAJOR-1, a named residual that
runtime-FLIPs); (viii-f) the sed argv
branch recognizes every unambiguous abbreviation of `--expression`
(`--e=`, `--ex=`, `--expr=`, `--expre=`, `--expressio=`, both separated
and `=`-attached), so the abbreviated expression's `w` target is
classified; the rule deliberately stops at `expression` (`--f` is
ambiguous between `--file` and `--follow-symlinks`). A13 also accepts
one measured out-of-corpus class that base refused — the `--e=`-family
abbreviations `--e=`, `--ex=`, `--expr=`, `--expre=` and `--expressio=`
(`sed -n --e=x 'w $(printenv …)' payload` is the representative; base
REFUSE → A13 ACCEPT, runtime cross-run):
recognizing `--e=x` reclassifies the first positional from script
candidate to file operand, so a target base scanned as a script is no
longer scanned; the direction is correct (the base refusal was a
misparse) and the corpus cannot represent it (`base_exit: 1` +
`exit: 0` is a hard selftest failure); (viii-g) the sed script join treats
an unclosed single quote like an unclosed double quote, so the BSD `$a\\`
two-line append (and a single-quoted `w` command split across physical
lines) is tokenized whole and its target classified; the join only feeds
the sed `w`/`$a\\` scan, so it can only add refusals, and the two benign
multi-line single-quoted controls stay accepted (the GNU-sed run of the
append is a deliberate fail-closed over-refusal, the same platform nuance
as item 6; the BSD run is a real runtime FLIP); (viii-h) the mention
walk's bounded
empty-pad elision removes adjacent empty single-quoted strings (`''`)
and ANSI-C literals whose body is a run of literal `\\0` escapes
(`$'\\0'`, `$'\\0\\0'`) before the 64-character window test — a fail-closed
addition (dropping a pad can only add mentions) that closes 3 of the 10
measured NUL spellings; item 8 stays a boundary class: `$'\\x00'` and `""`
are pinned as accepted boundary fixtures, and the other five measured
survivors (`$'\\000'`, `$'\\u0000'`, `$'\\c@'`, `$'\\0\\000'`, `$'\\x0'`)
stay accepted and are recorded here. Measured at A13: the fixture corpus is
594/594, of which 163 fixtures declare their measured base verdict
(`base_exit`); the array-element family adds 4 over-refusal pins under
two root causes — 3 unmodelled-write shapes (any unmodelled write of the
now-relevant base name refuses) and 1 no-write target mention (the
occurrence backstop refuses a target that mentions the base name) — item
2 adds its unresolved-upstream pin, item 7 adds its GNU-proxy fail-closed
class (measured on the converted append fixture: the same body
runtime-FLIPs under BSD sed, so the benign GNU run is recorded here
rather than separately pinned), and item 8's elision adds the hidden-name
echo class (now pinned), bringing the measured benign floor to
62 + 4 + 1 + 1 + 1 = 69. The A13 boundary (stays open, never implied
closed) is items 3, 4, 5, 6, 8, 10, 11 and the item-2
wrapper/assignment/continuation class, plus the newly named array
slice/offset and literal-newline-subscript spellings, the
substitution-nested continuation and the assignment-wrapped nested form;
the boundary pins for all of these are committed at this commit.
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
EXPECTED_MANIFEST_CASES = 594

# The scan floor. A typo'd `--root` (or a truncated checkout) must not look
# like a pass; update this constant only when workflows are intentionally
# removed (and then update the pin suite too).
MIN_SCANNED_WORKFLOW_FILES = 12
# A12's fixtures (45 at the round-1 fold + 24 at the round-2 fold + 15 at
# the round-3 fold + 15 at the round-4 fold) each declare the measured
# exit of the pre-fold gate
# (150a56a3) as `base_exit`; `--selftest` refuses an accept-widening (base
# REFUSE -> folded ACCEPT) and any base-REFUSE reject fixture that is not
# one of the documented pre-existing pins, so a double-caused fixture
# cannot hide behind a verdict the new mechanism did not cause. Limit:
# `--selftest` cannot re-run the historical gate, so an honestly recorded
# double cause reds but a *false* `base_exit: 0` still passes; the field
# is reviewable data backed by the measured counterfactual evidence, not a
# re-measurement (fold round 3 lens-2 MINOR-3, documented not overclaimed).
EXPECTED_BASE_VERDICT_CASES = 163
A12_BASE_REFUSAL_PINS = frozenset(
    {
        "reject-runid-github-env-write-mention-window-split-spelling",
        "reject-runid-github-env-write-sed-n-read-assigned-file",
    }
)

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


# The elision set for the mention-window walk: braced expansions, simple
# command substitutions, backticks, backslash-newline continuations, and
# UNBRACED `$NAME`/`$@`/`$*`/`$?`/`$!`/`$N` padding. The unbraced
# alternative deliberately skips a backslash-escaped `$` (the `\$GITHUB` in
# the `w2` family is literal text for the later `eval`) and a name beginning
# with `GITHUB`: eliding the first conjunct would delete the mention the walk
# is supposed to preserve (issue #347, fold lens-1 MAJOR-5). `$?`/`$!`/`$N`
# are elided too even though they expand to digits or a pid — the direction
# is fail-closed over-refusal, not miss (fold lens-1 round 2 MAJOR-3).
_EXPANSION_ELISION_RE = re.compile(
    r"\$\{[^{}]*\}"
    r"|\$\([^()]*\)"
    r"|`[^`]*`"
    r"|\\\n"
    r"|(?<!\\)\$(?!GITHUB)[A-Za-z_][A-Za-z0-9_]*"
    r"|(?<!\\)\$[@*?!]"
    r"|(?<!\\)\$[0-9]+",
    re.DOTALL,
)

# The empty-pad elision for the mention-window walk: a zero-width pad made
# of adjacent empty single-quoted strings (`''`) or an ANSI-C literal whose
# body is a run of literal `\0` escapes (`$'\0'`, `$'\0\0'`). Dropping it
# can only add mentions, so the direction is fail-closed. The class is
# deliberately bounded: it closes 3 of the 10 measured NUL spellings and
# the two representative survivors (`$'\x00'`, `""`) are pinned as
# boundary accepts while the other five (`$'\000'`, `$'\u0000'`,
# `$'\c@'`, `$'\0\000'`, `$'\x0'`) stay accepted and are recorded here;
# a complete closure needs an ANSI-C/empty-pad normalizer (issue
# #350, item 8, un-folded to the boundary).
_EMPTY_PAD_ELISION_RE = re.compile(r"''|\$'(?:\\0)+'")

# The elision runs to a bounded fixpoint. Two mechanisms cooperate and
# disagree about order: the regex fallback's braced alternative must
# consume a `${…}` before the unbraced `$NAME` alternative can swallow a
# trailing `ENV` (`GITHUB_$A…$A${A}ENV`), while the balanced scanner must
# see a `$(…)` whole before the regex can remove only its first
# `[^()]*`-shaped fragment (an interior escaped quote/comment paren). The
# walk therefore closes over every text reachable by applying either
# operation, in any order, bounded by `_EXPANSION_ELISION_MAX_PASSES`; the
# raw text is one of the candidates, so no base mention is ever lost, and
# exhausting either bound refuses fail-closed. The regex pass alone cannot
# flatten an outer `${…}`/`$(…)` whose interior holds an inner one (fold
# lens-1 round 3 MAJOR-1); the scanner removes any balanced region (however
# nested) in one pass.
_EXPANSION_ELISION_MAX_PASSES = 8

# A guard against a pathological candidate explosion: every candidate is
# strictly shorter than its parent, so the reachable set is finite, but the
# bound keeps the walk cheap and refuses fail-closed if it is ever hit.
_EXPANSION_ELISION_MAX_CANDIDATES = 64


def _elide_balanced_expansions(text: str) -> str:
    """`text` with every balanced `$(…)`/`${…}` region removed, with
    nesting, quotes, escapes and `#` comments honoured (re-lens 3
    BLOCKER-1). The regex fallback in `_mentions_github_env` still removes
    the simple spellings, backticks, backslash continuations and unbraced
    `$NAME`/`$@`/`$*`/`$?`/`$!`/`$N` pads; this scanner exists because the
    regex alone cannot elide a `$(…)` whose interior carries a parenthesis
    (a comment, a quoted argument, an escaped paren, a subshell, a process
    substitution), and a pad the elision cannot flatten keeps the
    `GITHUB`/`ENV` halves apart and skips the whole run-id scan. An
    unclosed construct deletes the rest of the text from the elided half
    only; the raw half is walked separately, so the delete stays
    fail-closed in the mention direction."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(text[i : i + 2])
            i += 2
            continue
        if c == "'":
            end = text.find("'", i + 1)
            end = n if end == -1 else end + 1
            out.append(text[i:end])
            i = end
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            i = _consume_command_substitution(text, i)
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "{":
            i = _consume_braced_expansion(text, i)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _mention_candidates(text: str) -> set[str] | None:
    """Every elision of `text` reachable by applying the regex fallback
    and the balanced scanner in any order, to a bounded fixpoint. `None`
    when either bound is exhausted (the caller treats that as fail-closed).
    The raw `text` is included, so the mention walk keeps every base
    mention."""
    seen = {text}
    frontier = [text]
    for _ in range(_EXPANSION_ELISION_MAX_PASSES):
        next_round: list[str] = []
        for candidate in frontier:
            for collapsed in (
                _EXPANSION_ELISION_RE.sub("", candidate),
                _elide_balanced_expansions(candidate),
                _EMPTY_PAD_ELISION_RE.sub("", candidate),
            ):
                if collapsed != candidate and collapsed not in seen:
                    seen.add(collapsed)
                    next_round.append(collapsed)
        if not next_round:
            break
        if len(seen) > _EXPANSION_ELISION_MAX_CANDIDATES:
            return None
        frontier = next_round
    else:
        return None
    return seen


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
    # Monotonicity: the raw-text walk is the base behaviour and must stay.
    # Eliding expansions can DELETE one half of a spelling the raw text
    # carries (`GITHUB_$(echo ENV)` -> `GITHUB_`), so the walk gate would skip
    # a body the base gate walked and reopen a runtime-proven fail-open.
    # Walk every candidate: raw (never lose a base mention) and every
    # bounded elision (close the window-spanning assembly).
    candidates = _mention_candidates(text)
    if candidates is None:
        return True
    for candidate in candidates:
        start = candidate.find("GITHUB")
        while start != -1:
            if "ENV" in candidate[start + len("GITHUB") : start + GITHUB_ENV_WINDOW]:
                return True
            start = candidate.find("GITHUB", start + 1)
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
# A whole shell word that is exactly one local expansion (`${NAME}`/`$NAME`,
# with an optional `[...]` array subscript). The subscript-aware form lets
# an argv-write target spelled `${arr[0]}` join the relevance set through the
# same narrow predicate, while a multi-piece target (`$OUT_DIR/x`) still does
# not (issue #350, item 1).
_LOCAL_REFERENCE_RE = re.compile(
    r"^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]\n]*\])?\}"
    r"|([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]\n]*\])?)$"
)
# A heredoc operator plus its delimiter (`<<EOF`, `<<'EOF'`, `<<-EOF`).
# The `(?<!<)`/`(?!<)` guards keep a here-string (`<<<`) from being read as
# a heredoc: without them the regex matches the `<<` formed by the second
# and third `<`, so the next line is misclassified as heredoc payload and
# skipped (issue #350, audit-found defect). `<<<<`/`<<<<<` are bash syntax
# errors and `<<<-` is a here-string, so no genuine heredoc is missed.
_HEREDOC_RE = re.compile(
    r"(?<!<)<<-?(?!<)[ \t]*(?:\"([^\"]*)\"|'([^']*)'|([A-Za-z_][A-Za-z0-9_]*))"
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
# Interpreters whose inline program operand (`python3 -c`, `perl -e`,
# `awk …`) is shell-adjacent code that can write a file: the program
# operand is a carrier, and an awk `-v` assignment is one too because it
# can name the program's redirect target (issue #345, lens-v2 t03/t17).
# `php` also runs inline code from `-B` (before input), `-E` (after input)
# and `-R` (per input line), all taking the code as the next word (or
# attached); before fold round 3 the attached `-B'code'` spelling refused
# only by accident, because the `-r` cluster rule matched an `r` inside
# the code text. PHP's CLI option table gives every short flag a long
# name (`-r` -> `--run`, `-B` -> `--process-begin`, `-E` ->
# `--process-end`, `-R` -> `--process-code` on 8.3/8.4/8.5/master); fold
# round 4 added the four long names after the A9 re-lens measured each
# accepted while runtime-live.
_INLINE_PROGRAM_FLAGS: dict[str, tuple[str, ...]] = {
    "python": ("-c",),
    "python3": ("-c",),
    "perl": ("-e", "-E"),
    "ruby": ("-e",),
    "node": ("-e", "-p", "--eval", "--print"),
    "php": (
        "--run",
        "--process-begin",
        "--process-end",
        "--process-code",
        "-r",
        "-B",
        "-E",
        "-R",
    ),
}
_INLINE_PROGRAM_POSITIONAL = frozenset({"awk", "gawk", "mawk", "nawk"})
_INLINE_PROGRAM_VERBS = frozenset(_INLINE_PROGRAM_FLAGS) | _INLINE_PROGRAM_POSITIONAL
# Interpreters whose short inline-program flag accepts a glued argument
# (`-cPROG`) — the attached branch. `node` is absent: it rejects every
# attached spelling (`-eprog`, `-ePROG`) at runtime (`bad option`), so
# `node -e'attached'` stays accepted as a non-carrier (issue #345, fold
# round 2 D3b; fold round 3 F1).
_INLINE_PROGRAM_GLUED = frozenset({"python", "python3", "perl", "ruby", "php"})
# Interpreters whose inline-program flag may also be recognized in a
# short-option cluster: the glued set plus `node`, whose only accepted
# cluster is the exact trailing-flag word `-pe` (`-p` then `-e`, program =
# the next word; the tuple above checks `-e` before `-p`, so the `e` in
# `-pe` is the last character and yields the next word). Every other node
# cluster (`-ep`, `-ee`, `-ie`, `-pi`, `-vpe`, `-px`, …) is a runtime
# `bad option`, so node is admitted to the cluster branch only for that
# single spelling (issue #345, fold round 3 F1).
_INLINE_PROGRAM_CLUSTERED = _INLINE_PROGRAM_GLUED | {"node"}
# A version suffix on an interpreter name (`python3.12`, `perl5.36`,
# `php8.2`): the base name is the recognized interpreter, so a versioned
# spelling does not evade the carrier check.
_INTERPRETER_VERSION_RE = re.compile(r"^(.*?)([0-9]+(?:\.[0-9]+)*)$")


def _interpreter_core(verb: str) -> str:
    """The table name for an interpreter spelling: `python3.12` resolves
    to `python3`, and any other verb is returned unchanged (issue #345,
    A6 widening (vii))."""
    if verb in _INLINE_PROGRAM_VERBS:
        return verb
    match = _INTERPRETER_VERSION_RE.match(verb)
    if match is not None and match.group(1) in _INLINE_PROGRAM_VERBS:
        return match.group(1)
    return verb


def _inline_program_cluster_spelling(core: str, argument: str) -> bool:
    """True when `argument` is a short-option cluster spelling whose
    inline-program flag the interpreter accepts. A glued interpreter
    accepts the cluster spellings the flag loop models; `node` accepts
    exactly `-pe` and rejects every other cluster at runtime (`bad
    option`), so only that word is admitted (issue #345, fold round 3
    F1)."""
    if core not in _INLINE_PROGRAM_CLUSTERED:
        return False
    if core == "node":
        return argument == "-pe"
    return True


def _short_option_cluster_carries_command(word: str) -> bool:
    """True for an exact `-c` or a short-option cluster that contains `c`
    (`bash -ec`, `sh -lc`): bash reads the command string for a clustered
    `-c` exactly as for the bare flag, so the carrier test must recognize
    both spellings. A long option (`--noprofile`) and a cluster without `c`
    (`-l`) are not carriers (issue #345, fold round 1 F1). Retained for
    defence-in-depth only: once (xvi) exists the cluster rule closes no
    malicious shape (the whole corpus stays green with it reduced to an
    exact `-c`), and its independent effect is the class of benign `-Xc`
    over-refusals whose `$`-free command string names a traced value
    (`-ec`/`-lc`/`-ilc`/`-xc`, and `sh -lc`; five measured, all runtime
    benign)."""
    if word == "-c":
        return True
    return (
        word.startswith("-")
        and not word.startswith("--")
        and len(word) > 2
        and "c" in word[1:]
    )


def _argv_has_command_flag(argv: list[str]) -> bool:
    """True when an argv carries a `-c` command string, exactly or as a
    short-option cluster (issue #345, fold round 1 F1)."""
    return any(_short_option_cluster_carries_command(word) for word in argv)


def _argv_has_unresolved_word(argv: list[str]) -> bool:
    """True when a recognized shell's argv carries a word assembled from a
    `$`/backtick the extractor cannot read (`f=-ec; bash $f \u2026`,
    `bash -e$f \u2026`): the word may be the command flag the shell reads,
    so the invocation cannot be proven not to carry a command string
    (issue #345, fold round 2 D5)."""
    return any("$" in word or "`" in word for word in argv)


def _inline_program_flag(
    core: str, args: list[str]
) -> tuple[int, bool, str] | None:
    """The `(index, attached, program)` inline program of a recognized
    interpreter's argv, or None when no inline-program flag is present (a
    script path is a named residual). The flag is matched exactly, as
    `--flag=value`, and — for the interpreters that accept it — as an
    attached argument (`-cPROG`) or inside a short-option cluster
    (`python3 -uc 'prog'`, `node -pe 'prog'`). For a cluster the program
    is the next word only when the flag character ends the word (`-uc`),
    because the interpreter consumes the rest of the word as the argument
    otherwise (`-cu` is the program `u`); `node` accepts no attached
    spelling and only its single accepted cluster `-pe` is admitted to
    the cluster branch (issue #345, fold round 1 F4; fold round 2 D3b;
    fold round 3 F1)."""
    flags = _INLINE_PROGRAM_FLAGS[core]
    glued = core in _INLINE_PROGRAM_GLUED
    for index, argument in enumerate(args):
        for flag in flags:
            if flag.startswith("--"):
                if argument == flag:
                    if index + 1 < len(args):
                        return (index, False, args[index + 1])
                    return None
                if argument.startswith(flag + "="):
                    return (index, True, argument[len(flag) + 1 :])
                continue
            if argument == flag:
                if index + 1 < len(args):
                    return (index, False, args[index + 1])
                return None
            if not glued and not _inline_program_cluster_spelling(core, argument):
                continue
            if argument.startswith(flag) and len(argument) > len(flag):
                return (index, True, argument[len(flag) :])
            if (
                argument.startswith("-")
                and not argument.startswith("--")
                and len(argument) > len(flag)
                and flag[1] in argument[1:]
            ):
                program_start = argument.index(flag[1], 1) + 1
                if program_start < len(argument):
                    return (index, True, argument[program_start:])
                if index + 1 < len(args):
                    return (index, False, args[index + 1])
                return None
    return None
# One whole shell expansion: `$NAME`, `${NAME}` or `%NAME%`. Used to count
# how many expansion pieces an argv write target is assembled from.
_EXPANSION_PIECE_RE = re.compile(
    r"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)|"
    r"%[A-Za-z_][A-Za-z0-9_]*%"
)
# A word that is exactly one variable expansion (`$SHELL`, `${SHELL}`).
_PURE_VARIABLE_RE = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
# Write verbs whose file operand is an argv word rather than a redirect
# (`tee`, `dd of=…`): a computed operand cannot be seen by the redirect
# classification, so it needs its own target check (issue #345, lens-v2
# t04/t20/t22/t23).
_ARGV_WRITE_VERBS = frozenset({"tee", "dd", "sed", "cp", "mv", "install", "touch", "truncate"})
# `read` options that consume the next word. `-a` is deliberately absent:
# its argument IS the array name that the rule must inspect.
_READ_OPTIONS_WITH_ARGUMENT = ("-d", "-i", "-n", "-N", "-p", "-t", "-u")
# `mapfile`/`readarray` share most option letters but `-t` is a flag there
# (`mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd]
# [-C callback] [-c quantum] [array]`), so the array name must not be
# skipped as its argument (issue #350, item 1).
_MAPFILE_OPTIONS_WITH_ARGUMENT = ("-C", "-c", "-d", "-n", "-O", "-s", "-u")
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


def _consume_backtick_region(text: str, start: int) -> int:
    """The index just past the backtick region opened at `text[start]`,
    with escaped backticks honoured; `len(text)` when the region is unclosed
    (the caller treats that fail-closed). A backtick region is opaque to
    an enclosing parenthesis/brace depth (bash parses it as a separate
    construct), so a `)`/`}` inside it belongs to the backtick command
    (fold round 5, X3; fold round 6, A2)."""
    n = len(text)
    j = start + 1
    while j < n:
        if text[j] == "\\" and j + 1 < n:
            j += 2
            continue
        if text[j] == "`":
            return j + 1
        j += 1
    return n


def _consume_command_substitution(text: str, start: int) -> int:
    """The index just past the `$(…)` opened at `text[start:start + 2]`,
    with quotes, escapes, `#` comments, nested parentheses, ANSI-C
    `$'…'` regions and backtick regions honoured; `len(text)` when the
    substitution is unclosed on the line (the caller's per-line scan
    refuses rather than guesses). Bash starts a `#` comment at the
    beginning of a word, and the comment runs to the next physical line;
    a parenthesis inside a comment must not count toward the nesting
    depth (fold round 4 BLOCKER-1). Inside `$'…'`, `\'` is an escaped
    quote and `\\` an escaped backslash; a backtick region is opaque to
    the depth, so a `)` inside it belongs to the backtick command (fold
    round 5, X2/X3). A backslash-newline continuation before the quote
    is removed by bash before tokenisation, and the runner executes the
    dedented block text, so a dollar followed by a backslash-newline
    continuation and the raw block indentation is the same ANSI-C
    string (fold round 6, A4). Inside a double-quoted region a nested
    `$(…)`/`${…}`/backtick region is consumed whole, so its own quotes
    pair inside the nested construct instead of ending the outer region
    early (fold round 6, A3)."""
    n = len(text)
    depth = 1
    j = start + 2
    while j < n and depth:
        cj = text[j]
        if cj == "$":
            # ANSI-C quoting: `\'` does not close the region and `\\`
            # is an escaped backslash, so the region can carry a raw
            # parenthesis without closing the substitution (fold round
            # 5, X2). A backslash-newline continuation before the quote
            # is removed by bash first (fold round 6, A4).
            k = j + 1
            while k + 1 < n and text[k] == "\\" and text[k + 1] == "\n":
                k += 2
                while k < n and text[k] in " \t":
                    k += 1
            if k < n and text[k] == "'":
                j = k + 1
                while j < n:
                    if text[j] == "\\" and j + 1 < n:
                        j += 2
                        continue
                    if text[j] == "'":
                        j += 1
                        break
                    j += 1
                continue
        if cj == "`":
            j = _consume_backtick_region(text, j)
            continue
        if cj in "'\"":
            quote = cj
            j += 1
            while j < n:
                if quote == '"' and text[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if quote == '"' and text[j] == "$":
                    # A nested `$(…)`/`${…}` inside the quotes is a
                    # separate parsing context: consume it whole so a
                    # quote inside the nested construct does not end the
                    # outer region (fold round 6, A3).
                    if j + 1 < n and text[j + 1] == "(":
                        j = _consume_command_substitution(text, j)
                        continue
                    if j + 1 < n and text[j + 1] == "{":
                        j = _consume_braced_expansion(text, j)
                        continue
                if quote == '"' and text[j] == "`":
                    j = _consume_backtick_region(text, j)
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            continue
        if cj == "\\" and j + 1 < n:
            j += 2
            continue
        if cj == "#" and (j == start + 2 or text[j - 1] in " \t\n;|&()"):
            newline = text.find("\n", j)
            j = n if newline == -1 else newline + 1
            continue
        if cj == "(":
            depth += 1
        elif cj == ")":
            depth -= 1
        j += 1
    return j


def _consume_braced_expansion(text: str, start: int) -> int:
    """The index just past the `${…}` opened at `text[start:start + 2]`,
    with nested `${…}` expansions, quotes and escapes honoured; a
    backtick region and a `$(…)` region are consumed whole, so a `}`
    inside them does not close the expansion (fold round 6, A2);
    `len(text)` when the expansion is unclosed (the caller leaves the raw
    half untouched, so the fail-closed direction is the mention walk).
    The bounded regex fixpoint can flatten nested braces only when every
    level is a simple `${…}`; a brace inside a quoted word is not a
    closing brace (fold round 4 BLOCKER-1)."""
    n = len(text)
    depth = 1
    j = start + 2
    while j < n and depth:
        cj = text[j]
        if cj == "\\" and j + 1 < n:
            j += 2
            continue
        if cj in "'\"":
            quote = cj
            j += 1
            while j < n and text[j] != quote:
                if quote == '"' and text[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if quote == '"' and text[j] == "$":
                    # A nested `$(…)`/`${…}` inside the quotes is a
                    # separate parsing context: consume it whole so a
                    # quote inside the nested construct does not end the
                    # quoted region early.
                    if j + 1 < n and text[j + 1] == "(":
                        j = _consume_command_substitution(text, j)
                        continue
                    if j + 1 < n and text[j + 1] == "{":
                        j = _consume_braced_expansion(text, j)
                        continue
                if quote == '"' and text[j] == "`":
                    j = _consume_backtick_region(text, j)
                    continue
                j += 1
            if j < n:
                j += 1
            continue
        if cj == "$" and j + 1 < n and text[j + 1] == "(":
            j = _consume_command_substitution(text, j)
            continue
        if cj == "`":
            j = _consume_backtick_region(text, j)
            continue
        if cj == "$" and j + 1 < n and text[j + 1] == "{":
            depth += 1
            j += 2
            continue
        if cj == "}":
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


_EXECUTING_HEREDOC_CONSUMERS = frozenset(
    {"bash", "sh", "zsh", "dash", "ksh", "source", "."}
)


def _heredoc_consumer_is_executing(line: str) -> bool:
    """True when the heredoc-opening line names an executing consumer
    (`bash <<'EOF'`, `source /dev/stdin <<'INNER'`), so the payload is shell
    code the inner shell runs (issue #345, Option A (i))."""
    head = line.split("<<", 1)[0]
    return any(
        token[0] == "word" and token[1] in _EXECUTING_HEREDOC_CONSUMERS
        for token in _shell_tokens(head)
    )


def _executing_heredoc_payload_lines(lines: list[str]) -> set[int]:
    """Payload line indices of heredocs whose consumer is an executing verb:
    those lines are shell statements for the inner shell, so a
    pure-spelling alias definition on one is a real alias (issue #345,
    Option A (i))."""
    executing: set[int] = set()
    index = 0
    while index < len(lines):
        match = _HEREDOC_RE.search(lines[index])
        if match is None:
            index += 1
            continue
        delimiter = match.group(1) or match.group(2) or match.group(3)
        is_executing = _heredoc_consumer_is_executing(lines[index])
        cursor = index + 1
        while cursor < len(lines) and lines[cursor].strip() != delimiter:
            if is_executing:
                executing.add(cursor)
            cursor += 1
        if cursor >= len(lines):
            break
        index = cursor + 1
    return executing



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


def _mask_quoted_and_commented(line: str) -> str:
    """`line` with quoted spans and the comment tail blanked to spaces, so
    a `<(`/`>(` that is only quoted data or comment text is not read as a
    process-substitution opener (issue #345, fold round 2 MINOR-1). The
    scan is deliberately local to quoting: a `$(`/backtick body keeps its
    text, because a real opener inside one still belongs to the line."""
    masked = list(line)
    n = len(line)
    index = 0
    word_start = True
    while index < n:
        char = line[index]
        if char in " \t":
            word_start = True
            index += 1
            continue
        if char == "#" and word_start:
            for tail in range(index, n):
                masked[tail] = " "
            break
        if char in ";&|<>":
            # `_shell_tokens` treats an operator as a word boundary, so a
            # `#` directly after one opens a comment there too.
            word_start = True
            index += 1
            continue
        word_start = False
        if char == "'":
            end = line.find("'", index + 1)
            end = n if end == -1 else end + 1
            for quoted in range(index, end):
                masked[quoted] = " "
            index = end
            continue
        if char == '"':
            end = index + 1
            while end < n:
                if line[end] == "\\" and end + 1 < n:
                    masked[end] = " "
                    masked[end + 1] = " "
                    end += 2
                    continue
                if line[end] == '"':
                    masked[end] = " "
                    end += 1
                    break
                masked[end] = " "
                end += 1
            masked[index] = " "
            index = end
            continue
        if char == "\\" and index + 1 < n:
            masked[index] = " "
            masked[index + 1] = " "
            index += 2
            continue
        index += 1
    return "".join(masked)


def _line_has_process_substitution(line: str) -> bool:
    """True when a physical line carries a real process-substitution
    opener (`<( … )`/`>( … )`), i.e. an unquoted, uncommented `<`/`>` glued
    to a following `(`. The shell lexer splits an unquoted opener into an
    operator plus a `(…` word, so the substitution's closing `)` is glued
    to the redirect target before it; the target classifier strips those
    `)` only when this opener is present (issue #345, fold round 1 F3;
    fold round 2 MINOR-1 masks quotes and comments first)."""
    unquoted = _mask_quoted_and_commented(line)
    for index, char in enumerate(unquoted[:-1]):
        if char in "<>" and unquoted[index + 1] == "(":
            return True
    return False


def _logical_line_has_process_substitution(
    lines: list[str], line_index: int
) -> bool:
    """True when the continuation-joined logical line containing
    `line_index` carries a process-substitution opener. A shell joins a
    physical line that ends in an unescaped `\\` with the next one, but the
    tokenizer still sees each physical line on its own, so a target whose
    closing `)` is glued on the continuation line needs the opener from the
    line before it (issue #345, fold round 1 F3)."""
    first = line_index
    while first > 0 and _line_has_continuation(lines[first - 1]):
        first -= 1
    last = line_index
    while last + 1 < len(lines) and _line_has_continuation(lines[last]):
        last += 1
    return any(
        _line_has_process_substitution(lines[index])
        for index in range(first, last + 1)
    )


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
    if (
        text.endswith(")")
        and _ENV_FILE_SPELLING_RE.fullmatch(text.rstrip(")"))
        and _logical_line_has_process_substitution(lines, line_index)
    ):
        # The shell lexer splits an unquoted process substitution into an
        # operator plus a `(…` word, so the substitution's closing `)`s are
        # glued to the redirect target that precedes it (`… >>
        # "$GITHUB_ENV")`): the exact env spelling plus one (or, nested,
        # several) trailing `)` is the env file, not a different filename.
        # The opener on the line is required, and only the exact env
        # spelling plus glued parens matches: a literal filename that is
        # not that spelling stays untouched (a literal `"$GITHUB_ENV))"`
        # target on a real-opener line refuses and is a named benign
        # over-refusal; issue #345, fold round 1 F3; fold round 2 D1
        # strips every glued closing parenthesis; fold round 3 names the
        # cost).
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


# A sed `w`/`W` script command: the target filename is the rest of the
# script line. The command position is the start of the script, a `;`
# separator, or the start of any script line (`re.MULTILINE`), optionally
# preceded by a GNU address — a line number/`$`/`~step`/`+N`, a `/regex/`,
# an alternate-delimiter `\,regex,`/`\%regex%`, one of those or a
# comma-separated pair of them (a range), optionally followed by a `{`
# block opener. Bracketed and addressed spellings are the same command at
# runtime (fold lens-1 MAJOR-2, round 3 MAJOR-4). The tokenizer keeps an
# escaped `\$` from a double-quoted operand, so the address may carry that
# backslash (`"\$w file"` passes `$w file` to sed). The `s///w file`
# substitution flag is left as a named residual: the prefix is anchored at
# a command position (start/`;`/line start), so it cannot start inside a
# substitution. The extracted target is tested with the same narrow
# predicate as the file operands, and a broader match can only add targets,
# so the direction is fail-closed. The alternate-delimiter address term is
# the general GNU `\cREc` form; it accepts both the raw single-backslash
# spelling and the double-quoted-source double-backslash spelling (shell
# double quotes turn `\\` into `\`), and its backreference is numbered per
# copy so a range's second term can itself be the alternate-delimiter form
# (fold round 5, Z1/Y9/Z2/Z3/Z4); the optional `!` modifier after an
# address or range is GNU's negation, without which `1!w`/`/re/!W` never
# reach the command scan (fold round 4 MAJOR-2).


def _sed_address_term(backreference: int) -> str:
    """One sed address term: a line number/`$`/`~`/`+` address, a
    `/regex/` address, or GNU's general `\\cREc` alternate-delimiter
    address. `\\\\?` carries the optional second raw backslash of the
    double-quoted-source spelling, the delimiter is group
    `backreference`, and the closing delimiter is matched with the same
    number."""
    return (
        r"(?:[0-9$~+]+|/(?:[^/\\\n]|\\\\/|\\.)*/|"
        r"\\\\?([^\\\n])[^\n]*?"
        + "\\"
        + str(backreference)
        + r")"
    )


_SED_ADDRESS = (
    _sed_address_term(1)
    + r"(?:[ \t]*,[ \t]*"
    + _sed_address_term(2)
    + r")?"
)
_SED_WRITE_COMMAND_RE = re.compile(
    r"(?:^|;)[ \t]*(?:\\)?(?:" + _SED_ADDRESS + r")?[ \t]*!?[ \t]*\{?[ \t]*[wW][ \t]+(?P<target>\S[^\n;]*)",
    re.MULTILINE,
)


def _sed_write_targets(script: str) -> list[str]:
    """The target of every `w`/`W` script command in one sed script
    operand: sed's second write channel, whose filename is the rest of the
    script line (issue #346, fold lens-1 MAJOR-1)."""
    targets: list[str] = []
    for match in _SED_WRITE_COMMAND_RE.finditer(script):
        target = match.group("target").strip()
        if target:
            targets.append(target)
    return targets


def _line_leaves_double_quote_open(line: str) -> bool:
    """True when one physical line ends inside an unclosed quoted string:
    a newline inside `"…"` or `'…'` is part of the word, not a command
    boundary. Used only to join a sed script that spans physical lines
    (fold lens-1 round 2 MAJOR-2; single-quote join added for the BSD
    `$a\\` two-line append, issue #350 item 7 — the name is retained for
    continuity). Escapes are honoured like `_command_substitution_depth`,
    and a `#` comment ends the scan."""
    quote: str | None = None
    index = 0
    while index < len(line):
        char = line[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\" and quote != "'" and index + 1 < len(line):
            index += 2
            continue
        if char == "'" and quote is None:
            quote = "'"
            index += 1
            continue
        if char == '"':
            quote = None if quote == '"' else '"'
            index += 1
            continue
        if char == "#" and quote is None and (index == 0 or line[index - 1].isspace()):
            break
        index += 1
    return quote is not None


def _joined_sed_segments(
    lines: list[str], index: int
) -> list[list[tuple[str, str, int, int]]]:
    """The token segment of a sed invocation whose quoted script spans
    physical lines, joined for the `w`/`W` scan only (fold lens-1 round 2
    MAJOR-2). The caller's per-line walk cannot see a script that continues
    past the closing quote's line, so this joins while the double quote is
    open and re-tokenizes; the result feeds the same narrow predicate, so
    the addition is fail-closed. Returns `[]` for every other line."""
    if not _line_leaves_double_quote_open(lines[index]):
        return []
    first = _first_shell_word(lines[index])[0]
    if first is None or first.rsplit("/", 1)[-1] != "sed":
        return []
    joined = [lines[index]]
    cursor = index
    while _line_leaves_double_quote_open("\n".join(joined)):
        cursor += 1
        if cursor >= len(lines):
            return []
        joined.append(lines[cursor])
    return [
        segment
        for segment in _shell_segments(_shell_tokens("\n".join(joined)))
        if segment
        and segment[0][0] == "word"
        and segment[0][1].rsplit("/", 1)[-1] == "sed"
    ]


_CONTINUATION_JOIN_MAX_LINES = 8


def _line_continuation_pending(line: str) -> bool:
    """True when the physical line ends in an unquoted, unescaped
    backslash, so the shell joins the next physical line into this command
    (issue #350, item 1 (iii)). `_line_has_continuation` owns the odd-run
    test; this scan additionally rejects a backslash that sits inside a
    single-quoted region, where it is literal rather than a continuation,
    and stops at an unquoted `#` comment word, where the shell ends the
    command (fold round 1 MAJOR-2(b)). The comment test is escape-aware:
    whitespace a backslash just escaped is part of the word, so a `#`
    behind it does not start a comment (fold round 2 MAJOR-1)."""
    if not _line_has_continuation(line):
        return False
    quote: str | None = None
    index = 0
    end = len(line)
    escaped_until = -1
    while index < end:
        char = line[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\" and quote != "'" and index + 1 < end:
            escaped_until = index + 1
            index += 2
            continue
        if char == "'" and quote is None:
            quote = "'"
            index += 1
            continue
        if char == '"':
            quote = None if quote == '"' else '"'
            index += 1
            continue
        if (
            char == "#"
            and quote is None
            and (index == 0 or (line[index - 1].isspace() and index - 1 != escaped_until))
        ):
            end = index
            break
        index += 1
    if quote == "'":
        return False
    return _line_has_continuation(line[:end])


def _joined_continuation_segments(
    lines: list[str], index: int
) -> list[list[tuple[str, str, int, int]]]:
    """The argv-write segments of the logical line that starts at
    `lines[index]` when it ends in an unquoted backslash (issue #350, item 1
    (iii)). The per-line walk cannot see an argv target the shell joins
    from the continuation line (`cp payload \\` + newline + `"${arr[0]}"`),
    so the logical line is tokenized whole and the argv-target predicate
    runs on the result. Returns [] unless `index` ends in a continuation
    and the join stays inside the bound; a line inside a longer chain can
    also join as a suffix (the joined scans are additive refusals, so
    double-joining is harmless, and a backslash-terminated comment no
    longer suppresses the real continuation — fold round 1 MAJOR-2(b)). A
    continuation longer than the bound stays open (a named residual)."""
    if not _line_continuation_pending(lines[index]):
        return []
    joined = [lines[index]]
    cursor = index
    while _line_continuation_pending(joined[-1]):
        cursor += 1
        if cursor >= len(lines) or (cursor - index) >= _CONTINUATION_JOIN_MAX_LINES:
            return []
        joined.append(lines[cursor])
    return [
        segment
        for segment in _shell_segments(_shell_tokens("\n".join(joined)))
        if segment
    ]


def _argv_write_targets(
    segment: list[tuple[str, str, int, int]],
) -> list[tuple[str, str]]:
    """The `(verb, target)` file operands of an argv write verb in one
    segment: `tee` appends to every non-option path operand and `dd` writes
    `of=…`. The verb is matched by basename so a path prefix does not evade
    (issue #345, lens-v2 t04/t20/t22/t23). A recognized interpreter invoked
    with an inline-program flag (`python3 -c`, `perl -e`, `ruby -e`) also
    carries its file targets in argv (`sys.argv[1]`, `$ARGV[0]`, `ARGV[0]`),
    so the non-flag words after the inline program are returned too and
    classified with the same resolver as `tee`/`dd of=` (issue #345, fold
    round 1 F4)."""
    words = [token[1] for token in segment if token[0] == "word"]
    for position, text in enumerate(words):
        verb = text.rsplit("/", 1)[-1] if "/" in text else text
        if verb in _ARGV_WRITE_VERBS:
            args = words[position + 1 :]
            if verb == "tee":
                targets: list[tuple[str, str]] = []
                options_done = False
                for argument in args:
                    if argument == "--":
                        options_done = True
                        continue
                    if argument == "-":
                        # stdout, not a file.
                        continue
                    if not options_done and argument.startswith("-"):
                        continue
                    targets.append(("tee", argument))
                return targets
            if verb == "dd":
                return [
                    ("dd", argument[3:])
                    for argument in args
                    if argument.startswith("of=") and len(argument) > 3
                ]
            if verb in ("cp", "mv", "install"):
                operands = [a for a in args if not a.startswith("-")]
                if not operands:
                    return []
                return [(verb, operands[-1])]
            if verb in ("touch", "truncate"):
                targets = []
                options_done = False
                for argument in args:
                    if argument == "--":
                        options_done = True
                        continue
                    if not options_done and argument.startswith("-"):
                        continue
                    targets.append((verb, argument))
                return targets
            if verb == "sed":
                args2 = list(args)
                inplace = False
                expressions: list[str] = []
                positional: list[str] = []
                has_expression_flag = False
                index = 0
                while index < len(args2):
                    argument = args2[index]
                    if argument == "--":
                        positional.extend(args2[index + 1 :])
                        break
                    if argument in ("-e", "--expression"):
                        has_expression_flag = True
                        if index + 1 < len(args2):
                            expressions.append(args2[index + 1])
                            index += 2
                            continue
                        index += 1
                        continue
                    if argument.startswith("--expression="):
                        has_expression_flag = True
                        expressions.append(argument.split("=", 1)[1])
                        index += 1
                        continue
                    if argument in ("-f", "--file"):
                        # The script file's body is not read (named
                        # residual); its argument is not a positional
                        # operand.
                        has_expression_flag = True
                        index += 2
                        continue
                    if argument.startswith("--file="):
                        has_expression_flag = True
                        index += 1
                        continue
                    if argument == "-i":
                        inplace = True
                        if index + 1 < len(args2) and args2[index + 1] == "":
                            # BSD `-i ''` extension argument.
                            index += 1
                        index += 1
                        continue
                    if argument.startswith("--"):
                        option_name = argument[2:].split("=", 1)[0]
                        if option_name and "in-place".startswith(option_name):
                            # GNU getopt_long accepts any unambiguous
                            # abbreviation of a long option, and `in-place`
                            # is sed's only long option starting with `i`,
                            # so `--i`/`--in`/`--in-plac` (and the
                            # `--in=.bak` attached-argument form) are the
                            # in-place form (fold lens-1 round 3 MAJOR-2).
                            inplace = True
                            index += 1
                            continue
                        if option_name and "expression".startswith(option_name):
                            # GNU getopt_long accepts any unambiguous
                            # abbreviation of `--expression`, and
                            # `expression` is sed's only long option
                            # starting with `e`, so `--e`/`--ex`/…/
                            # `--expressio` are the expression flag in
                            # both the separated and the attached
                            # (`--ex=`) form (issue #350, item 9).
                            has_expression_flag = True
                            if "=" in argument:
                                expressions.append(argument.split("=", 1)[1])
                                index += 1
                                continue
                            if index + 1 < len(args2):
                                expressions.append(args2[index + 1])
                                index += 2
                                continue
                            index += 1
                            continue
                    if argument.startswith("-i"):
                        inplace = True
                        index += 1
                        continue
                    if (
                        argument.startswith("-")
                        and not argument.startswith("--")
                        and not argument.startswith("-i")
                        and not argument.startswith("-f")
                    ):
                        # GNU getopt scans a short-option word left to
                        # right: the first `e` takes the remainder of the
                        # word as the script (`-eSCRIPT`, `-nEeSCRIPT`) and
                        # an `i` before it is the in-place flag, with the
                        # remainder as its optional suffix (`-ni`, `-Ei`,
                        # `-ni.bak`; the `-i`/`-iSUFFIX` forms are
                        # handled above). A script attached to `-e` was previously
                        # never scanned (fold lens-1 round 3 MAJOR-3), and
                        # an `i` inside an attached script no longer sets
                        # in-place. Recognized flags only ever add script
                        # text or positional file targets, so the direction
                        # is fail-closed. `-f` keeps its previous handling
                        # (the script-file body stays residual).
                        cluster = argument[1:]
                        expression_at = cluster.find("e")
                        inplace_at = cluster.find("i")
                        if expression_at != -1 and (
                            inplace_at == -1 or expression_at < inplace_at
                        ):
                            has_expression_flag = True
                            remainder = cluster[expression_at + 1 :]
                            if remainder:
                                expressions.append(remainder)
                                index += 1
                            elif index + 1 < len(args2):
                                expressions.append(args2[index + 1])
                                index += 2
                            else:
                                index += 1
                            continue
                        if inplace_at != -1:
                            inplace = True
                            index += 1
                            continue
                    if argument.startswith("-"):
                        index += 1
                        continue
                    positional.append(argument)
                    index += 1
                if has_expression_flag:
                    files = positional
                else:
                    expressions = positional[:1]
                    files = positional[1:]
                targets = [
                    ("sed", target)
                    for expression in expressions
                    for target in _sed_write_targets(expression)
                ]
                if inplace:
                    targets.extend(("sed", f) for f in files)
                return targets
            return []
        core = _interpreter_core(verb)
        if core not in _INLINE_PROGRAM_FLAGS:
            continue
        args = words[position + 1 :]
        inline = _inline_program_flag(core, args)
        if inline is None:
            # No inline program: a script path (`python3 script.py`) is a
            # named residual and its operands are not classified.
            continue
        program_index, attached, _program = inline
        first = program_index + (1 if attached else 2)
        return [
            (verb, argument)
            for argument in args[first:]
            if not argument.startswith("-")
        ]
    return []


def _new_verb_target_is_unproven(
    target: str,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
) -> bool:
    """r1: the narrow predicate for the newly modelled verbs. A target is
    unproven when it names the env file, carries a command substitution /
    backtick / indirection / env spelling, or resolves through an assignment
    whose RHS carries one of those. A multi-expansion target that names only
    unassigned variables (`$OUT_DIR/VVTerm.ipa`) is accepted -- it cannot be
    proven to be the env file, but the strict A6 predicate would refuse every
    real `cp`/`mv`/`install` destination."""
    text = target.strip()
    if (
        _env_file_target_kind(
            target, aliases, assignments, lines, line_index, column_index
        )
        == "env"
    ):
        return True
    if "$(" in text or "`" in text or "${!" in text:
        return True
    if _ENV_FILE_SPELLING_RE.search(text):
        return True
    inner = _local_reference_name(text)
    if inner is not None:
        for assignment in assignments:
            if assignment.name == inner and assignment.value is not None:
                value = assignment.value
                if "$(" in value or "`" in value or "${!" in value:
                    return True
    return False


def _argv_write_target_is_unproven(
    target: str,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
) -> bool:
    """True when one argv write target is not provably harmless: the
    env-file spelling/alias (`env`), an unassigned or computed value
    (`unknown`), or a value assembled from more than one expansion piece.
    The argv write form is new to the model, so a single resolved non-env
    reference (or a plain literal) is the only accepted proof (issue #345,
    lens-v2 t03/t04/t20/t22/t23)."""
    kind = _env_file_target_kind(
        target, aliases, assignments, lines, line_index, column_index
    )
    if kind != "other":
        return True
    return len(_EXPANSION_PIECE_RE.findall(target)) > 1


def _segment_env_redirect_present(
    segment: list[tuple[str, str, int, int]],
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
) -> bool:
    """True when this segment itself redirects to the env file. The
    substitution-body argv deferral is only sound when the outer
    per-segment reference accounting runs, and that accounting is skipped
    when the segment has an env redirect of its own, so the caller needs
    this before the body scan (issue #345, fold round 1 F2)."""
    for _op, target, _start, _span, redirect_fd in _segment_redirects(segment):
        if _op == "<>" and redirect_fd == 0:
            continue
        if (
            _env_file_target_kind(
                target, aliases, assignments, lines, line_index, column_index
            )
            == "env"
        ):
            return True
    return False


def _refuse_argv_write_targets(
    segment: list[tuple[str, str, int, int]],
    step: ArtifactStep,
    body: RunBody,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
    defer_env_spelling: bool,
) -> None:
    """Refuse when an argv write verb in this segment has a target the
    extractor cannot prove harmless. Inside a substitution body
    (`defer_env_spelling`) the exact env-file spelling is left to the outer
    per-segment reference accounting, which sees the same text and owns that
    diagnostic — but that accounting only runs when the enclosing segment
    has no env redirect of its own, so the caller defers only in that case
    and otherwise refuses with the argv diagnostic (issue #345, fold round 1
    F2)."""
    for verb, target in _argv_write_targets(segment):
        if verb in ("tee", "dd") or _interpreter_core(verb) in _INLINE_PROGRAM_FLAGS:
            unproven = _argv_write_target_is_unproven(
                target, aliases, assignments, lines, line_index, column_index
            )
        else:
            unproven = _new_verb_target_is_unproven(
                target, aliases, assignments, lines, line_index, column_index
            )
        if not unproven:
            continue
        if defer_env_spelling and _env_file_target_kind(
            target, aliases, assignments, lines, line_index, column_index
        ) == "env":
            continue
        raise _run_id_argv_write_refusal(step, body, verb, target)


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


_SUBSTITUTION_SCAN_DEPTH_LIMIT = 8


def _substitution_bodies(text: str) -> list[str]:
    """Every `$( … )`/backtick/`<( … )` body inside one shell word, in
    source order. `$( … )`/`<( … )` are quote-aware
    (`_consume_command_substitution`); an unclosed construct yields the rest
    of the word, which the callers treat fail-closed. The word text has
    usually lost its quotes, so a single-quoted `$( … )` is
    indistinguishable here and is refused by the callers' fail-closed
    guards rather than silently skipped (issue #345, Option A (ii); the
    process-substitution opener is fold round 1 F3)."""
    bodies: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "`":
            end = text.find("`", i + 1)
            if end == -1:
                bodies.append(text[i + 1 :])
                i = n
            else:
                bodies.append(text[i + 1 : end])
                i = end + 1
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            end = _consume_command_substitution(text, i)
            bodies.append(text[i + 2 : end - 1])
            i = end
            continue
        if c in "<>" and i + 1 < n and text[i + 1] == "(":
            # `<( … )`/`>( … )` executes its body exactly as `$( … )` does,
            # so its redirects are scanned with the same rules (issue #345,
            # fold round 1 F3).
            end = _consume_command_substitution(text, i)
            bodies.append(text[i + 2 : end - 1])
            i = end
            continue
        i += 1
    return bodies


def _body_shadow_assignment(
    body: str, relevant: set[str], broad: bool = False
) -> str | None:
    """A name the substitution body itself assigns (`NAME=`/`+=`) that is
    part of the scope the download resolves through, or None. A body-local
    assignment is invisible to the outer trace, so a body that assigns a
    traced name is refused rather than classified through it (issue #345,
    Option A (iii)). `broad` also reads an assignment embedded inside a
    quoted carrier word (`eval "printf \u2026 NAME=... \u2026"`), which the
    word-position form cannot see."""
    for token in _shell_tokens(body):
        if token[0] != "word":
            continue
        match = _ENV_ALIAS_ASSIGNMENT_RE.match(token[1])
        if match is None:
            match = _ENV_APPEND_ASSIGNMENT_RE.match(token[1])
        if match is not None and match.group(1) in relevant:
            return match.group(1)
    if broad:
        for name in sorted(relevant, key=len, reverse=True):
            if re.search(
                r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\s*(?:\+)?=", body
            ):
                return name
    return None


def _unclosed_substitution_hides_redirect(line: str) -> bool:
    """True when a physical line that ends in a continuation contains a
    command substitution that does not close on the line and whose text
    already shows a redirection operator: the joined next line closes the
    substitution and completes the redirect target, outside the per-line
    view (issue #345, h23)."""
    if not _line_has_continuation(line):
        return False
    for token in _shell_tokens(line):
        if token[0] != "word":
            continue
        text = token[1]
        i = 0
        n = len(text)
        while i < n:
            c = text[i]
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == "`":
                end = text.find("`", i + 1)
                if end == -1:
                    if any(ch in text[i:] for ch in (">", "<")):
                        return True
                    break
                i = end + 1
                continue
            if c == "$" and i + 1 < n and text[i + 1] == "(":
                end = _consume_command_substitution(text, i)
                if end >= n:
                    if any(ch in text[i:] for ch in (">", "<")):
                        return True
                    break
                i = end
                continue
            i += 1
    return False


def _refuse_substitution_body_writes(
    text: str,
    step: ArtifactStep,
    body: RunBody,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
    relevant_names: set[str],
    flip_targets: set[str],
    mechanism_guard: str | None,
    use_body_shadow_guard: bool,
    broad_shadow_guard: bool,
    defer_env_spelling: bool,
    depth: int = 0,
) -> None:
    """Issue #345, Option A (ii)/(iii): a `$( \u2026 )`/backtick body the
    per-line walk did not model is shell code the shell runs, so each of its
    redirects is classified with the outer scope and each of its words is
    scanned recursively. Refuses when a target classifies `env`/`unknown`
    (accepting `other`), when an optional body-level unmodelled-write guard
    names a traced variable, or when an optional shadow guard sees a body
    assignment of a traced name. A depth overrun refuses rather than
    recursing without bound."""
    if depth > _SUBSTITUTION_SCAN_DEPTH_LIMIT:
        raise _run_id_payload_refusal(step, body)
    for inner in _substitution_bodies(text):
        if use_body_shadow_guard:
            shadow = _body_shadow_assignment(
                inner, relevant_names | flip_targets, broad_shadow_guard
            )
            if shadow is not None:
                raise _run_id_unaccounted_occurrence_refusal(step, body, shadow)
        inner_tokens = _shell_tokens(inner)
        if mechanism_guard is not None:
            mechanism = _unmodelled_write_match(
                inner_tokens, step, relevant_names, flip_targets
            )
            if mechanism is not None and (
                mechanism_guard != "carrier" or mechanism[2]
            ):
                raise _run_id_unmodelled_write_refusal(step, body, mechanism)
        for inner_segment in _shell_segments(inner_tokens):
            for op, target, _start, _span, fd in _segment_redirects(inner_segment):
                if op == "<>" and fd == 0:
                    continue
                kind = _env_file_target_kind(
                    target,
                    aliases,
                    assignments,
                    lines,
                    line_index,
                    column_index,
                )
                if kind == "unknown":
                    raise _run_id_unresolved_target_refusal(step, body, target)
                if kind == "env":
                    raise _run_id_reference_refusal(step, body)
            carrier = _xargs_upstream_carrier(
                inner,
                inner_segment,
                relevant_names,
                flip_targets,
                require_unresolved_word_catch=False,
            )
            if carrier is not None:
                raise _run_id_unmodelled_write_refusal(
                    step, body, ("xargs", carrier, True)
                )
            _refuse_argv_write_targets(
                inner_segment,
                step,
                body,
                aliases,
                assignments,
                lines,
                line_index,
                column_index,
                defer_env_spelling,
            )
            for token in inner_segment:
                if token[0] == "word" and ("$(" in token[1] or "`" in token[1]):
                    _refuse_substitution_body_writes(
                        token[1],
                        step,
                        body,
                        aliases,
                        assignments,
                        lines,
                        line_index,
                        column_index,
                        relevant_names,
                        flip_targets,
                        mechanism_guard,
                        use_body_shadow_guard,
                        broad_shadow_guard,
                        defer_env_spelling,
                        depth + 1,
                    )


def _scan_segment_substitutions(
    segment: list[tuple[str, str, int, int]],
    step: ArtifactStep,
    body: RunBody,
    aliases: set[str],
    assignments: list[_ShellAssignment],
    lines: list[str],
    line_index: int,
    column_index: int,
    relevant_names: set[str],
    flip_targets: set[str],
    mechanism_guard: str | None,
    use_body_shadow_guard: bool,
    broad_shadow_guard: bool,
    defer_env_spelling: bool,
) -> None:
    for token in segment:
        if token[0] != "word":
            continue
        if "$(" not in token[1] and "`" not in token[1]:
            continue
        _refuse_substitution_body_writes(
            token[1],
            step,
            body,
            aliases,
            assignments,
            lines,
            line_index,
            column_index,
            relevant_names,
            flip_targets,
            mechanism_guard,
            use_body_shadow_guard,
            broad_shadow_guard,
            defer_env_spelling,
        )




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


def _run_id_argv_write_refusal(
    step: ArtifactStep, body: RunBody, verb: str, target: str
) -> Refusal:
    """An argv write verb (`tee`, `dd of=…`) whose file target the extractor
    cannot resolve to the env file or prove harmless (issue #345)."""
    return Refusal(
        step.run_id_line or step.uses_line,
        f"run-id: '{step.run_id}' cannot be proven — a preceding step in this job runs `{verb}` "
        f"with a file target `{target}` the extractor cannot resolve to the env file or prove "
        "harmless (refusing rather than guessing)",
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
    elif carrier and _interpreter_core(mechanism) in _INLINE_PROGRAM_FLAGS:
        # An interpreter inline program (`python3 -c`, `php -r`, …) is
        # refused by the same content test, but a `$(` inside a Python or
        # PHP string names nothing the download resolves through, so the
        # shell-carrier wording would be a false claim (fold lens-1 round 2
        # MAJOR-6).
        detail = (
            f"runs `{mechanism}` with an inline program the extractor cannot prove harmless"
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


def _read_operands(
    argv: list[str],
    options_with_argument: tuple[str, ...] = _READ_OPTIONS_WITH_ARGUMENT,
) -> list[str | None]:
    """Every variable `read`/`mapfile`/`readarray` writes: the non-option
    words, with option arguments skipped. A dynamic operand (`read -r
    "$name"`) is returned as None so the caller refuses rather than
    guessing which variable it writes (issue #342, R4). An array-element
    operand (`read 'arr[0]'`) contributes its base name; the caller passes
    the verb-specific option table because `-t` takes an argument for
    `read` but is a flag for `mapfile`/`readarray` (issue #350, item 1)."""
    operands: list[str | None] = []
    position = 0
    while position < len(argv):
        word = argv[position]
        if word == "--":
            position += 1
            continue
        if word.startswith("-") and len(word) > 1:
            position += 2 if word in options_with_argument else 1
            continue
        if word.startswith("$"):
            operands.append(None)
        elif _IDENTIFIER_RE.match(word):
            operands.append(word)
        elif _ARRAY_OPERAND_RE.match(word):
            operands.append(_ARRAY_OPERAND_RE.match(word).group(1))
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
        options = (
            _READ_OPTIONS_WITH_ARGUMENT
            if mechanism == "read"
            else _MAPFILE_OPTIONS_WITH_ARGUMENT
        )
        return [(name, False) for name in _read_operands(argv, options)]
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
    if mechanism in ("bash", "sh", "zsh", "dash", "ksh") and (
        _argv_has_command_flag(argv) or _argv_has_unresolved_word(argv)
    ):
        program_index = None
        for index, word in enumerate(argv):
            if _short_option_cluster_carries_command(word):
                program_index = index + 1
                break
        if program_index is not None:
            if program_index < len(argv):
                return [(argv[program_index], True)]
            return []
        if argv:
            return [(argv[0], True)]
        return []
    if mechanism in _INLINE_PROGRAM_POSITIONAL:
        operands = []
        for word in argv:
            if word == "-v":
                continue
            if word.startswith("-v") and len(word) > 2:
                operands.append((word[2:], True))
                continue
            if word.startswith("-"):
                continue
            operands.append((word, True))
        return operands
    if mechanism in _INLINE_PROGRAM_FLAGS:
        inline = _inline_program_flag(mechanism, argv)
        if inline is None:
            # No literal inline-program flag, but a `$`/backtick-bearing
            # word may itself be that flag (`F=-r; php $F 'prog'`, `php
            # $'--run' 'prog'`), so the invocation cannot be proven not to
            # carry an inline program: the interpreter sibling of the
            # runtime-assembled shell command flag (D5), the same
            # fail-closed rule as the shell branch above (issue #345,
            # fold round 5).
            if _argv_has_unresolved_word(argv):
                return [(word, True) for word in argv]
            return []
        return [(inline[2], True)]
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


_ANSI_C_QUOTED_RE = re.compile(r"\$'((?:\\.|[^'\\])*)'", re.DOTALL)
_ANSI_C_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "e": "\x1b",
    "E": "\x1b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "?": "?",
}


def _decode_ansi_c_body(body: str) -> str:
    r"""Decode the body of a bash `$'…'` ANSI-C literal (issue #346, fold
    lens-1 MAJOR-4). Bounded to the escape set a carrier needs: `\xHH`,
    `\uHHHH`, `\UHHHHHHHH`, octal `\NNN` and the single-character C
    escapes. An unrecognized escape keeps its character, as bash does."""
    result: list[str] = []
    index = 0
    while index < len(body):
        char = body[index]
        if char != "\\" or index + 1 >= len(body):
            result.append(char)
            index += 1
            continue
        nxt = body[index + 1]
        if nxt in ("x", "u", "U"):
            width = {"x": 2, "u": 4, "U": 8}[nxt]
            digits = body[index + 2 : index + 2 + width]
            match = re.match(r"[0-9A-Fa-f]{1," + str(width) + r"}", digits)
            if match is not None:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue
            result.append(nxt)
            index += 2
            continue
        if nxt in "01234567":
            match = re.match(r"[0-7]{1,3}", body[index + 1 :])
            result.append(chr(int(match.group(0), 8)))
            index += 1 + len(match.group(0))
            continue
        result.append(_ANSI_C_ESCAPES.get(nxt, nxt))
        index += 2
    return "".join(result)


def _ansi_c_decoded(text: str) -> str:
    """Every `$'…'` ANSI-C literal in `text` replaced with its decoded
    text. Used only by the carrier-substitution test, so the decoder does
    not widen any unrelated rule (issue #346, fold lens-1 MAJOR-4)."""
    return _ANSI_C_QUOTED_RE.sub(
        lambda match: _decode_ansi_c_body(match.group(1)), text
    )


def _carries_substitution_spelling(text: str) -> bool:
    """True when `text`, or its ANSI-C decoding, contains a command
    substitution or a backtick. The shell tokenizer strips the `$'…'`
    quotes, so an operand reaches the carrier test as `$` plus the
    backslash-escaped body (`$\x24\x28…`); that token form is decoded too
    (issue #346, fold lens-1 MAJOR-4)."""
    if "$(" in text or "`" in text:
        return True
    decoded = _ansi_c_decoded(text)
    if "$(" in decoded or "`" in decoded:
        return True
    if text.startswith("$") and "\\" in text:
        body = text[1:]
        decoded_body = _decode_ansi_c_body(body)
        if "$(" in decoded_body or "`" in decoded_body:
            return True
    return False


def _carrier_operand_matches(
    text: str, relevant: set[str], flip_targets: set[str]
) -> bool:
    """True when a `trap`/`eval`/`sh -c` command string can carry the value
    the download resolves through: it mentions the env file, references a
    traced variable, assigns one, or is itself an unreadable variable
    (`eval "$CMD"`: the gate cannot see what it runs, so it cannot prove the
    command string is harmless), issue #342, R4 / issue #345 lens-v2
    t16/t16b."""
    if _mentions_github_env(text):
        return True
    if _PURE_VARIABLE_RE.match(text) is not None:
        return True
    # The substitution test reads the ANSI-C-decoded text: `$'…\x24\x28…'`
    # is a spelling of `$(…` that the raw text does not expose (issue #346,
    # fold lens-1 MAJOR-4).
    if _carries_substitution_spelling(text):
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
        if kind != "word":
            index += 1
            continue
        # A path-prefixed verb (`/bin/bash`, `/usr/bin/tee`) is the same
        # mechanism as the bare name, so the table is keyed by basename
        # (issue #345, lens-v2 t01).
        verb = text.rsplit("/", 1)[-1] if "/" in text else text
        interpreter = _interpreter_core(verb)
        var_command = _PURE_VARIABLE_RE.match(text) is not None
        if (
            verb not in _UNMODELLED_WRITE_VERBS
            and interpreter not in _INLINE_PROGRAM_VERBS
            and not var_command
        ):
            index += 1
            continue
        resolved = interpreter if interpreter in _INLINE_PROGRAM_VERBS else verb
        mechanism = verb
        index += 1
        argv: list[str] = []
        while index < len(tokens) and tokens[index][0] == "word":
            argv.append(tokens[index][1])
            index += 1
        if var_command:
            # A variable in command position (`$SHELL -c …`): only an
            # invocation with `-c` carries a command string, and it must
            # reach the env file/traced names to refuse (issue #345,
            # lens-v2 t02). The command flag may be a short-option cluster
            # (`$SHELL -ec`), so the cluster spelling is recognized here too
            # (issue #345, fold round 1 F1); a `$`/backtick-bearing argv
            # word may itself be the command flag (`$SHELL $f`), so the
            # unresolved-word form is fail-closed too (issue #345, fold
            # round 2 D5).
            if _argv_has_command_flag(argv) or _argv_has_unresolved_word(argv):
                for word in argv:
                    if _carrier_operand_matches(word, relevant, flip_targets):
                        return (text, word, True)
            continue
        for operand, carrier in _mechanism_operands(resolved, argv):
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
    change the redirect's destination (issue #342, R4). An array subscript
    contributes its base name: the base name is what the relevance set
    needs (`${arr[$i]}` decodes to `arr`; a nested `$i` index is dropped
    deliberately, issue #350 item 1 note)."""
    names: set[str] = set()
    for a, b, c in re.findall(
        r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]\n]*\])?)\}"
        r"|([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]\n]*\])?))"
        r"|%([A-Za-z_][A-Za-z0-9_]*)%",
        text,
    ):
        name = a or b or c
        if name:
            names.add(name.split("[", 1)[0])
    return names


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
            # A newly-modelled argv write target's variable name is traced
            # too when the target is a PURE variable (`$p`): if the name is
            # written by an unmodelled assignment form (`printf -v`,
            # `read`, `declare`/`local`/`typeset`), the unmodelled-write
            # guard refuses the write rather than accepting the target as
            # unassigned (issue #346, fold lens-1 MAJOR-3). A multi-piece
            # target (`$OUT_DIR/VVTerm.ipa`) deliberately adds no names:
            # that is the real `cp` false-red the narrow predicate exists
            # to keep accepted.
            for _verb, target in _argv_write_targets(segment):
                if _local_reference_name(target) is not None:
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


def _xargs_upstream_carrier(
    line: str,
    segment: list[tuple[str, str, int, int]],
    relevant: set[str],
    flip_targets: set[str],
    require_unresolved_word_catch: bool = True,
) -> str | None:
    """The upstream pipeline text of an `xargs` segment when it can carry
    the operand argv cannot see (issue #350, item 2), or None. The operand
    arrives on xargs' stdin; refuse when the upstream names the env file,
    references a traced name, carries a command substitution/backtick, or
    (at the per-line site) is a `$`-bearing word the extractor cannot
    resolve. The substitution-body site passes
    `require_unresolved_word_catch=False`: a body whose upstream merely
    carries a benign `$raw` word is the real-tree witness the catch
    over-refuses, while a body carrying a nested `$(…)` still refuses
    through the substitution-spelling test."""
    if not segment or segment[0][0] != "word":
        return None
    verb = segment[0][1].rsplit("/", 1)[-1]
    if verb != "xargs":
        return None
    text = line[: segment[0][2]].strip()
    if not text:
        return None
    if _mentions_github_env(text):
        return text
    if _carries_substitution_spelling(text):
        return text
    if _text_references_names(text, relevant, flip_targets):
        return text
    if require_unresolved_word_catch and any(
        token[0] == "word" and ("$" in token[1] or "`" in token[1])
        for token in _shell_tokens(text)
    ):
        return text
    return None


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
        executing_payload = _executing_heredoc_payload_lines(lines)
        aliases = _env_file_alias_names(lines, payload_lines - executing_payload)
        assignments = _body_shell_assignments(lines, payload_lines)
        modelled_positions = {(hit.index, hit.column) for hit in assignments}
        relevant_names = _relevant_shell_names(
            flip_targets, aliases, assignments, lines, payload_lines
        )
        # Issue #350 item 1 (iii): a backslash continuation hides an argv
        # target from `_relevant_shell_names` (which reads physical lines),
        # so the array base name the joined target references never joins
        # the relevance set and the occurrence backstop cannot fire on the
        # continued line. Add the joined targets' base names first; heredoc
        # payload lines are skipped because they are literal text, not
        # shell.
        for _joined_index in range(len(lines)):
            if _joined_index in payload_lines:
                continue
            for _joined_segment in _joined_continuation_segments(lines, _joined_index):
                for _verb, _target in _argv_write_targets(_joined_segment):
                    if _local_reference_name(_target) is not None:
                        relevant_names.update(_expansion_names(_target))
        skip_until = -1
        for index, line in enumerate(lines):
            if index <= skip_until:
                continue
            if index not in payload_lines and _continuation_hides_redirect_target(line):
                raise _run_id_continuation_refusal(step, body)
            tokens = _shell_tokens(line)
            if True and _unclosed_substitution_hides_redirect(line):
                raise _run_id_continuation_refusal(step, body)
            mechanism = _unmodelled_write_match(
                tokens, step, relevant_names, flip_targets
            )
            if mechanism is not None:
                raise _run_id_unmodelled_write_refusal(step, body, mechanism)
            accounted: set[tuple[int, int]] = set()
            for segment in _shell_segments(tokens):
                write_column = segment[0][2]
                defer_env_spelling = not _segment_env_redirect_present(
                    segment,
                    aliases,
                    assignments,
                    lines,
                    index,
                    write_column,
                )
                xargs_carrier = _xargs_upstream_carrier(
                    line, segment, relevant_names, flip_targets
                )
                if xargs_carrier is not None:
                    raise _run_id_unmodelled_write_refusal(
                        step, body, ("xargs", xargs_carrier, True)
                    )
                _scan_segment_substitutions(
                    segment,
                    step,
                    body,
                    aliases,
                    assignments,
                    lines,
                    index,
                    write_column,
                    relevant_names,
                    flip_targets,
                    'carrier',
                    False,
                    False,
                    defer_env_spelling,
                )
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
            for segment in _shell_segments(tokens):
                _refuse_argv_write_targets(
                    segment,
                    step,
                    body,
                    aliases,
                    assignments,
                    lines,
                    index,
                    segment[0][2] if segment else 0,
                    False,
                )
            # A sed script that spans physical lines is invisible to the
            # per-line walk above; join it for the `w`/`W` scan (fold
            # lens-1 round 2 MAJOR-2). The joined segment is classified
            # with the same narrow predicate, so the addition only ever
            # adds a refusal.
            for joined_segment in _joined_sed_segments(lines, index):
                _refuse_argv_write_targets(
                    joined_segment,
                    step,
                    body,
                    aliases,
                    assignments,
                    lines,
                    index,
                    joined_segment[0][2] if joined_segment else 0,
                    False,
                )
            # A backslash continuation splits a command across physical
            # lines, so the argv-target walk above never sees a target on
            # the continued line (issue #350, item 1 (iii)). Join the
            # logical line for the narrow argv-target scan only; the joined
            # segments feed the same predicate, so the addition only ever
            # adds a refusal.
            for joined_segment in _joined_continuation_segments(lines, index):
                _refuse_argv_write_targets(
                    joined_segment,
                    step,
                    body,
                    aliases,
                    assignments,
                    lines,
                    index,
                    joined_segment[0][2] if joined_segment else 0,
                    False,
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
    base_verdict_cases = [case for case in cases if "base_exit" in case]
    if len(base_verdict_cases) != EXPECTED_BASE_VERDICT_CASES:
        print(
            f"selftest: FAIL — {len(base_verdict_cases)} case(s) declare a base "
            f"verdict, the stated constant is {EXPECTED_BASE_VERDICT_CASES}; every "
            "A12 fixture must declare its measured base verdict"
        )
        return 1
    for case in base_verdict_cases:
        base_exit = case["base_exit"]
        if base_exit not in (0, 1):
            print(
                f"selftest: FAIL — {case['id']}: base_exit must be 0 or 1, got "
                f"{base_exit!r}"
            )
            return 1
        if base_exit == 1 and int(case["exit"]) == 0:
            print(
                f"selftest: FAIL — {case['id']}: accept-widening (base REFUSE -> "
                "folded ACCEPT) is never allowed in this fold"
            )
            return 1
        if base_exit == 1 and case["id"] not in A12_BASE_REFUSAL_PINS:
            print(
                f"selftest: FAIL — {case['id']}: a fixture that already refused at "
                "base must be one of the documented pre-existing pins"
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
