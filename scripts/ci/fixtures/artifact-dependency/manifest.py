# SPDX-License-Identifier: MIT
"""Fixture manifest for the artifact-dependency gate (issue #316).

Each case is one fixture file (or one file pair) plus the expected exit code
and the EXACT diagnostics, compared as an ordered list. `--selftest`:
  * refuses a manifest whose length differs from `EXPECTED_MANIFEST_CASES` in
    `check-artifact-dependencies.py` (so deleting a case is a red selftest);
  * refuses any fixture file on disk that no case references;
  * copies the case's file(s) into a temp `.github/workflows/` and runs the
    same `scan_root` the real scan uses.

`floor: True` runs that case with the real scan floor enabled; every other
case runs with the floor disabled (temp trees hold 1-2 files by design).

Fixture layout: each file's first line is the SPDX header and the following
comment lines describe the case; the expected diagnostics carry the measured
line numbers.
"""

CASES = [
    # ------------------------------------------------------------------
    # Accept controls: every one exits 0 with no diagnostics.
    # ------------------------------------------------------------------
    {
        "id": "accept-needs-flow",
        "files": ["accept-needs-flow.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-needs-bare",
        "files": ["accept-needs-bare.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-needs-after-steps",
        "files": ["accept-needs-after-steps.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-needs-same-indent",
        "files": ["accept-needs-same-indent.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-needs-quoted",
        "files": ["accept-needs-quoted.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-bom-quoted-jobs",
        "files": ["accept-bom-quoted-jobs.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-templated-upload",
        "files": ["accept-templated-upload.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-producer-is-consumer",
        "files": ["accept-producer-is-consumer.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-cross-run-run-id",
        "files": ["accept-cross-run-run-id.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-block-scalar",
        "files": ["accept-block-scalar.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-quoted-uses",
        "files": ["accept-quoted-uses.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-run-id-with-needs",
        "files": ["accept-run-id-with-needs.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-in-comment",
        "files": ["accept-token-in-comment.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-quote-in-run-body",
        "files": ["accept-quote-in-run-body.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-deep-with",
        "files": ["accept-deep-with.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-needs-block-with-comment",
        "files": ["accept-needs-block-with-comment.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # Rejects: rule violations (a broken needs path) name the site.
    # ------------------------------------------------------------------
    {
        "id": "reject-missing-edge",
        "files": ["reject-missing-edge.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-missing-edge.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-shadow-downloader",
        "files": ["reject-shadow-downloader.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-shadow-downloader.yml:14: shadow downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `shadow` job',
        ],
    },
    {
        "id": "reject-wrong-job-needs",
        "files": ["reject-wrong-job-needs.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-wrong-job-needs.yml:19: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-steps-at-key-indent",
        "files": ["reject-steps-at-key-indent.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-steps-at-key-indent.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-steps-at-eight",
        "files": ["reject-steps-at-eight.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-steps-at-eight.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-job-body-at-six",
        "files": ["reject-job-body-at-six.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-job-body-at-six.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-block-decoy",
        "files": ["reject-run-block-decoy.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-block-decoy.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-single-line-decoy",
        "files": ["reject-run-single-line-decoy.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-single-line-decoy.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-quoted-uses-no-edge",
        "files": ["reject-quoted-uses-no-edge.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-quoted-uses-no-edge.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-case-variant-action",
        "files": ["reject-case-variant-action.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-case-variant-action.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-quoted-job-key-merge",
        "files": ["reject-quoted-job-key-merge.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-quoted-job-key-merge.yml:21: tail-job downloads artifact "vvterm-build" but no needs: path reaches its producer "producer" — add `needs: producer` to the `tail-job` job',
        ],
    },
    {
        "id": "reject-nested-needs-in-matrix",
        "files": ["reject-nested-needs-in-matrix.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-nested-needs-in-matrix.yml:18: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-current",
        "files": ["reject-run-id-current.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-current.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-fallback",
        "files": ["reject-run-id-fallback.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-fallback.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-bracket",
        "files": ["reject-run-id-bracket.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-bracket.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-quoted-jobs-missing-edge",
        "files": ["reject-quoted-jobs-missing-edge.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-quoted-jobs-missing-edge.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-crlf-missing-edge",
        "files": ["reject-crlf-missing-edge.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-crlf-missing-edge.yml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-yaml-extension",
        "files": ["reject-yaml-extension.yaml"],
        "exit": 1,
        "diagnostics": [
            'reject-yaml-extension.yaml:14: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-cross-file",
        "files": ["reject-cross-file-a.yml", "reject-cross-file-b.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-cross-file-b.yml:15: consumer downloads artifact "shared-artifact" but no needs: path reaches its producer "build" — the producer is in reject-cross-file-a.yml, not this workflow (artifacts are run-scoped; use `run-id:` for a cross-run handoff)',
        ],
    },
    # ------------------------------------------------------------------
    # Rejects: refusals the gate cannot fully prove.
    # ------------------------------------------------------------------
    {
        "id": "reject-unterminated-quote",
        "files": ["reject-unterminated-quote.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-unterminated-quote.yml:16: unterminated quoted scalar — a quoted scalar must close on its own line (multi-line quoted scalars are refused rather than guessed)",
        ],
    },
    {
        "id": "reject-terminated-multiline-quote",
        "files": ["reject-terminated-multiline-quote.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-terminated-multiline-quote.yml:15: unterminated quoted scalar — a quoted scalar must close on its own line (multi-line quoted scalars are refused rather than guessed)",
        ],
    },
    {
        "id": "reject-split-uses",
        "files": ["reject-split-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-split-uses.yml:9: unterminated quoted scalar — a quoted scalar must close on its own line (multi-line quoted scalars are refused rather than guessed)",
        ],
    },
    {
        "id": "reject-template-name-download",
        "files": ["reject-template-name-download.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-template-name-download.yml:17: download step's 'name:' is not a literal ('vvterm-build-${{ matrix.shard.name }}') — a templated name cannot be resolved to a producer (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-pattern-download",
        "files": ["reject-pattern-download.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-pattern-download.yml:16: 'pattern:' on an artifact download — only one literal 'name:' can be resolved to a producer (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-artifact-ids-download",
        "files": ["reject-artifact-ids-download.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-artifact-ids-download.yml:17: 'artifact-ids:' on an artifact download — only one literal 'name:' can be resolved to a producer (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-download-no-with",
        "files": ["reject-download-no-with.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-download-no-with.yml:14: download step has no 'name:' — set a literal artifact name so its producer can be resolved",
        ],
    },
    {
        "id": "reject-run-id-empty",
        "files": ["reject-run-id-empty.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-empty.yml:17: empty 'run-id:' — a download with a run-id must name a run",
        ],
    },
    {
        "id": "reject-run-id-unrecognized",
        "files": ["reject-run-id-unrecognized.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-unrecognized.yml:19: unrecognized 'run-id:' value ('${{ github.event.inputs.source_run }}') — recognized forms are a literal integer, ${{ env.NAME }}, ${{ github.event.workflow_run.id }}, or the same-run ${{ github.run_id }} (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-duplicate-producer",
        "files": ["reject-duplicate-producer.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-duplicate-producer.yml:17: artifact name 'vvterm-build' is uploaded more than once (job 'build' line 11, job 'other' line 17) — upload-artifact v4 requires artifact names to be unique per run",
        ],
    },
    {
        "id": "reject-duplicate-steps",
        "files": ["reject-duplicate-steps.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-duplicate-steps.yml:9: duplicate mapping key 'steps' (lines 7 and 9) — remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
        ],
    },
    {
        "id": "reject-duplicate-job-name",
        "files": ["reject-duplicate-job-name.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-duplicate-job-name.yml:10: duplicate job 'build' (lines 6 and 10) — every job key must be unique",
        ],
    },
    {
        "id": "reject-duplicate-top-level-jobs",
        "files": ["reject-duplicate-top-level-jobs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-duplicate-top-level-jobs.yml:12: duplicate top-level key 'jobs' (lines 5 and 12) — remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
        ],
    },
    {
        "id": "reject-duplicate-with-name",
        "files": ["reject-duplicate-with-name.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-duplicate-with-name.yml:18: duplicate 'with.name' (lines 17 and 18) — remove one (GitHub's duplicate-key semantics are unverified, so the gate refuses)",
        ],
    },
    {
        "id": "reject-absent-jobs",
        "files": ["reject-absent-jobs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-absent-jobs.yml:1: no top-level 'jobs:' mapping — refusing rather than passing a file the gate cannot read",
        ],
    },
    {
        "id": "reject-empty-jobs",
        "files": ["reject-empty-jobs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-empty-jobs.yml:4: 'jobs:' is empty — refusing rather than passing a workflow with no jobs",
        ],
    },
    {
        "id": "reject-tabs",
        "files": ["reject-tabs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tabs.yml:5: tab in indentation — YAML forbids tabs for indentation; use spaces",
        ],
    },
    {
        "id": "reject-merge-key",
        "files": ["reject-merge-key.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-merge-key.yml:6: merge key '<<' — YAML merge keys are refused (write the keys explicitly)",
        ],
    },
    {
        "id": "reject-anchor-alias",
        "files": ["reject-anchor-alias.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-anchor-alias.yml:10: anchor or alias '&'/'*' in a parsed position — YAML anchors/aliases are refused (write the value explicitly)",
        ],
    },
    {
        "id": "reject-flow-step",
        "files": ["reject-flow-step.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-flow-step.yml:8: flow mapping '{' in a parsed position — write a block mapping (flow syntax is refused rather than guessed)",
        ],
    },
    {
        "id": "reject-flow-with",
        "files": ["reject-flow-with.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-flow-with.yml:10: flow mapping '{' in a parsed position — write a block mapping (flow syntax is refused rather than guessed)",
        ],
    },
    {
        "id": "reject-uses-job-with-steps",
        "files": ["reject-uses-job-with-steps.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-uses-job-with-steps.yml:8: job 'caller' has both 'uses:' (line 7) and 'steps:' (line 8) — a reusable-workflow call cannot declare steps",
        ],
    },
    {
        "id": "reject-nested-with-lookalike",
        "files": ["reject-nested-with-lookalike.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-nested-with-lookalike.yml:19: artifact action token not parsed as an artifact step — a construct the parser cannot fully model must not pass (reconciliation failed)",
        ],
    },
    {
        "id": "reject-unconsumed-line",
        "files": ["reject-unconsumed-line.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-unconsumed-line.yml:18: unconsumed line — every line in a job or step must be a mapping key the gate understands (refusing rather than skipping)",
        ],
    },
    {
        "id": "reject-scan-floor",
        "files": ["reject-scan-floor.yml"],
        "exit": 1,
        "floor": True,
        "diagnostics": [
            "scan floor: only 1 workflow file(s) found under .github/workflows; the floor is 12 — update the floor constant only if workflows were intentionally removed (refusing rather than passing a truncated tree)",
        ],
    },
    # ------------------------------------------------------------------
    # Round-1 fold: the measured silent passes (lens-1 B1/B2/B3, M1), the
    # data-mention control (m1) and the orphan-download branch (lens-2 M2).
    # ------------------------------------------------------------------
    {
        "id": "reject-quoted-escape-uses",
        "files": ["reject-quoted-escape-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-quoted-escape-uses.yml:16: unsupported backslash escape '\\u' in a double-quoted scalar — the gate decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full escape set)",
        ],
    },
    {
        "id": "reject-quoted-escape-keyed-uses",
        "files": ["reject-quoted-escape-keyed-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-quoted-escape-keyed-uses.yml:15: unsupported backslash escape '\\u' in a double-quoted scalar — the gate decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full escape set)",
        ],
    },
    {
        "id": "accept-quoted-plain-uses",
        "files": ["accept-quoted-plain-uses.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-block-scalar-uses",
        "files": ["reject-block-scalar-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-uses.yml:15: block scalar header '|' as the value of 'uses:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    {
        "id": "reject-block-scalar-uses-folded",
        "files": ["reject-block-scalar-uses-folded.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-uses-folded.yml:15: block scalar header '>-' as the value of 'uses:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    {
        "id": "reject-block-scalar-with-name",
        "files": ["reject-block-scalar-with-name.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-with-name.yml:17: block scalar header '>-' as the value of 'name:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    {
        "id": "reject-block-scalar-needs",
        "files": ["reject-block-scalar-needs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-needs.yml:13: block scalar header '>-' as the value of 'needs:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    {
        "id": "reject-run-id-env-indirection",
        "files": ["reject-run-id-env-indirection.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-env-indirection.yml:18: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-run-id-static-cross-run-env",
        "files": ["accept-run-id-static-cross-run-env.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-producer-is-consumer-download-first",
        "files": ["reject-producer-is-consumer-download-first.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-producer-is-consumer-download-first.yml:9: build downloads artifact "vvterm-build" before its own upload step (line 12) — a job\'s steps run in source order; move the upload step earlier',
        ],
    },
    {
        "id": "accept-run-line-mentioning-action",
        "files": ["accept-run-line-mentioning-action.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-orphan-download",
        "files": ["reject-orphan-download.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-orphan-download.yml:8: consumer downloads artifact "never-uploaded" but no job in this workflow uploads that literal name (artifacts are run-scoped; use `run-id:` for a cross-run handoff)',
        ],
    },
    # ------------------------------------------------------------------
    # Round-2 fold: the closure lens's silent pass (C-MAJOR-1), the m1
    # job-key/step-name false reds (C-MINOR-1), the escape-refusal scope
    # (C-MINOR-2) and the with-key block-scalar class (C-NIT-2).
    # ------------------------------------------------------------------
    {
        "id": "reject-run-id-cross-run-without-token",
        "files": ["reject-run-id-cross-run-without-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-cross-run-without-token.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-run-id-cross-run-with-token",
        "files": ["accept-run-id-cross-run-with-token.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-job-key-mentioning-action",
        "files": ["accept-job-key-mentioning-action.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-step-name-mentioning-action",
        "files": ["accept-step-name-mentioning-action.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-legal-escape-in-name",
        "files": ["accept-legal-escape-in-name.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-legal-escape-in-run",
        "files": ["accept-legal-escape-in-run.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-block-scalar-with-keys",
        "files": [
            "reject-block-scalar-with-artifact-ids.yml",
            "reject-block-scalar-with-pattern.yml",
            "reject-block-scalar-with-run-id.yml",
        ],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-with-artifact-ids.yml:19: block scalar header '>-' as the value of 'artifact-ids:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
            "reject-block-scalar-with-pattern.yml:19: block scalar header '>-' as the value of 'pattern:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
            "reject-block-scalar-with-run-id.yml:19: block scalar header '>-' as the value of 'run-id:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    # ------------------------------------------------------------------
    # Round-3 fold: reconciliation fires only on a `uses:` key line whose
    # value carries an artifact token or on the `-artifact@ref` action-ref
    # shape. A job id that merely CONTAINS the token is a label, not a step,
    # and must not red when referenced (needs: flow list, needs: block list,
    # an `if:` expression).
    # ------------------------------------------------------------------
    {
        "id": "accept-job-id-containing-token-needs-flow",
        "files": ["accept-job-id-containing-token-needs-flow.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-job-id-containing-token-needs-block",
        "files": ["accept-job-id-containing-token-needs-block.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-job-id-containing-token-if-expr",
        "files": ["accept-job-id-containing-token-if-expr.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # Round-4 fold: the string-tag scalar readers (R4-MAJOR-1), the
    # empty-at-runtime `github-token:` forms (R4-MINOR-1), and the
    # round-2/round-3 mechanisms the closure lens measured as unpinned
    # (R4-NIT-1/2/3).
    # ------------------------------------------------------------------
    {
        "id": "reject-tagged-escaped-uses",
        "files": ["reject-tagged-escaped-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-escaped-uses.yml:16: unsupported backslash escape '\\u' in a double-quoted scalar — the gate decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full escape set)",
        ],
    },
    {
        "id": "reject-tagged-value-escaped-uses",
        "files": ["reject-tagged-value-escaped-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-value-escaped-uses.yml:16: unsupported backslash escape '\\u' in a double-quoted scalar — the gate decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full escape set)",
        ],
    },
    {
        "id": "reject-tagged-escaped-quoted-key",
        "files": ["reject-tagged-escaped-quoted-key.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-escaped-quoted-key.yml:16: unsupported backslash escape '\\u' in a double-quoted scalar — the gate decodes only \\n, \\t, \\\" and \\\\ (refusing rather than guessing YAML's full escape set)",
        ],
    },
    {
        "id": "reject-quoted-tag-text-runid-key",
        "files": ["reject-quoted-tag-text-runid-key.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-quoted-tag-text-runid-key.yml:17: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-tagged-uses-key",
        "files": ["reject-tagged-uses-key.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-tagged-uses-key.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-tagged-key-uses",
        "files": ["accept-tagged-key-uses.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-tagged-value-uses",
        "files": ["accept-tagged-value-uses.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-tagged-structure",
        "files": ["accept-tagged-structure.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-tagged-non-string-uses",
        "files": ["reject-tagged-non-string-uses.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-non-string-uses.yml:16: YAML tag '!!int' on a mapping key — only a single leading string tag ('!!str') is resolved to the scalar GitHub reads; a second tag or any other tag can coerce the key, so the gate refuses rather than guessing",
        ],
    },
    {
        "id": "reject-tagged-null-token",
        "files": ["reject-tagged-null-token.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-null-token.yml:20: YAML tag '!!null' on the value of 'github-token:' — only the string tag ('!!str') is resolved to the scalar GitHub reads; any other tag can coerce this value, so the gate refuses rather than guessing",
        ],
    },
    {
        "id": "accept-if-negation",
        "files": ["accept-if-negation.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-run-id-cross-run-empty-token",
        "files": ["reject-run-id-cross-run-empty-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-cross-run-empty-token.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-cross-run-empty-env-token",
        "files": ["reject-run-id-cross-run-empty-env-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-cross-run-empty-env-token.yml:18: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-cross-run-unresolved-token",
        "files": ["reject-run-id-cross-run-unresolved-token.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-cross-run-unresolved-token.yml:20: github-token: '${{ vars.TOKEN }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-run-id-literal-no-token",
        "files": ["reject-run-id-literal-no-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-literal-no-token.yml:17: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-block-scalar-with-github-token",
        "files": ["reject-block-scalar-with-github-token.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-block-scalar-with-github-token.yml:20: block scalar header '>-' as the value of 'github-token:' — this key decides the artifact graph and must be an inline scalar (refusing rather than guessing the folded value)",
        ],
    },
    {
        "id": "accept-step-name-with-ref",
        "files": ["accept-step-name-with-ref.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-job-name-with-ref",
        "files": ["accept-job-name-with-ref.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-mapping-key-ref",
        "files": ["accept-mapping-key-ref.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-uses-token-no-ref",
        "files": ["reject-uses-token-no-ref.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-uses-token-no-ref.yml:17: artifact action token not parsed as an artifact step — a construct the parser cannot fully model must not pass (reconciliation failed)",
        ],
    },
    {
        "id": "reject-action-ref-value",
        "files": ["reject-action-ref-value.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-action-ref-value.yml:20: artifact action token not parsed as an artifact step — a construct the parser cannot fully model must not pass (reconciliation failed)",
        ],
    },
    # ------------------------------------------------------------------
    # Round 5 (R5-MINOR-1 scoped env, R5-MINOR-2 exact token, R5-NIT-1
    # tagged needs flow). The two cases above whose diagnostics changed are
    # reject-tagged-non-string-uses (R5-NIT-2 wording) and
    # reject-run-id-cross-run-unresolved-token (the remedy text).
    # ------------------------------------------------------------------
    {
        "id": "accept-tagged-needs-flow",
        "files": ["accept-tagged-needs-flow.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-tagged-non-string-needs",
        "files": ["reject-tagged-non-string-needs.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-tagged-non-string-needs.yml:13: YAML tag '!!seq' on the value of 'needs:' — only the string tag ('!!str') is resolved to the scalar GitHub reads; any other tag can coerce this value, so the gate refuses rather than guessing",
        ],
    },
    {
        "id": "accept-token-in-scope-job-env",
        "files": ["accept-token-in-scope-job-env.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-in-scope-workflow-env",
        "files": ["accept-token-in-scope-workflow-env.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-token-out-of-scope-job-env",
        "files": ["reject-token-out-of-scope-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-out-of-scope-job-env.yml:27: github-token: '${{ env.GH_TOKEN }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-token-out-of-scope-step-env",
        "files": ["reject-token-out-of-scope-step-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-out-of-scope-step-env.yml:27: github-token: '${{ env.GH_TOKEN }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-token-unset-secret",
        "files": ["reject-token-unset-secret.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-unset-secret.yml:20: github-token: '${{ secrets.SOME_UNSET }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-token-compound-secret",
        "files": ["reject-token-compound-secret.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-compound-secret.yml:20: github-token: '${{ secrets.GITHUB_TOKEN && '' }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-run-id-out-of-scope-cross-run-env",
        "files": ["reject-run-id-out-of-scope-cross-run-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-out-of-scope-cross-run-env.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through a static `env:` assignment that is outside this step's env scope (only the workflow-level, the enclosing job's and the step's own `env:` are visible at runtime) — the value is empty or runtime-written, so a cross-run handoff cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-run-id-out-of-scope-same-run-env",
        "files": ["reject-run-id-out-of-scope-same-run-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-out-of-scope-same-run-env.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through a static `env:` assignment that is outside this step's env scope (only the workflow-level, the enclosing job's and the step's own `env:` are visible at runtime) — the value is empty or runtime-written, so a cross-run handoff cannot be proven (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # round-6 fold: YAML-empty `env:` values (R6-BLOCKER-1), case-sensitive
    # `env:` names (R6-BLOCKER-2), step-over-job precedence (R6-MINOR-1), and
    # the transitive link in a chained run-id refusal (R6-NIT-1)
    # ------------------------------------------------------------------
    {
        "id": "reject-token-env-empty-block-scalar-in-scope",
        "files": ["reject-token-env-empty-block-scalar-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-empty-block-scalar-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-empty-folded-block-scalar-in-scope",
        "files": ["reject-token-env-empty-folded-block-scalar-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-empty-folded-block-scalar-in-scope.yml:17: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-null-tilde-in-scope",
        "files": ["reject-token-env-null-tilde-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-null-tilde-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-null-literal-in-scope",
        "files": ["reject-token-env-null-literal-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-null-literal-in-scope.yml:19: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-token-env-nonempty-block-scalar-in-scope",
        "files": ["accept-token-env-nonempty-block-scalar-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-token-env-name-case-mismatch",
        "files": ["reject-token-env-name-case-mismatch.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-env-name-case-mismatch.yml:25: github-token: '${{ env.gh_token }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-token-env-name-case-alias",
        "files": ["reject-token-env-name-case-alias.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-env-name-case-alias.yml:30: github-token: '${{ env.GH_TOKEN }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-step-env-shadow-over-job-env",
        "files": ["accept-step-env-shadow-over-job-env.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-step-env-empty-shadow-over-job-env",
        "files": ["reject-step-env-empty-shadow-over-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-step-env-empty-shadow-over-job-env.yml:19: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-run-id-chain-out-of-scope-env",
        "files": ["reject-run-id-chain-out-of-scope-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-chain-out-of-scope-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.OTHER`, a static `env:` assignment that is outside this step's env scope (only the workflow-level, the enclosing job's and the step's own `env:` are visible at runtime) — the value is empty or runtime-written, so a cross-run handoff cannot be proven (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # round-7 fold: null-tagged `env:` values (R7-BLOCKER-1), bare empty
    # `env:` values that must still shadow (R7-BLOCKER-2), comment-only
    # block-scalar bodies (R7-MAJOR-1), and the case-mismatch run-id
    # wording (R7-NIT-1)
    # ------------------------------------------------------------------
    {
        "id": "reject-token-env-null-tag-in-scope",
        "files": ["reject-token-env-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-verbatim-null-tag-in-scope",
        "files": ["reject-token-env-verbatim-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-verbatim-null-tag-in-scope.yml:18: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-step-env-null-tag-shadow-over-job-env",
        "files": ["reject-step-env-null-tag-shadow-over-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-step-env-null-tag-shadow-over-job-env.yml:22: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-step-env-bare-null-shadow-over-job-env",
        "files": ["reject-step-env-bare-null-shadow-over-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-step-env-bare-null-shadow-over-job-env.yml:22: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-token-env-comment-block-scalar-in-scope",
        "files": ["accept-token-env-comment-block-scalar-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-run-id-case-variant-env",
        "files": ["reject-run-id-case-variant-env.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-run-id-case-variant-env.yml:25: run-id: '${{ env.source_run_id }}' resolves through `env.source_run_id`, which is assigned only under a different case (`env.SOURCE_RUN_ID`) — the `env` context lookup is case-sensitive on non-Windows runners, so the value is empty at runtime and a cross-run handoff cannot be proven (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # round-8 fold: QUOTED/ESCAPED null spellings on a null-tagged `env:`
    # value (R8-BLOCKER-1), tagged/anchored block-scalar headers on `env:`
    # values and semantic keys (R8-BLOCKER-1/-2), and the anchor property on
    # a tagged scalar (R8-BLOCKER-2)
    # ------------------------------------------------------------------
    {
        "id": "reject-token-env-quoted-null-tag-in-scope",
        "files": ["reject-token-env-quoted-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-quoted-null-tag-in-scope.yml:22: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-quoted-tilde-null-tag-in-scope",
        "files": ["reject-token-env-quoted-tilde-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-quoted-tilde-null-tag-in-scope.yml:19: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-verbatim-quoted-null-tag-in-scope",
        "files": ["reject-token-env-verbatim-quoted-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-verbatim-quoted-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-quoted-null-tag-shadow-over-job-env",
        "files": ["reject-token-env-quoted-null-tag-shadow-over-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-quoted-null-tag-shadow-over-job-env.yml:23: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-empty-block-null-tag-in-scope",
        "files": ["reject-token-env-empty-block-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-empty-block-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-escape-null-tag-in-scope",
        "files": ["reject-token-env-escape-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-escape-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-anchor-null-tag-in-scope",
        "files": ["reject-token-env-anchor-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-anchor-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-anchored-quoted-null-tag-in-scope",
        "files": ["reject-token-env-anchored-quoted-null-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-anchored-quoted-null-tag-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-string-tag-empty-block-in-scope",
        "files": ["reject-token-env-string-tag-empty-block-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-string-tag-empty-block-in-scope.yml:21: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-tagged-anchor-empty-in-scope",
        "files": ["reject-token-tagged-anchor-empty-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-tagged-anchor-empty-in-scope.yml:20: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "accept-token-env-quoted-nonnull-null-tag-in-scope",
        "files": ["accept-token-env-quoted-nonnull-null-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-null-tag-nonempty-block-in-scope",
        "files": ["accept-token-env-null-tag-nonempty-block-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-anchored-value-null-tag-in-scope",
        "files": ["accept-token-env-anchored-value-null-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-anchored-literal-in-scope",
        "files": ["accept-token-anchored-literal-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # round-9 fold (#334): a non-string tag on an in-scope `env:` value is
    # resolved the way the runner resolves it (an empty argument is the
    # empty string, not a present token), and the direct plain-null
    # `with.github-token:` spellings are resolved before `decode_scalar`.
    # Branch order in `_static_env_value` is part of the contract:
    # `_null_tag_value` must run BEFORE the generic non-string-tag branch,
    # or the 7 existing quoted/escaped null-tag cases regress to silent
    # passes (measured 136/143 with the reversed order). The last four
    # cases are the continuation controls: the guard preserves the base
    # verdict for a tagged value whose plain scalar continues on a
    # more-indented line instead of reding it.
    # ------------------------------------------------------------------
    {
        "id": "reject-token-env-int-empty-tag-in-scope",
        "files": ["reject-token-env-int-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-empty-tag-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-bool-empty-tag-in-scope",
        "files": ["reject-token-env-bool-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-bool-empty-tag-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-float-empty-tag-in-scope",
        "files": ["reject-token-env-float-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-float-empty-tag-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-int-bare-tag-in-scope",
        "files": ["reject-token-env-int-bare-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-bare-tag-in-scope.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-binary-empty-tag-in-scope",
        "files": ["reject-token-env-binary-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-binary-empty-tag-in-scope.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-custom-empty-tag-in-scope",
        "files": ["reject-token-env-custom-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-custom-empty-tag-in-scope.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-tag-first-anchor-int-empty",
        "files": ["reject-token-env-tag-first-anchor-int-empty.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-tag-first-anchor-int-empty.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-verbatim-int-empty",
        "files": ["reject-token-env-verbatim-int-empty.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-verbatim-int-empty.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-custom-expression-tag-in-scope",
        "files": ["reject-token-env-custom-expression-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            "reject-token-env-custom-expression-tag-in-scope.yml:22: github-token: '${{ env.GH_TOKEN }}' cannot be proven non-empty at runtime — actions/download-artifact honors `run-id:` only when the token input is set; use a literal, ${{ secrets.GITHUB_TOKEN }} or ${{ github.token }}, or drop `run-id:` and add the `needs:` edge (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-token-env-bare-nonspecific-tag-in-scope",
        "files": ["reject-token-env-bare-nonspecific-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-bare-nonspecific-tag-in-scope.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-omap-empty-tag-in-scope",
        "files": ["reject-token-env-omap-empty-tag-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-omap-empty-tag-in-scope.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-null",
        "files": ["reject-token-direct-null.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-null.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-tilde",
        "files": ["reject-token-direct-tilde.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-tilde.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-null-title",
        "files": ["reject-token-direct-null-title.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-null-title.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-null-upper",
        "files": ["reject-token-direct-null-upper.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-null-upper.yml:15: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-bare-str-tag-line",
        "files": ["reject-bare-str-tag-line.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-bare-str-tag-line.yml:20: unconsumed line — every line in a job or step must be a mapping key the gate understands (refusing rather than skipping)',
        ],
    },
    {
        "id": "accept-token-env-int-literal-tag-in-scope",
        "files": ["accept-token-env-int-literal-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-bool-false-tag-in-scope",
        "files": ["accept-token-env-bool-false-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-custom-literal-tag-in-scope",
        "files": ["accept-token-env-custom-literal-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-custom-null-tag-in-scope",
        "files": ["accept-token-env-custom-null-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-string-null-tag-in-scope",
        "files": ["accept-token-env-string-null-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-int-expression-tag-in-scope",
        "files": ["accept-token-env-int-expression-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-escaped-nonnull-null-tag-in-scope",
        "files": ["accept-token-env-escaped-nonnull-null-tag-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-direct-string-null",
        "files": ["accept-token-direct-string-null.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-direct-quoted-null",
        "files": ["accept-token-direct-quoted-null.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-int-tag-continuation",
        "files": ["accept-token-env-int-tag-continuation.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-custom-tag-continuation",
        "files": ["accept-token-env-custom-tag-continuation.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-token-env-int-empty-tag-continuation",
        "files": ["reject-token-env-int-empty-tag-continuation.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-empty-tag-continuation.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-int-empty-block-continuation",
        "files": ["reject-token-env-int-empty-block-continuation.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-empty-block-continuation.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-int-comment-continuation",
        "files": ["reject-token-env-int-comment-continuation.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-comment-continuation.yml:16: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-bare-verbatim-str-tag-line",
        "files": ["reject-bare-verbatim-str-tag-line.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-bare-verbatim-str-tag-line.yml:20: unconsumed line — every line in a job or step must be a mapping key the gate understands (refusing rather than skipping)',
        ],
    },
    {
        "id": "reject-token-env-step-int-empty-shadow-over-job-env",
        "files": ["reject-token-env-step-int-empty-shadow-over-job-env.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-step-int-empty-shadow-over-job-env.yml:19: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },

    {
        "id": "reject-token-env-esc-x20-in-scope",
        "files": ["reject-token-env-esc-x20-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-x20-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-u0020-in-scope",
        "files": ["reject-token-env-esc-u0020-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-u0020-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-v-in-scope",
        "files": ["reject-token-env-esc-v-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-v-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-f-in-scope",
        "files": ["reject-token-env-esc-f-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-f-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-nbsp-in-scope",
        "files": ["reject-token-env-esc-nbsp-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-nbsp-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-ls-in-scope",
        "files": ["reject-token-env-esc-ls-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-ls-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-ps-in-scope",
        "files": ["reject-token-env-esc-ps-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-ps-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-tab-in-scope",
        "files": ["reject-token-env-esc-tab-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-tab-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-cr-in-scope",
        "files": ["reject-token-env-esc-cr-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-cr-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-feff-in-scope",
        "files": ["reject-token-env-esc-feff-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-feff-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-str-tag-esc-x20-in-scope",
        "files": ["reject-token-env-str-tag-esc-x20-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-str-tag-esc-x20-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-str-tag-esc-feff-in-scope",
        "files": ["reject-token-env-str-tag-esc-feff-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-str-tag-esc-feff-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-str-tag-anchor-esc-x20-in-scope",
        "files": ["reject-token-env-str-tag-anchor-esc-x20-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-str-tag-anchor-esc-x20-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-int-esc-feff-in-scope",
        "files": ["reject-token-env-int-esc-feff-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-int-esc-feff-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-raw-bom-in-scope",
        "files": ["reject-token-env-raw-bom-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-raw-bom-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-quoted-raw-bom-in-scope",
        "files": ["reject-token-env-quoted-raw-bom-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-quoted-raw-bom-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-raw-bom",
        "files": ["reject-token-direct-raw-bom.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-raw-bom.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-direct-quoted-raw-bom",
        "files": ["reject-token-direct-quoted-raw-bom.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-direct-quoted-raw-bom.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-token-env-esc-jstrim-nonascii-in-scope",
        "files": ["reject-token-env-esc-jstrim-nonascii-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-jstrim-nonascii-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-tagged-anchored-escaped-uses",
        "files": ["reject-tagged-anchored-escaped-uses.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-tagged-anchored-escaped-uses.yml:13: unsupported backslash escape \'\\x\' in a double-quoted scalar — the gate decodes only \\n, \\t, \\" and \\\\ (refusing rather than guessing YAML\'s full escape set)',
        ],
    },
    {
        "id": "reject-tagged-anchored-esc-token",
        "files": ["reject-tagged-anchored-esc-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-tagged-anchored-esc-token.yml:17: unsupported backslash escape \'\\x\' in a double-quoted scalar — the gate decodes only \\n, \\t, \\" and \\\\ (refusing rather than guessing YAML\'s full escape set)',
        ],
    },
    {
        "id": "reject-needs-flow-escape",
        "files": ["reject-needs-flow-escape.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-needs-flow-escape.yml:17: unsupported backslash escape \'\\x\' in a double-quoted scalar — the gate decodes only \\n, \\t, \\" and \\\\ (refusing rather than guessing YAML\'s full escape set)',
        ],
    },
    {
        "id": "accept-token-env-esc-nel-in-scope",
        "files": ["accept-token-env-esc-nel-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-esc-fs-in-scope",
        "files": ["accept-token-env-esc-fs-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-squote-x20-in-scope",
        "files": ["accept-token-env-squote-x20-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-raw-nel-in-scope",
        "files": ["accept-token-env-raw-nel-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-env-int-esc-fs-in-scope",
        "files": ["accept-token-env-int-esc-fs-in-scope.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-token-direct-quoted-raw-nel",
        "files": ["accept-token-direct-quoted-raw-nel.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-token-env-esc-lf-in-scope",
        "files": ["reject-token-env-esc-lf-in-scope.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-token-env-esc-lf-in-scope.yml:13: consumer downloads artifact "vvterm-build" but no needs: path reaches its producer "build" — add `needs: build` to the `consumer` job',
        ],
    },
    {
        "id": "reject-needs-flow-swallow",
        "files": ["reject-needs-flow-swallow.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-needs-flow-swallow.yml:17: unsupported backslash escape \'\\x\' in a double-quoted scalar — the gate decodes only \\n, \\t, \\" and \\\\ (refusing rather than guessing YAML\'s full escape set)',
        ],
    },
    {
        "id": "accept-needs-flow-quoted",
        "files": ["accept-needs-flow-quoted.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # #338 (run-id parseInt predicate): the leading NEL/C0 refusals, the
    # leading-BOM false-red removal, the trailing-NEL control that pins
    # parseInt's LEADING-prefix semantics, and the env-chain pair that
    # exercises the static-assignment site (`_classify_static_value`).
    # ------------------------------------------------------------------
    {
        "id": "reject-run-id-nel-literal",
        "files": ["reject-run-id-nel-literal.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-nel-literal.yml:20: unrecognized \'run-id:\' value (\'\u0085123\') — recognized forms are a literal integer, ${{ env.NAME }}, ${{ github.event.workflow_run.id }}, or the same-run ${{ github.run_id }} (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-run-id-1c-literal",
        "files": ["reject-run-id-1c-literal.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-1c-literal.yml:18: unrecognized \'run-id:\' value (\'\u001c\u001d\u001e\u001f123\') — recognized forms are a literal integer, ${{ env.NAME }}, ${{ github.event.workflow_run.id }}, or the same-run ${{ github.run_id }} (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-run-id-bom-literal",
        "files": ["accept-run-id-bom-literal.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-run-id-nel-tail-literal",
        "files": ["accept-run-id-nel-tail-literal.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-run-id-env-nel",
        "files": ["reject-run-id-env-nel.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-env-nel.yml:21: run-id: \'${{ env.SOURCE_RUN_ID }}\' resolves through a static assignment in this file to a value that is neither the current run nor a recognized cross-run handoff (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-run-id-env-bom",
        "files": ["accept-run-id-env-bom.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # #338 fold round 1: `parseInt`'s hex radix. A `0x`/`0X` prefix needs at
    # least one hex digit or the value is `NaN` (refuse); `0x10` is 16 and is
    # a genuine handoff (accept).
    {
        "id": "reject-run-id-hex-prefix-no-digits",
        "files": ["reject-run-id-hex-prefix-no-digits.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-run-id-hex-prefix-no-digits.yml:20: unrecognized \'run-id:\' value (\'0xg\') — recognized forms are a literal integer, ${{ env.NAME }}, ${{ github.event.workflow_run.id }}, or the same-run ${{ github.run_id }} (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-run-id-hex-literal",
        "files": ["accept-run-id-hex-literal.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # #339 ($GITHUB_ENV token overwrite): a preceding same-job `run:` body
    # that MENTIONS `GITHUB_ENV` makes a statically env-resolved
    # `github-token:` unprovable. The four rejects pin the closed shapes
    # (`>>`, single `>`, a dynamic name, a same-value rewrite); the accept
    # is the position control and deliberately writes the chain name. The
    # fold-round-1 rejects pin the decoded/indirect spellings.
    # ------------------------------------------------------------------
    {
        "id": "reject-github-env-write-empties-token",
        "files": ["reject-github-env-write-empties-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-empties-token.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 19) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-single-redirect",
        "files": ["reject-github-env-write-single-redirect.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-single-redirect.yml:23: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 18) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-dynamic-name",
        "files": ["reject-github-env-write-dynamic-name.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-dynamic-name.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 19) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-same-value",
        "files": ["reject-github-env-write-same-value.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-same-value.yml:23: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 18) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-github-env-write-after-download",
        "files": ["accept-github-env-write-after-download.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    # #339 fold round 1: the detector decodes the run scalar's YAML escapes
    # and closes the indirect spellings (a `\x5f`-escaped name, shell-level
    # `"GITHUB_""ENV"` assembly inline and through a `bash -c` argv, and a
    # Windows `%github_env%` whose lookup is case-insensitive).
    {
        "id": "reject-github-env-write-yaml-escape",
        "files": ["reject-github-env-write-yaml-escape.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-yaml-escape.yml:25: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 20) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-shell-assembled",
        "files": ["reject-github-env-write-shell-assembled.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-shell-assembled.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 19) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-bash-c-argv",
        "files": ["reject-github-env-write-bash-c-argv.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-bash-c-argv.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 19) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-github-env-write-windows-lowercase",
        "files": ["reject-github-env-write-windows-lowercase.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-github-env-write-windows-lowercase.yml:25: github-token: \'${{ env.GH_TOKEN }}\' resolves through the `env` context, and a preceding step in this job writes to `$GITHUB_ENV` (line 20) — that write can change or empty the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    # ------------------------------------------------------------------
    # #341 (case-colliding env): the winning-assignment predicate. The
    # rejects close the Windows last-wins fail-open on the token chain
    # (direct and transitive) and across scopes (a case-variant inner scope
    # shadowing an exact-case outer assignment: step-over-job token,
    # job-over-workflow token, step-over-job run-id); the accepts are E8
    # (exact key last), E7 (a step-scope exact shadow) and E2 (an unrelated
    # in-scope collision).
    # ------------------------------------------------------------------
    {
        "id": "reject-env-case-collision-token",
        "files": ["reject-env-case-collision-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-env-case-collision-token.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through `env.GH_TOKEN`, and the case-variant assignment `env.gh_token` (line 18) wins under a Windows runner\'s case-insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a different value, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-env-case-collision-exact-last",
        "files": ["accept-env-case-collision-exact-last.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-env-case-variant-step-shadow",
        "files": ["accept-env-case-variant-step-shadow.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-env-case-collision-transitive",
        "files": ["reject-env-case-collision-transitive.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-env-case-collision-transitive.yml:24: github-token: \'${{ env.GH_TOKEN }}\' resolves through `env.TOKEN`, and the case-variant assignment `env.token` (line 18) wins under a Windows runner\'s case-insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a different value, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "accept-env-case-variant-unrelated",
        "files": ["accept-env-case-variant-unrelated.yml"],
        "exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-env-case-collision-step-variant-token",
        "files": ["reject-env-case-collision-step-variant-token.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-env-case-collision-step-variant-token.yml:27: github-token: \'${{ env.GH_TOKEN }}\' resolves through `env.GH_TOKEN`, and the case-variant assignment `env.gh_token` (line 23) wins under a Windows runner\'s case-insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a different value, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-env-case-collision-job-variant-workflow-exact",
        "files": ["reject-env-case-collision-job-variant-workflow-exact.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-env-case-collision-job-variant-workflow-exact.yml:25: github-token: \'${{ env.GH_TOKEN }}\' resolves through `env.GH_TOKEN`, and the case-variant assignment `env.gh_token` (line 19) wins under a Windows runner\'s case-insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a different value, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    {
        "id": "reject-env-case-collision-runid-step-variant",
        "files": ["reject-env-case-collision-runid-step-variant.yml"],
        "exit": 1,
        "diagnostics": [
            'reject-env-case-collision-runid-step-variant.yml:24: run-id: \'${{ env.SOURCE_RUN_ID }}\' resolves through `env.SOURCE_RUN_ID`, and the case-variant assignment `env.source_run_id` (line 21) wins under a Windows runner\'s case-insensitive `env` context (`OrdinalIgnoreCase`, last-wins) — the runtime resolves a different value, so the cross-run exclusion cannot be proven (refusing rather than guessing)',
        ],
    },
    # #342: the run-id `$GITHUB_ENV` write class. A preceding same-job write of
    # a flip-target name keeps the cross-run exclusion only when its value is
    # provably a cross-run handoff; the scan is per line, so one unrelated
    # extractable write cannot launder a missed same-run write. Every reject
    # was measured fail-open at the base commit (CF-1) and every accept
    # asserts `"excluded": 1` so a vacuous accept cannot pass.
    {
        "id": "reject-runid-github-env-write-bash-c-indirect",
        "files": ["reject-runid-github-env-write-bash-c-indirect.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-bash-c-indirect.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-case-variant-name",
        "files": ["reject-runid-github-env-write-case-variant-name.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-case-variant-name.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `source_run_id` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-command-substitution",
        "files": ["reject-runid-github-env-write-command-substitution.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-command-substitution.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 16) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-dd-unmodelled",
        "files": ["reject-runid-github-env-write-dd-unmodelled.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-dd-unmodelled.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 15) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-dynamic-name",
        "files": ["reject-runid-github-env-write-dynamic-name.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-dynamic-name.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes an unextractable name to `$GITHUB_ENV` (line 16) (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-empty",
        "files": ["reject-runid-github-env-write-empty.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-empty.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-guarded-local",
        "files": ["reject-runid-github-env-write-guarded-local.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-guarded-local.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 16) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-heredoc",
        "files": ["reject-runid-github-env-write-heredoc.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-heredoc.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 16) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-job-chain-write",
        "files": ["reject-runid-github-env-write-job-chain-write.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-job-chain-write.yml:25: run-id: '${{ env.A }}' resolves through `env.A`, and a preceding step in this job writes `B` to `$GITHUB_ENV` (line 20) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mixed-unmodelled-launder",
        "files": ["reject-runid-github-env-write-mixed-unmodelled-launder.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mixed-unmodelled-launder.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-payload-unknown",
        "files": ["reject-runid-github-env-write-payload-unknown.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-payload-unknown.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-read-only-mention",
        "files": ["reject-runid-github-env-write-read-only-mention.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-read-only-mention.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-same-run",
        "files": ["reject-runid-github-env-write-same-run.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-same-run.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-append-unmodelled",
        "files": ["reject-runid-github-env-write-sed-append-unmodelled.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-append-unmodelled.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 15) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-shell-assembled-name",
        "files": ["reject-runid-github-env-write-shell-assembled-name.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-shell-assembled-name.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-static-cross-run-flip",
        "files": ["reject-runid-github-env-write-static-cross-run-flip.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-static-cross-run-flip.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-step-chain-flip",
        "files": ["reject-runid-github-env-write-step-chain-flip.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-step-chain-flip.yml:26: run-id: '${{ env.A }}' resolves through `env.A`, and a preceding step in this job writes `B` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-tee-unmodelled",
        "files": ["reject-runid-github-env-write-tee-unmodelled.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-tee-unmodelled.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-vars-flip",
        "files": ["reject-runid-github-env-write-vars-flip.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-vars-flip.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-windows-spelling",
        "files": ["reject-runid-github-env-write-windows-spelling.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-windows-spelling.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-after-download",
        "files": ["accept-runid-github-env-write-after-download.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-cross-run",
        "files": ["accept-runid-github-env-write-cross-run.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-direct-expression",
        "files": ["accept-runid-github-env-write-direct-expression.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-inputs-local",
        "files": ["accept-runid-github-env-write-inputs-local.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-other-job",
        "files": ["accept-runid-github-env-write-other-job.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-real-handoff",
        "files": ["accept-runid-github-env-write-real-handoff.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-single-line-body",
        "files": ["accept-runid-github-env-write-single-line-body.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-step-env-shadow",
        "files": ["accept-runid-github-env-write-step-env-shadow.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-tagged-body",
        "files": ["accept-runid-github-env-write-tagged-body.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-unrelated-name",
        "files": ["accept-runid-github-env-write-unrelated-name.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-vars-cross-run",
        "files": ["accept-runid-github-env-write-vars-cross-run.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-yaml-escaped",
        "files": ["accept-runid-github-env-write-yaml-escaped.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    # fold round 1 (#342 lens findings): the command-substitution alias skip
    # (BLOCKER-1, five shapes), the `${!x}` indirect target (BLOCKER-2) plus
    # its direct-target control, and the `$GITHUB_ENV.bak` false red
    # (MINOR-1/F3).
    {
        "id": "reject-runid-github-env-write-cmdsub-assign",
        "files": ["reject-runid-github-env-write-cmdsub-assign.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-assign.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-tee",
        "files": ["reject-runid-github-env-write-cmdsub-tee.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-tee.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-multi",
        "files": ["reject-runid-github-env-write-cmdsub-multi.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-multi.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-backtick",
        "files": ["reject-runid-github-env-write-backtick.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-backtick.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-read",
        "files": ["reject-runid-github-env-write-cmdsub-read.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-read.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-indirect-target",
        "files": ["reject-runid-github-env-write-indirect-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-indirect-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-indirect-target-direct",
        "files": ["reject-runid-github-env-write-indirect-target-direct.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-indirect-target-direct.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `${!x}`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-env-file-backup",
        "files": ["accept-runid-github-env-write-env-file-backup.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    # fold round 2 (#342): the same-line multi-assignment traces (F7/F8) —
    # every statement-position `NAME=VALUE` is indexed with its column, so a
    # later same-line reassignment is visible and the reaching assignment is
    # the last one at or before the write's (line, column). Also the F9
    # `$GITHUB_ENV_X` narrowing, the F10 F2(b)-alone trace pin, and the
    # own-line reassignment control.
    {
        "id": "reject-runid-github-env-write-target-reassigned-mid-line",
        "files": ["reject-runid-github-env-write-target-reassigned-mid-line.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-target-reassigned-mid-line.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-target-reassigned-inline",
        "files": ["reject-runid-github-env-write-target-reassigned-inline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-target-reassigned-inline.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-target-reassigned-after-write",
        "files": ["reject-runid-github-env-write-target-reassigned-after-write.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-target-reassigned-after-write.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-value-reassigned-mid-line",
        "files": ["reject-runid-github-env-write-value-reassigned-mid-line.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-value-reassigned-mid-line.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-value-reassigned-inline",
        "files": ["reject-runid-github-env-write-value-reassigned-inline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-value-reassigned-inline.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 16) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-value-reassigned-after-write",
        "files": ["reject-runid-github-env-write-value-reassigned-after-write.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-value-reassigned-after-write.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-own-line-reassign-control",
        "files": ["reject-runid-github-env-write-own-line-reassign-control.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-own-line-reassign-control.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-unresolved-target-value",
        "files": ["reject-runid-github-env-write-unresolved-target-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-unresolved-target-value.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    # fold round 3 (#342): four closed fail-open families. `>&word`/`>|word`
    # are redirect targets (BLOCKER-1), a branch closer between the traced
    # assignment and the write is a fail-closed boundary (BLOCKER-2), a
    # command-prefix assignment in the write's own segment is NOT reaching
    # because bash expands the command's words with the previous value
    # (BLOCKER-3), and the cross-step `GITHUB_ENV_X` chain makes the suffix
    # target `unknown` (BLOCKER-4: the old accept was valid only under the
    # unprovable "never set" assumption and is now a reject).
    {
        "id": "reject-runid-github-env-write-amp-target",
        "files": ["reject-runid-github-env-write-amp-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-amp-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-noclobber-target",
        "files": ["reject-runid-github-env-write-noclobber-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-noclobber-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-exec-amp-target",
        "files": ["reject-runid-github-env-write-exec-amp-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-exec-amp-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes to `$GITHUB_ENV` (line 18) with a payload the gate cannot extract (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-ifelse-branch-target",
        "files": ["reject-runid-github-env-write-ifelse-branch-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-ifelse-branch-target.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-case-branch-target",
        "files": ["reject-runid-github-env-write-case-branch-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-case-branch-target.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-branch-residual",
        "files": ["reject-runid-github-env-write-branch-residual.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-branch-residual.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-prefix-target-oneline",
        "files": ["reject-runid-github-env-write-prefix-target-oneline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-prefix-target-oneline.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 21) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-prefix-target",
        "files": ["reject-runid-github-env-write-prefix-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-prefix-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-prefix-value-oneline",
        "files": ["reject-runid-github-env-write-prefix-value-oneline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-prefix-value-oneline.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 20) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-prefix-value",
        "files": ["reject-runid-github-env-write-prefix-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-prefix-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 18) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-identifier-suffix-chain",
        "files": ["reject-runid-github-env-write-identifier-suffix-chain.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-identifier-suffix-chain.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$GITHUB_ENV_X`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-identifier-suffix-concat-chain",
        "files": ["reject-runid-github-env-write-identifier-suffix-concat-chain.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-identifier-suffix-concat-chain.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$GITHUB_ENVx`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-identifier-suffix-target",
        "files": ["reject-runid-github-env-write-identifier-suffix-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-identifier-suffix-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$GITHUB_ENV_X`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-or-target-oneline",
        "files": ["reject-runid-github-env-write-or-target-oneline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-or-target-oneline.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-and-or-target-oneline",
        "files": ["reject-runid-github-env-write-and-or-target-oneline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-and-or-target-oneline.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-or-target-continuation",
        "files": ["reject-runid-github-env-write-or-target-continuation.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-or-target-continuation.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-or-value-oneline",
        "files": ["reject-runid-github-env-write-or-value-oneline.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-or-value-oneline.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-rw-target",
        "files": ["reject-runid-github-env-write-rw-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-rw-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 17) with a value that is not provably cross-run — that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-rw-exec",
        "files": ["reject-runid-github-env-write-rw-exec.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-rw-exec.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes to `$GITHUB_ENV` (line 17) with a payload the gate cannot extract (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-continuation-amp-target",
        "files": ["reject-runid-github-env-write-continuation-amp-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-amp-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job ends a line with an unescaped backslash continuation, so a redirect target or assignment can sit on the next line outside the extractor's per-line view (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-continuation-noclobber-target",
        "files": ["reject-runid-github-env-write-continuation-noclobber-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-noclobber-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job ends a line with an unescaped backslash continuation, so a redirect target or assignment can sit on the next line outside the extractor's per-line view (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-trap-target",
        "files": ["reject-runid-github-env-write-trap-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-trap-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `trap` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-eval-target",
        "files": ["reject-runid-github-env-write-eval-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-eval-target.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-bash-c-export-target",
        "files": ["reject-runid-github-env-write-bash-c-export-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-bash-c-export-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-bash-c-export-unset-target",
        "files": ["reject-runid-github-env-write-bash-c-export-unset-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-bash-c-export-unset-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-brace-group-target",
        "files": ["reject-runid-github-env-write-brace-group-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-brace-group-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `an out-of-statement assignment`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-read-value",
        "files": ["reject-runid-github-env-write-read-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-read-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-read-target",
        "files": ["reject-runid-github-env-write-read-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-read-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-printf-v-value",
        "files": ["reject-runid-github-env-write-printf-v-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-printf-v-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `printf`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-declare-value",
        "files": ["reject-runid-github-env-write-declare-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-declare-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `declare`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-declare-target",
        "files": ["reject-runid-github-env-write-declare-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-declare-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `declare`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-readonly-value",
        "files": ["reject-runid-github-env-write-readonly-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-readonly-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `readonly`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-readonly-target",
        "files": ["reject-runid-github-env-write-readonly-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-readonly-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `readonly`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-typeset-value",
        "files": ["reject-runid-github-env-write-typeset-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-typeset-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `typeset`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-declare-g-value",
        "files": ["reject-runid-github-env-write-declare-g-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-declare-g-value.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `declare`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-rw-plain",
        "files": ["accept-runid-github-env-write-rw-plain.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-unrelated-mechanism",
        "files": ["accept-runid-github-env-write-unrelated-mechanism.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    # #342 fold round 5: the F1 narrowings (benign continuations), the
    # F2 subshell-context exclusions (`&` background, `|`/`|&` left, a
    # `( … )` group, and a cross-line `$( … )`), and the F3
    # detection-completeness rule (mapfile/readarray `-t`, carrier
    # bare-name writes, namerefs, bracketed `read` operands, `let`,
    # `(( ))`, array-element assignment, and the pinned fail-closed
    # expansion-read cost).
    {
        "id": "accept-runid-github-env-write-benign-continuation",
        "files": ["accept-runid-github-env-write-benign-continuation.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-benign-continuation-heredoc",
        "files": ["accept-runid-github-env-write-benign-continuation-heredoc.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-benign-continuation-comment",
        "files": ["accept-runid-github-env-write-benign-continuation-comment.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-runid-github-env-write-amp-background-target",
        "files": ["reject-runid-github-env-write-amp-background-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-amp-background-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-pipe-left-target",
        "files": ["reject-runid-github-env-write-pipe-left-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-pipe-left-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-pipe-left-or-target",
        "files": ["reject-runid-github-env-write-pipe-left-or-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-pipe-left-or-target.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subshell-group-target",
        "files": ["reject-runid-github-env-write-subshell-group-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subshell-group-target.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `an out-of-statement assignment`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-multiline-target",
        "files": ["reject-runid-github-env-write-cmdsub-multiline-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-multiline-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mapfile-t-value",
        "files": ["reject-runid-github-env-write-mapfile-t-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mapfile-t-value.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `mapfile`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-readarray-t-value",
        "files": ["reject-runid-github-env-write-readarray-t-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-readarray-t-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `readarray`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mapfile-n-t-value",
        "files": ["reject-runid-github-env-write-mapfile-n-t-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mapfile-n-t-value.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `mapfile`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mapfile-t-target",
        "files": ["reject-runid-github-env-write-mapfile-t-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mapfile-t-target.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `n` through `mapfile`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-eval-read-value",
        "files": ["reject-runid-github-env-write-eval-read-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-eval-read-value.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-eval-read-target",
        "files": ["reject-runid-github-env-write-eval-read-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-eval-read-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `n`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-eval-printf-v-value",
        "files": ["reject-runid-github-env-write-eval-printf-v-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-eval-printf-v-value.yml:22: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-nameref-read-target",
        "files": ["reject-runid-github-env-write-nameref-read-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-nameref-read-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-nameref-eval-target",
        "files": ["reject-runid-github-env-write-nameref-eval-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-nameref-eval-target.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-read-subscript-value",
        "files": ["reject-runid-github-env-write-read-subscript-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-read-subscript-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-let-value",
        "files": ["reject-runid-github-env-write-let-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-let-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `CI_RUN_ID` through `an out-of-statement assignment`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-arith-value",
        "files": ["reject-runid-github-env-write-arith-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-arith-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-array-element-value",
        "files": ["reject-runid-github-env-write-array-element-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-value.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-expansion-read-value",
        "files": ["reject-runid-github-env-write-expansion-read-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-expansion-read-value.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `CI_RUN_ID`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # #342 fold round 6: the cross-line `$( … )`/backtick tracker closes
    # with the substitution again (fold-5 BLOCKER-1), and an unterminated
    # heredoc whose delimiter line ends in a continuation refuses rather
    # than reading the swallowed write as shell (fold-5 MINOR-3).
    # ------------------------------------------------------------------
    {
        "id": "accept-runid-github-env-write-substitution-then-cross-run-write",
        "files": [
            "accept-runid-github-env-write-substitution-then-cross-run-write.yml"
        ],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-substitution-then-value-trace",
        "files": [
            "accept-runid-github-env-write-substitution-then-value-trace.yml"
        ],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-substitution-then-alias-target",
        "files": [
            "accept-runid-github-env-write-substitution-then-alias-target.yml"
        ],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-backtick-then-alias-target",
        "files": [
            "accept-runid-github-env-write-backtick-then-alias-target.yml"
        ],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-runid-github-env-write-unterminated-heredoc-delimiter",
        "files": [
            "reject-runid-github-env-write-unterminated-heredoc-delimiter.yml"
        ],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-unterminated-heredoc-delimiter.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job ends a line with an unescaped backslash continuation, so a redirect target or assignment can sit on the next line outside the extractor's per-line view (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # #345: the command-substitution hidden-write family (A6). The gate
    # re-tokenizes every `$( ... )`/backtick word, classifies its redirects
    # with the outer scope, and closes the measured 382-shape family with 0
    # fail-opens. The 29 closure rejects derive from the measured roots: the
    # 8 issue-342 closure-5 roots (battery f01-f08), f10/f11/f12, k01-k04,
    # h16/h17/h18/h24-carrier/h26/q6, h23, and A6's 7 malicious shapes (one
    # per mechanism). The accept pins the `other`-target acceptance inside a
    # substitution body; the 9 over-refusal pins make the fail-closed cost
    # of the six A4 classes and A6's three benign-as-stored shapes visible.
    # ------------------------------------------------------------------
    {
        "id": "accept-runid-github-env-write-sub-other-target",
        "files": ["accept-runid-github-env-write-sub-other-target.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-overrefusal-assembled-literal-target",
        "files": ["reject-overrefusal-assembled-literal-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-assembled-literal-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `${p1}${p2}`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-awk-argv-target",
        "files": ["reject-overrefusal-awk-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-awk-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `awk` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-dd-of-target",
        "files": ["reject-overrefusal-dd-of-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-dd-of-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `dd` with a file target `${x}${y}` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-executing-heredoc-alias",
        "files": ["reject-overrefusal-executing-heredoc-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-executing-heredoc-alias.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 20) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-malformed-no-newline-value",
        "files": ["reject-overrefusal-malformed-no-newline-value.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-malformed-no-newline-value.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-nonexecuting-conditional-alias",
        "files": ["reject-overrefusal-nonexecuting-conditional-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-nonexecuting-conditional-alias.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-quoted-heredoc-payload",
        "files": ["reject-overrefusal-quoted-heredoc-payload.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-quoted-heredoc-payload.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 19) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-subshell-name-writing-mechanism",
        "files": ["reject-overrefusal-subshell-name-writing-mechanism.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-subshell-name-writing-mechanism.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-tee-argv-target",
        "files": ["reject-overrefusal-tee-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-tee-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `tee` with a file target `${x}${y}` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-assembled-inline-target",
        "files": ["reject-runid-github-env-write-cmdsub-assembled-inline-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-assembled-inline-target.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-bash-heredoc-alias",
        "files": ["reject-runid-github-env-write-cmdsub-bash-heredoc-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-bash-heredoc-alias.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-binbash-carrier",
        "files": ["reject-runid-github-env-write-cmdsub-binbash-carrier.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-binbash-carrier.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-dd-printenv",
        "files": ["reject-runid-github-env-write-cmdsub-dd-printenv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-dd-printenv.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `dd` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-eval-carrier",
        "files": ["reject-runid-github-env-write-cmdsub-eval-carrier.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-eval-carrier.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-eval-var-operand-noxy",
        "files": ["reject-runid-github-env-write-cmdsub-eval-var-operand-noxy.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-eval-var-operand-noxy.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-eval-var-operand",
        "files": ["reject-runid-github-env-write-cmdsub-eval-var-operand.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-eval-var-operand.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-export-alias",
        "files": ["reject-runid-github-env-write-cmdsub-export-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-export-alias.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-heredoc-payload",
        "files": ["reject-runid-github-env-write-cmdsub-heredoc-payload.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-heredoc-payload.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-if-condition",
        "files": ["reject-runid-github-env-write-cmdsub-if-condition.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-if-condition.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-indirect-name-target",
        "files": ["reject-runid-github-env-write-cmdsub-indirect-name-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-indirect-name-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$(printenv \"$p\")`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-nested",
        "files": ["reject-runid-github-env-write-cmdsub-nested.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-nested.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-payload-computed-alias",
        "files": ["reject-runid-github-env-write-cmdsub-payload-computed-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-payload-computed-alias.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-payload-direct",
        "files": ["reject-runid-github-env-write-cmdsub-payload-direct.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-payload-direct.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-payload-word",
        "files": ["reject-runid-github-env-write-cmdsub-payload-word.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-payload-word.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-plainname-last",
        "files": ["reject-runid-github-env-write-cmdsub-plainname-last.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-plainname-last.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-printenv-alias-target",
        "files": ["reject-runid-github-env-write-cmdsub-printenv-alias-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-printenv-alias-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$n`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-printenv-target",
        "files": ["reject-runid-github-env-write-cmdsub-printenv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-printenv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job redirects to `$(printenv \"${x}${y}\")`, a target the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python3-open",
        "files": ["reject-runid-github-env-write-cmdsub-python3-open.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python3-open.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `python3` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-quoted-xprefix-last",
        "files": ["reject-runid-github-env-write-cmdsub-quoted-xprefix-last.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-quoted-xprefix-last.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-same-run-last",
        "files": ["reject-runid-github-env-write-cmdsub-same-run-last.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-same-run-last.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-sh-heredoc-alias",
        "files": ["reject-runid-github-env-write-cmdsub-sh-heredoc-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-sh-heredoc-alias.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 17) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-shellvar-carrier",
        "files": ["reject-runid-github-env-write-cmdsub-shellvar-carrier.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-shellvar-carrier.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `$SHELL` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-source-heredoc-alias",
        "files": ["reject-runid-github-env-write-cmdsub-source-heredoc-alias.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-source-heredoc-alias.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-source-heredoc-both",
        "files": ["reject-runid-github-env-write-cmdsub-source-heredoc-both.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-source-heredoc-both.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 18) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-tee-printenv",
        "files": ["reject-runid-github-env-write-cmdsub-tee-printenv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-tee-printenv.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `tee` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-test-operand",
        "files": ["reject-runid-github-env-write-cmdsub-test-operand.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-test-operand.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-test-zero-exit",
        "files": ["reject-runid-github-env-write-cmdsub-test-zero-exit.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-test-zero-exit.yml:23: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 16) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-unclosed-continuation",
        "files": ["reject-runid-github-env-write-cmdsub-unclosed-continuation.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-unclosed-continuation.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job ends a line with an unescaped backslash continuation, so a redirect target or assignment can sit on the next line outside the extractor's per-line view (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # #345 fold round 1 (A7): clustered command flags, the argv
    # deferral with an enclosing env redirect, process substitution,
    # and interpreter argv file targets.
    # ------------------------------------------------------------------
    {
        "id": "reject-runid-github-env-write-cmdsub-bash-ec",
        "files": ["reject-runid-github-env-write-cmdsub-bash-ec.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-bash-ec.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-sh-ec",
        "files": ["reject-runid-github-env-write-cmdsub-sh-ec.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-sh-ec.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sh` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-shellvar-ec",
        "files": ["reject-runid-github-env-write-cmdsub-shellvar-ec.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-shellvar-ec.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `$SHELL` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-tee-outer-env-target",
        "files": ["reject-runid-github-env-write-cmdsub-tee-outer-env-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-tee-outer-env-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-dd-outer-env-target",
        "files": ["reject-runid-github-env-write-cmdsub-dd-outer-env-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-dd-outer-env-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `dd` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-process-substitution",
        "files": ["reject-runid-github-env-write-cmdsub-process-substitution.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-process-substitution.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 21) with a value that is not provably cross-run \u2014 that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-output-process-substitution",
        "files": ["reject-runid-github-env-write-cmdsub-output-process-substitution.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-output-process-substitution.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run \u2014 that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python3-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-python3-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python3-argv-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-perl-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-perl-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-perl-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `perl` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-ruby-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-ruby-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-ruby-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `ruby` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-process-substitution-continuation",
        "files": ["reject-runid-github-env-write-cmdsub-process-substitution-continuation.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-process-substitution-continuation.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes to `$GITHUB_ENV` (line 20) with a payload the gate cannot extract (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-shell-login-flags",
        "files": ["accept-runid-github-env-write-cmdsub-shell-login-flags.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-tee-literal-outer-env",
        "files": ["accept-runid-github-env-write-cmdsub-tee-literal-outer-env.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-process-substitution-other-target",
        "files": ["accept-runid-github-env-write-cmdsub-process-substitution-other-target.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-interpreter-literal-argv",
        "files": ["accept-runid-github-env-write-cmdsub-interpreter-literal-argv.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-overrefusal-interpreter-expansion-argv",
        "files": ["reject-overrefusal-interpreter-expansion-argv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-interpreter-expansion-argv.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$MESSAGE` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # #345 fold round 2 (A8): nested process-substitution parens,
    # inline-program flag clusters/attached/--flag= spellings, and a
    # runtime-assembled shell command flag.
    # ------------------------------------------------------------------
    {
        "id": "reject-runid-github-env-write-cmdsub-process-substitution-nested",
        "files": ["reject-runid-github-env-write-cmdsub-process-substitution-nested.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-process-substitution-nested.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 22) with a value that is not provably cross-run \u2014 that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-output-process-substitution-nested",
        "files": ["reject-runid-github-env-write-cmdsub-output-process-substitution-nested.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-output-process-substitution-nested.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' resolves through `env.SOURCE_RUN_ID`, and a preceding step in this job writes `SOURCE_RUN_ID` to `$GITHUB_ENV` (line 19) with a value that is not provably cross-run \u2014 that write can change the value at runtime, so the cross-run exclusion cannot be proven (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-perl-capital-e-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-perl-capital-e-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-perl-capital-e-argv-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `perl` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python3-cluster-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-python3-cluster-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python3-cluster-argv-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python3-attached-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-python3-attached-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python3-attached-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-perl-cluster-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-perl-cluster-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-perl-cluster-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `perl` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-perl-attached-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-perl-attached-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-perl-attached-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `perl` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-ruby-attached-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-ruby-attached-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-ruby-attached-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `ruby` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-attached-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-attached-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-attached-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-node-long-eval-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-node-long-eval-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-node-long-eval-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `node` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python312-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-python312-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python312-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3.12` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-shellvar-var-flag",
        "files": ["reject-runid-github-env-write-cmdsub-shellvar-var-flag.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-shellvar-var-flag.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-shellvar-attached-var-flag",
        "files": ["reject-runid-github-env-write-cmdsub-shellvar-attached-var-flag.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-shellvar-attached-var-flag.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-shellvar-var-command-flag",
        "files": ["reject-runid-github-env-write-cmdsub-shellvar-var-command-flag.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-shellvar-var-command-flag.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `$SHELL` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-interpreter-flag-spellings",
        "files": ["accept-runid-github-env-write-cmdsub-interpreter-flag-spellings.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-quoted-process-substitution-literal-target",
        "files": ["accept-runid-github-env-write-cmdsub-quoted-process-substitution-literal-target.yml"],
        "exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-overrefusal-shell-variable-operand",
        "files": ["reject-overrefusal-shell-variable-operand.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-shell-variable-operand.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-interpreter-attached-expansion-argv",
        "files": ["reject-overrefusal-interpreter-attached-expansion-argv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-interpreter-attached-expansion-argv.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$MESSAGE` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-node-pe-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-node-pe-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-node-pe-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `node` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-before-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-before-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-before-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-after-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-after-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-after-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-readline-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-readline-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-readline-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    # ------------------------------------------------------------------
    # #345 fold round 4 (A10): php's long-option inline-program aliases
    # (`--run`, `--process-begin`, `--process-end`, `--process-code`) and
    # the long spelling's over-refusal pin.
    # ------------------------------------------------------------------
    {
        "id": "reject-runid-github-env-write-cmdsub-php-long-run-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-long-run-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-long-run-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-long-run-attached-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-long-run-attached-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-long-run-attached-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-long-before-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-long-before-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-long-before-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-long-after-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-long-after-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-long-after-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-long-readline-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-long-readline-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-long-readline-argv-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-interpreter-long-alias-expansion-argv",
        "files": ["reject-overrefusal-interpreter-long-alias-expansion-argv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-interpreter-long-alias-expansion-argv.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with a file target `$MESSAGE` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-runtime-flag-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-runtime-flag-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-runtime-flag-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-php-ansic-long-flag-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-php-ansic-long-flag-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-php-ansic-long-flag-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-python3-runtime-flag-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-python3-runtime-flag-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-python3-runtime-flag-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cmdsub-node-runtime-flag-argv-target",
        "files": ["reject-runid-github-env-write-cmdsub-node-runtime-flag-argv-target.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cmdsub-node-runtime-flag-argv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `node` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-interpreter-runtime-flag-expansion-argv",
        "files": ["reject-overrefusal-interpreter-runtime-flag-expansion-argv.yml"],
        "exit": 1,
        "excluded": 0,
        "diagnostics": [
            "reject-overrefusal-interpreter-runtime-flag-expansion-argv.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `php` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-eval-pad",
        "files": ["reject-runid-github-env-write-mention-window-eval-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-eval-pad.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-empty-var-literal-underscore",
        "files": ["reject-runid-github-env-write-mention-window-empty-var-literal-underscore.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-empty-var-literal-underscore.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-printf-pad",
        "files": ["reject-runid-github-env-write-mention-window-printf-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-printf-pad.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-backslash-continuation",
        "files": ["reject-runid-github-env-write-mention-window-backslash-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-backslash-continuation.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-backtick-pad",
        "files": ["reject-runid-github-env-write-mention-window-backtick-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-backtick-pad.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-unbraced-special-pad",
        "files": ["reject-runid-github-env-write-mention-window-unbraced-special-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-unbraced-special-pad.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-unbraced-name-pad",
        "files": ["reject-runid-github-env-write-mention-window-unbraced-name-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-unbraced-name-pad.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-split-spelling",
        "files": ["reject-runid-github-env-write-mention-window-split-spelling.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-split-spelling.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 14) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-inplace-target",
        "files": ["reject-runid-github-env-write-sed-inplace-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-inplace-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-cp-target",
        "files": ["reject-runid-github-env-write-cp-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-cp-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `cp` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mv-target",
        "files": ["reject-runid-github-env-write-mv-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mv-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `mv` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-install-target",
        "files": ["reject-runid-github-env-write-install-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-install-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `install` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-truncate-target",
        "files": ["reject-runid-github-env-write-truncate-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-truncate-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `truncate` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-touch-target",
        "files": ["reject-runid-github-env-write-touch-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-touch-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `touch` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-w-target",
        "files": ["reject-runid-github-env-write-sed-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-w-inplace-target",
        "files": ["reject-runid-github-env-write-sed-w-inplace-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-w-inplace-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-long-inplace-target",
        "files": ["reject-runid-github-env-write-sed-long-inplace-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-long-inplace-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-assignment-rhs-sed-decoy",
        "files": ["reject-runid-github-env-write-assignment-rhs-sed-decoy.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-assignment-rhs-sed-decoy.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-assignment-rhs-cp-decoy",
        "files": ["reject-runid-github-env-write-assignment-rhs-cp-decoy.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-assignment-rhs-cp-decoy.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `cp` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-assignment-rhs-alias-mention",
        "files": ["reject-runid-github-env-write-assignment-rhs-alias-mention.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-assignment-rhs-alias-mention.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-eval-cat",
        "files": ["reject-runid-github-env-write-carrier-eval-cat.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-eval-cat.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-sh-c-cat",
        "files": ["reject-runid-github-env-write-carrier-sh-c-cat.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-sh-c-cat.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sh` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-bash-c-cat",
        "files": ["reject-runid-github-env-write-carrier-bash-c-cat.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-bash-c-cat.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `bash` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-backtick-cat",
        "files": ["reject-runid-github-env-write-carrier-backtick-cat.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-backtick-cat.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-embedded-eval",
        "files": ["reject-runid-github-env-write-carrier-embedded-eval.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-embedded-eval.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-embedded-eval-prefix",
        "files": ["reject-runid-github-env-write-carrier-embedded-eval-prefix.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-embedded-eval-prefix.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-embedded-sh-prefix",
        "files": ["reject-runid-github-env-write-carrier-embedded-sh-prefix.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-embedded-sh-prefix.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sh` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-ansic-eval",
        "files": ["reject-runid-github-env-write-carrier-ansic-eval.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-ansic-eval.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-carrier-ansic-trap",
        "files": ["reject-runid-github-env-write-carrier-ansic-trap.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-carrier-ansic-trap.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `trap` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-unmodelled-printf-v-target",
        "files": ["reject-runid-github-env-write-unmodelled-printf-v-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-unmodelled-printf-v-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `p` through `printf`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-unmodelled-read-target",
        "files": ["reject-runid-github-env-write-unmodelled-read-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-unmodelled-read-target.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `p` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-unmodelled-declare-target",
        "files": ["reject-runid-github-env-write-unmodelled-declare-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-unmodelled-declare-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `p` through `declare`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-cp-two-expansions-destination",
        "files": ["accept-runid-github-env-write-cp-two-expansions-destination.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-cp-home-profile-destination",
        "files": ["accept-runid-github-env-write-cp-home-profile-destination.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-sed-inplace-literal-script",
        "files": ["accept-runid-github-env-write-sed-inplace-literal-script.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-bash-script-data-substitution",
        "files": ["accept-runid-github-env-write-bash-script-data-substitution.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-bash-c-data-substitution",
        "files": ["accept-runid-github-env-write-bash-c-data-substitution.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-sed-n-read-unassigned-file",
        "files": ["accept-runid-github-env-write-sed-n-read-unassigned-file.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-python-script-invocation",
        "files": ["accept-runid-github-env-write-python-script-invocation.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-n-read-assigned-file",
        "files": ["reject-runid-github-env-write-sed-n-read-assigned-file.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-sed-n-read-assigned-file.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `file`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-mention-window-long-expansion-assembly",
        "files": ["reject-overrefusal-mention-window-long-expansion-assembly.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-mention-window-long-expansion-assembly.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 14) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-carrier-benign-substitution",
        "files": ["reject-overrefusal-carrier-benign-substitution.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-carrier-benign-substitution.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-new-verb-unresolvable-target",
        "files": ["reject-overrefusal-new-verb-unresolvable-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-new-verb-unresolvable-target.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `cp` with a file target `$(mktemp)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-new-verb-unmodelled-write-target",
        "files": ["reject-overrefusal-new-verb-unmodelled-write-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-new-verb-unmodelled-write-target.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `p` through `printf`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-mention-window-question-pad",
        "files": ["reject-overrefusal-mention-window-question-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-mention-window-question-pad.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 14) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-backtick-isolating",
        "files": ["reject-runid-github-env-write-mention-window-backtick-isolating.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-backtick-isolating.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-digit-positional-pad",
        "files": ["reject-runid-github-env-write-mention-window-digit-positional-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-digit-positional-pad.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-append-single-quote-join",
        "files": ["reject-runid-github-env-write-sed-append-single-quote-join.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-append-single-quote-join.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ],
    },
    {
        "id": "accept-runid-github-env-write-sed-single-quote-multiline-benign",
        "files": ["accept-runid-github-env-write-sed-single-quote-multiline-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-sed-single-quote-literal-append-benign",
        "files": ["accept-runid-github-env-write-sed-single-quote-literal-append-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-assignment-sed-no-mention",
        "files": ["accept-runid-github-env-write-assignment-sed-no-mention.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-lua-inline-program",
        "files": ["accept-runid-github-env-write-lua-inline-program.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-tclsh-script-invocation",
        "files": ["accept-runid-github-env-write-tclsh-script-invocation.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "accept-runid-github-env-write-perl-script-invocation",
        "files": ["accept-runid-github-env-write-perl-script-invocation.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-long-inplace-suffix-target",
        "files": ["reject-runid-github-env-write-sed-long-inplace-suffix-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-long-inplace-suffix-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-inplace-suffix-target",
        "files": ["reject-runid-github-env-write-sed-inplace-suffix-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-inplace-suffix-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-carrier-ansic-quoted-form",
        "files": ["reject-overrefusal-carrier-ansic-quoted-form.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-carrier-ansic-quoted-form.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-mention-window-escaped-special-pad",
        "files": ["accept-runid-github-env-write-mention-window-escaped-special-pad.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [

        ],
    },
    {
        "id": "reject-overrefusal-mention-window-bare-github-name",
        "files": ["reject-overrefusal-mention-window-bare-github-name.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-mention-window-bare-github-name.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job references `$GITHUB_ENV` (line 14) without an extractable write (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-option-cluster-ni-target",
        "files": ["reject-runid-github-env-write-sed-option-cluster-ni-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-option-cluster-ni-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-option-cluster-Ei-target",
        "files": ["reject-runid-github-env-write-sed-option-cluster-Ei-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-option-cluster-Ei-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-option-cluster-ni-e-target",
        "files": ["reject-runid-github-env-write-sed-option-cluster-ni-e-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-option-cluster-ni-e-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-space-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-space-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-space-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-dollar-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-dollar-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-dollar-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-newline-block-w-target",
        "files": ["reject-runid-github-env-write-sed-newline-block-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-newline-block-w-target.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-two-line-w-target",
        "files": ["reject-runid-github-env-write-sed-two-line-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-two-line-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-bang-pad",
        "files": ["reject-runid-github-env-write-mention-window-bang-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-bang-pad.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-interpreter-inline-program-substitution",
        "files": ["reject-overrefusal-interpreter-inline-program-substitution.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-interpreter-inline-program-substitution.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `python3` with an inline program the extractor cannot prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-eval-arithmetic-substitution",
        "files": ["reject-overrefusal-eval-arithmetic-substitution.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-eval-arithmetic-substitution.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-mention-window-zero-pad",
        "files": ["reject-overrefusal-mention-window-zero-pad.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-mention-window-zero-pad.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-nested-brace",
        "files": ["reject-runid-github-env-write-mention-window-nested-brace.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-nested-brace.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-nested-two-level",
        "files": ["reject-runid-github-env-write-mention-window-nested-two-level.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-nested-two-level.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-nested-cmdsub",
        "files": ["reject-runid-github-env-write-mention-window-nested-cmdsub.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-nested-cmdsub.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-long-inplace-abbrev-i-target",
        "files": ["reject-runid-github-env-write-sed-long-inplace-abbrev-i-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-long-inplace-abbrev-i-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-long-inplace-abbrev-in-target",
        "files": ["reject-runid-github-env-write-sed-long-inplace-abbrev-in-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-long-inplace-abbrev-in-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-long-inplace-abbrev-eq-suffix-target",
        "files": ["reject-runid-github-env-write-sed-long-inplace-abbrev-eq-suffix-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-long-inplace-abbrev-eq-suffix-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-attached-e-ni-p-target",
        "files": ["reject-runid-github-env-write-sed-attached-e-ni-p-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-attached-e-ni-p-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-attached-e-ni-w-target",
        "files": ["reject-runid-github-env-write-sed-attached-e-ni-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-attached-e-ni-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-cluster-attached-e-w-target",
        "files": ["reject-runid-github-env-write-sed-cluster-attached-e-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-cluster-attached-e-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-plus-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-plus-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-plus-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-two-regex-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-two-regex-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-two-regex-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-zero-regex-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-zero-regex-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-zero-regex-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-addressed-alt-delimiter-w-target",
        "files": ["reject-runid-github-env-write-sed-addressed-alt-delimiter-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-addressed-alt-delimiter-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-glued-block-w-target",
        "files": ["reject-runid-github-env-write-sed-glued-block-w-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-glued-block-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-mention-window-bang-pid",
        "files": ["reject-overrefusal-mention-window-bang-pid.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-mention-window-bang-pid.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-comment-paren",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-comment-paren.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-comment-paren.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-quoted-paren",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-quoted-paren.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-quoted-paren.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-subshell-paren",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-subshell-paren.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-subshell-paren.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-escaped-paren",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-escaped-paren.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-escaped-paren.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-process-substitution",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-process-substitution.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-process-substitution.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-escaped-quote",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-escaped-quote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-escaped-quote.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-line-w-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-line-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-line-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-range-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-last-w-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-last-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-last-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-space-w-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-space-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-space-w-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-regex-W-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-regex-W-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-regex-W-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-alt-delimiter-hash-w-target",
        "files": [
            "reject-runid-github-env-write-sed-alt-delimiter-hash-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-alt-delimiter-hash-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-alt-delimiter-pipe-w-target",
        "files": [
            "reject-runid-github-env-write-sed-alt-delimiter-pipe-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-alt-delimiter-pipe-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-alt-delimiter-at-w-target",
        "files": [
            "reject-runid-github-env-write-sed-alt-delimiter-at-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-alt-delimiter-at-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-negated-glued-block-w-target",
        "files": [
            "reject-runid-github-env-write-sed-negated-glued-block-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-negated-glued-block-w-target.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-w-target",
        "files": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-two-backslash-w-target",
        "files": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-two-backslash-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-percent-two-backslash-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-hash-w-target",
        "files": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-hash-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-hash-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-pipe-w-target",
        "files": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-pipe-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-mixed-range-alt-delimiter-pipe-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-ansic-escaped-quote",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-ansic-escaped-quote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-ansic-escaped-quote.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-cmdsub-backtick-paren",
        "files": [
            "reject-runid-github-env-write-mention-window-cmdsub-backtick-paren.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-cmdsub-backtick-paren.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-mention-window-cmdsub-case-pattern-paren",
        "files": [
            "accept-runid-github-env-write-mention-window-cmdsub-case-pattern-paren.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": []
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-numeric-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-numeric-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-numeric-range-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-zero-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-zero-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-zero-range-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-negated-regex-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-negated-regex-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-negated-regex-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-regex-alternation-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-regex-alternation-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-regex-alternation-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-negated-mixed-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-negated-mixed-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-negated-mixed-range-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-spaced-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-spaced-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-spaced-range-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-attached-e-negated-mixed-range-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-attached-e-negated-mixed-range-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-attached-e-negated-mixed-range-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-glued-block-W-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-glued-block-W-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-glued-block-W-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-escaped-slash-two-backslash-w-target",
        "files": [
            "reject-runid-github-env-write-sed-escaped-slash-two-backslash-w-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-escaped-slash-two-backslash-w-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-sed-escaped-slash-benign-w-target",
        "files": [
            "accept-runid-github-env-write-sed-escaped-slash-benign-w-target.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": []
    },
    {
        "id": "reject-runid-github-env-write-mention-window-brace-backtick-close",
        "files": [
            "reject-runid-github-env-write-mention-window-brace-backtick-close.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-brace-backtick-close.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-brace-cmdsub-close",
        "files": [
            "reject-runid-github-env-write-mention-window-brace-cmdsub-close.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-brace-cmdsub-close.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-nested-cmdsub-in-quotes",
        "files": [
            "reject-runid-github-env-write-mention-window-nested-cmdsub-in-quotes.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-nested-cmdsub-in-quotes.yml:19: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-continuation-ansic",
        "files": [
            "reject-runid-github-env-write-mention-window-continuation-ansic.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-continuation-ansic.yml:20: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    # #350 item 1: the array-element write-target family (A13). The four
    # closure rejects are base-ACCEPT runtime FLIPs; the continuation spelling
    # needs the relevance pre-pass; the three over-refusal pins share one root
    # cause (any unmodelled write of the now-relevant base name refuses).
    {
        "id": "reject-runid-github-env-write-array-element-read-a-target",
        "files": [
            "reject-runid-github-env-write-array-element-read-a-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-read-a-target.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-mapfile-t-target",
        "files": [
            "reject-runid-github-env-write-array-element-mapfile-t-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-mapfile-t-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `mapfile`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-printf-v-target",
        "files": [
            "reject-runid-github-env-write-array-element-printf-v-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-printf-v-target.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `printf`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-read-subscript-target",
        "files": [
            "reject-runid-github-env-write-array-element-read-subscript-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-read-subscript-target.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-continuation-target",
        "files": [
            "reject-runid-github-env-write-array-element-continuation-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-continuation-target.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-comment-continuation-target",
        "files": [
            "reject-runid-github-env-write-array-element-comment-continuation-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-comment-continuation-target.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-escaped-whitespace-comment-target",
        "files": [
            "reject-runid-github-env-write-array-element-escaped-whitespace-comment-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-escaped-whitespace-comment-target.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-array-element-continuation-eof-target",
        "files": [
            "reject-runid-github-env-write-array-element-continuation-eof-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-continuation-eof-target.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-array-element-literal-mapfile",
        "files": [
            "reject-overrefusal-runid-github-env-write-array-element-literal-mapfile.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-array-element-literal-mapfile.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `mapfile`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-array-element-literal-read",
        "files": [
            "reject-overrefusal-runid-github-env-write-array-element-literal-read.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-array-element-literal-read.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-array-element-plain-assignment",
        "files": [
            "reject-overrefusal-runid-github-env-write-array-element-plain-assignment.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-array-element-plain-assignment.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `arr`, an occurrence the extractor cannot account for (refusing rather than guessing)"
        ]
    },
    # #350 fold round 1 MINOR-1: the over-refusal floor's missing pins —
    # the no-write array target (occurrence backstop) and the benign
    # hidden-name echo the item-8 elision surfaces (both base ACCEPT,
    # shipped REFUSE, runtime cross-run).
    {
        "id": "reject-overrefusal-runid-github-env-write-array-element-no-write-target",
        "files": [
            "reject-overrefusal-runid-github-env-write-array-element-no-write-target.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-array-element-no-write-target.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `arr`, an occurrence the extractor cannot account for (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-mention-window-hidden-name-echo",
        "files": [
            "reject-overrefusal-runid-github-env-write-mention-window-hidden-name-echo.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-mention-window-hidden-name-echo.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job references `$GITHUB_ENV` (line 19) without an extractable write (refusing rather than guessing)"
        ]
    },
    # #350 here-string defect: `<<<` must not open a phantom heredoc.
    {
        "id": "reject-runid-github-env-write-here-string-not-a-heredoc",
        "files": [
            "reject-runid-github-env-write-here-string-not-a-heredoc.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-here-string-not-a-heredoc.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    # #350 item 2: xargs as a carrier (A13). The per-line walk refuses a
    # resolvable upstream; the substitution-body site drops the `$`-word
    # catch; the two wrapper spellings stay accepted boundary pins.
    {
        "id": "reject-runid-github-env-write-xargs-stdin-operand",
        "files": [
            "reject-runid-github-env-write-xargs-stdin-operand.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-xargs-stdin-operand.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `xargs` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-xargs-plain-stdin-operand",
        "files": [
            "reject-runid-github-env-write-xargs-plain-stdin-operand.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-xargs-plain-stdin-operand.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `xargs` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-xargs-unresolved-upstream",
        "files": [
            "reject-overrefusal-runid-github-env-write-xargs-unresolved-upstream.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-xargs-unresolved-upstream.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `xargs` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-xargs-in-cmdsub-operand",
        "files": [
            "reject-runid-github-env-write-xargs-in-cmdsub-operand.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-xargs-in-cmdsub-operand.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `xargs` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-xargs-literal-upstream",
        "files": [
            "accept-runid-github-env-write-xargs-literal-upstream.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-xargs-padding-short",
        "files": [
            "accept-runid-github-env-write-xargs-padding-short.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-xargs-padding-long",
        "files": [
            "accept-runid-github-env-write-xargs-padding-long.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-xargs-env-wrapper",
        "files": [
            "accept-runid-github-env-write-xargs-env-wrapper.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-xargs-multiline-pipe",
        "files": [
            "accept-runid-github-env-write-xargs-multiline-pipe.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 fold round 1: boundary accepts for the newly named residual
    # sub-shapes — the item-2 assignment-wrapped nested form, the
    # substitution-nested continuation, and the array slice/offset/
    # multi-line-subscript spellings (all base ACCEPT, shipped ACCEPT,
    # runtime FLIP; extending the mechanisms is deferred).
    {
        "id": "accept-runid-github-env-write-xargs-assignment-wrapped-nested",
        "files": [
            "accept-runid-github-env-write-xargs-assignment-wrapped-nested.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350d moved the former
    # `accept-runid-github-env-write-array-element-cmdsub-continuation`
    # boundary pin to the reject set (the substitution-body descent closes
    # it); see `reject-runid-github-env-write-array-element-cmdsub-assign-continuation`.
    {
        "id": "accept-runid-github-env-write-array-element-slice-target",
        "files": [
            "accept-runid-github-env-write-array-element-slice-target.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-array-element-offset-target",
        "files": [
            "accept-runid-github-env-write-array-element-offset-target.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-array-element-multiline-subscript",
        "files": [
            "accept-runid-github-env-write-array-element-multiline-subscript.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # Fold round 3 MAJOR-2 / NIT-2: the per-line comment test has no
    # previous-line context, so a `#` immediately after an escaped
    # newline is read as a comment and the joined target never reaches
    # the relevance set; the gate ACCEPTs while bash joins (a named
    # boundary residual, runtime FLIP).
    {
        "id": "accept-runid-github-env-write-array-element-hash-after-escaped-newline-target",
        "files": [
            "accept-runid-github-env-write-array-element-hash-after-escaped-newline-target.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 item 9: `--expression` long-option abbreviations (A13).
    {
        "id": "reject-runid-github-env-write-sed-expression-abbrev-e-eq",
        "files": [
            "reject-runid-github-env-write-sed-expression-abbrev-e-eq.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-expression-abbrev-e-eq.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-expression-abbrev-ex-eq",
        "files": [
            "reject-runid-github-env-write-sed-expression-abbrev-ex-eq.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-expression-abbrev-ex-eq.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-expression-abbrev-expr-eq",
        "files": [
            "reject-runid-github-env-write-sed-expression-abbrev-expr-eq.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-expression-abbrev-expr-eq.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-expression-abbrev-expre-eq",
        "files": [
            "reject-runid-github-env-write-sed-expression-abbrev-expre-eq.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-expression-abbrev-expre-eq.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-sed-expression-abbrev-expressio-eq",
        "files": [
            "reject-runid-github-env-write-sed-expression-abbrev-expressio-eq.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-expression-abbrev-expressio-eq.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-sed-expression-abbrev-benign",
        "files": [
            "accept-runid-github-env-write-sed-expression-abbrev-benign.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 item 8 (boundary, partial credit): the bounded empty-pad elision
    # closes the `''` and `$'\0'`-only spellings; the other measured NUL
    # spellings stay accepted boundary pins.
    {
        "id": "reject-runid-github-env-write-mention-window-empty-single-quote-pad",
        "files": [
            "reject-runid-github-env-write-mention-window-empty-single-quote-pad.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-empty-single-quote-pad.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-mention-window-empty-ansic-pad",
        "files": [
            "reject-runid-github-env-write-mention-window-empty-ansic-pad.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-mention-window-empty-ansic-pad.yml:21: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-mention-window-empty-pad-ansic-hex",
        "files": [
            "accept-runid-github-env-write-mention-window-empty-pad-ansic-hex.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-mention-window-empty-pad-empty-dquote",
        "files": [
            "accept-runid-github-env-write-mention-window-empty-pad-empty-dquote.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 boundary pins: items 4, 5 and 11 stay open, each with a committed
    # accept pin.
    {
        "id": "accept-runid-github-env-write-python3-stdin-program",
        "files": [
            "accept-runid-github-env-write-python3-stdin-program.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-python3-stdin-heredoc-program",
        "files": [
            "accept-runid-github-env-write-python3-stdin-heredoc-program.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-python3-process-substitution-program",
        "files": [
            "accept-runid-github-env-write-python3-process-substitution-program.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-cmdsub-heredoc-program",
        "files": [
            "accept-runid-github-env-write-cmdsub-heredoc-program.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 item 12 (scoped as #354): the trailing-backslash continuation masking
    # family. Every reject is measured base ACCEPT -> shipped REFUSE; the closure
    # rows runtime-FLIP (the body-final `dd of=` row truncates the env file: runtime
    # absent/destructive), the over-refusal pins runtime cross-run. Every fixture is
    # mention-bearing and carries the `read -a arr < pf` device.
    {
        "id": "reject-runid-github-env-write-continuation-mask-cp",
        "files": [
            "reject-runid-github-env-write-continuation-mask-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-cp.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-mv",
        "files": [
            "reject-runid-github-env-write-continuation-mask-mv.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-mv.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-install",
        "files": [
            "reject-runid-github-env-write-continuation-mask-install.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-install.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-mask-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-dd-of.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-sed-w",
        "files": [
            "reject-runid-github-env-write-continuation-mask-sed-w.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-sed-w.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-sed-cmdsub",
        "files": [
            "reject-runid-github-env-write-continuation-mask-sed-cmdsub.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-sed-cmdsub.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-indicator-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-mask-indicator-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-indicator-dd-of.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-eof-mask-cp",
        "files": [
            "reject-runid-github-env-write-continuation-eof-mask-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-eof-mask-cp.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-eof-mask-mv",
        "files": [
            "reject-runid-github-env-write-continuation-eof-mask-mv.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-eof-mask-mv.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-eof-mask-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-eof-mask-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-eof-mask-dd-of.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-eof-mask-folded-cp",
        "files": [
            "reject-runid-github-env-write-continuation-eof-mask-folded-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-eof-mask-folded-cp.yml:24: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-folded-blank-verb",
        "files": [
            "reject-runid-github-env-write-continuation-mask-folded-blank-verb.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-folded-blank-verb.yml:27: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-folded-more-indent-cont",
        "files": [
            "reject-runid-github-env-write-continuation-mask-folded-more-indent-cont.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-folded-more-indent-cont.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-folded-more-indent-verb-eof",
        "files": [
            "reject-runid-github-env-write-continuation-mask-folded-more-indent-verb-eof.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-folded-more-indent-verb-eof.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-folded-over2-eof",
        "files": [
            "reject-runid-github-env-write-continuation-mask-folded-over2-eof.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-folded-over2-eof.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-plain-blank",
        "files": [
            "reject-runid-github-env-write-continuation-mask-plain-blank.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-plain-blank.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-literal-single-blank-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-literal-single-blank-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-literal-single-blank-cp.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-same-dd-of",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-same-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-same-dd-of.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-plain-dd-of-eof",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-plain-dd-of-eof.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-plain-dd-of-eof.yml:28: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-blank-indent-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-blank-indent-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-blank-indent-cp.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-mask-folded-blank-env-prefix-cp",
        "files": [
            "reject-runid-github-env-write-continuation-mask-folded-blank-env-prefix-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-mask-folded-blank-env-prefix-cp.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-blank-builtin-prefix-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-blank-builtin-prefix-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-blank-builtin-prefix-cp.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-eof-command-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-eof-command-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-eof-command-cp.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-uniform-cmdsub-eof-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-uniform-cmdsub-eof-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-uniform-cmdsub-eof-cp.yml:25: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-folded-more-indent-blank-cp",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-more-indent-blank-cp.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-folded-more-indent-blank-cp.yml:26: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-continuation-benign-literal",
        "files": [
            "accept-runid-github-env-write-continuation-benign-literal.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-continuation-benign-sed-read",
        "files": [
            "accept-runid-github-env-write-continuation-benign-sed-read.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350e: the continuation-bound fold. The former `>8` continuation
    # fail-open is closed fail-closed: chains up to 64 physical lines join
    # (and are caught by the existing write detection), and a longer chain
    # is refused by `_run_id_continuation_bound_refusal`. Every case is
    # mention-bearing and device-bearing; all eight declare `base_exit: 0`.
    # The raw-payload-crossing case (fold round 1, lens 1 F2) is the
    # raw-arm-only shape: its >64 raw run walks into a heredoc payload while
    # the bash arm stays under the bound, so it pins the predicate's raw arm.
    {
        "id": "reject-runid-github-env-write-continuation-chain-over-old-bound",
        "files": [
            "reject-runid-github-env-write-continuation-chain-over-old-bound.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-chain-over-old-bound.yml:35: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-chain-over-analysis-bound",
        "files": [
            "reject-runid-github-env-write-continuation-chain-over-analysis-bound.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-chain-over-analysis-bound.yml:91: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job has a backslash continuation chain longer than the physical-line analysis bound (64 lines), so a joined command's write targets cannot be extracted (refusing rather than guessing; split the chain into shorter logical lines)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-continuation-chain-benign-at-analysis-bound",
        "files": [
            "accept-runid-github-env-write-continuation-chain-benign-at-analysis-bound.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-chain-benign-over-bound",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-benign-over-bound.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-benign-over-bound.yml:91: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job has a backslash continuation chain longer than the physical-line analysis bound (64 lines), so a joined command's write targets cannot be extracted (refusing rather than guessing; split the chain into shorter logical lines)"
        ]
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-chain-blank-inflated-over-analysis-bound",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-blank-inflated-over-analysis-bound.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-blank-inflated-over-analysis-bound.yml:92: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job has a backslash continuation chain longer than the physical-line analysis bound (64 lines), so a joined command's write targets cannot be extracted (refusing rather than guessing; split the chain into shorter logical lines)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-continuation-chain-benign-mid-range",
        "files": [
            "accept-runid-github-env-write-continuation-chain-benign-mid-range.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "accept-runid-github-env-write-continuation-chain-benign-at-analysis-bound-eof",
        "files": [
            "accept-runid-github-env-write-continuation-chain-benign-at-analysis-bound-eof.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-continuation-chain-raw-payload-crossing",
        "files": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-raw-payload-crossing.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-continuation-chain-raw-payload-crossing.yml:95: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job has a backslash continuation chain longer than the physical-line analysis bound (64 lines), so a joined command's write targets cannot be extracted (refusing rather than guessing; split the chain into shorter logical lines)"
        ]
    },
    # #350 item 12, fold round 1 (lens-1 BLOCKER-1): the cross-line-quote
    # family. A single quote opened on an earlier body line and closed on
    # the line that ends in `\` used to make the per-line predicate read
    # the closing quote as an opening one and miss the `\`+newline pair
    # bash removes. Every reject is measured base ACCEPT -> folded REFUSE
    # with runtime FLIP; the accept pin is a benign cross-line single-quoted
    # string with a relative target (runtime cross-run). All are
    # mention-bearing and device-bearing (`read -a arr < pf`, or the direct
    # `$(printenv ...)` target).
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-canonical",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-canonical.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-canonical.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-mv",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-mv.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-mv.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-install-doubled",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-install-doubled.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-install-doubled.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-dd-of.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-sed-w-indicator",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-sed-w-indicator.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-sed-w-indicator.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-folded-over2",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-folded-over2.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-folded-over2.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-direct-device",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-direct-device.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-direct-device.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$(printenv \"${x}${y}\")` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-continuation-quote-crossline-benign",
        "files": [
            "accept-runid-github-env-write-continuation-quote-crossline-benign.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    # #350 item 12, fold round 2 (lens-1 BLOCKER-1): the ANSI-C `$'…'`
    # escaped-quote sub-class. The fold round 1 whole-body quote state scanned
    # `$'…'` as a plain `'…'` region, so `\'` read as a close and the next
    # `'` as a new open; the phantom quote carried to the next line suppressed
    # the continuation join. Each spelling is measured base ACCEPT / previous
    # head (bdbb8cfd) REFUSE -> folded REFUSE with a runtime FLIP, is
    # mention-bearing and device-bearing (`read -a arr < pf`), and uses
    # relative targets.
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-dd-of.yml:35: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-sed-w",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-sed-w.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-mid-sed-w.yml:35: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-dd-of.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-sed-w",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-sed-w.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-end-sed-w.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-dd-of",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-dd-of.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-dd-of.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-sed-w",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-sed-w.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-escaped-twice-sed-w.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    # #350 item 12, fold round 3 (fold round 2 re-lens BLOCKER-1): the plain
    # `'` opener lost its `quote is None` guard, so a `'` inside an open
    # double-quoted (or locale `$"…"`) region opened a phantom single-quote
    # state, suppressed the line-2 continuation join, and left 10 measured
    # runtime-FLIP spellings accepted. Each reject is base ACCEPT / previous
    # head (`7d712907`) REFUSE -> fold round 3 REFUSE with a runtime FLIP
    # (fold round 2 accepted it because of the defect), and is mention-bearing
    # and device-bearing; the boundary accept pin keeps the shape the
    # corrected model accepts (base/`7d712907` ACCEPT, fold round 2 REFUSE ->
    # fold round 3 ACCEPT, runtime cross-run).
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-dquote-adjacent",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-dquote-adjacent.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-dquote-adjacent.yml:36: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-squote-in-dquote",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-squote-in-dquote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-squote-in-dquote.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-locale-squote-in-dquote",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-locale-squote-in-dquote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-locale-squote-in-dquote.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-ansic-squote-in-dquote",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-squote-in-dquote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-ansic-squote-in-dquote.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-prior-squote-in-dquote",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-prior-squote-in-dquote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-prior-squote-in-dquote.yml:35: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-mv-squote-in-dquote-eof",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-mv-squote-in-dquote-eof.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-mv-squote-in-dquote-eof.yml:34: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "reject-runid-github-env-write-continuation-quote-crossline-split-dd-of-squote-in-dquote",
        "files": [
            "reject-runid-github-env-write-continuation-quote-crossline-split-dd-of-squote-in-dquote.yml"
        ],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-continuation-quote-crossline-split-dd-of-squote-in-dquote.yml:35: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)"
        ]
    },
    {
        "id": "accept-runid-github-env-write-continuation-quote-crossline-ansic-dquote-literal",
        "files": [
            "accept-runid-github-env-write-continuation-quote-crossline-ansic-dquote-literal.yml"
        ],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": []
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-ln-last-operand",
        "files": ["reject-runid-github-env-write-operand-mask-ln-last-operand.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-ln-last-operand.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-ln-continuation",
        "files": ["reject-runid-github-env-write-operand-mask-ln-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-ln-continuation.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-rsync-last-operand",
        "files": ["reject-runid-github-env-write-operand-mask-rsync-last-operand.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-rsync-last-operand.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-sed-w-attached",
        "files": ["reject-runid-github-env-write-operand-mask-sed-w-attached.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-sed-w-attached.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-lt",
        "files": ["reject-runid-github-env-write-operand-mask-cp-lt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-lt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-gt",
        "files": ["reject-runid-github-env-write-operand-mask-cp-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-append",
        "files": ["reject-runid-github-env-write-operand-mask-cp-append.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-append.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-fd2-gt",
        "files": ["reject-runid-github-env-write-operand-mask-cp-fd2-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-fd2-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-fd2-dup",
        "files": ["reject-runid-github-env-write-operand-mask-cp-fd2-dup.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-fd2-dup.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-gt-amp2",
        "files": ["reject-runid-github-env-write-operand-mask-cp-gt-amp2.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-gt-amp2.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-cp-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-fd2-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-cp-fd2-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-fd2-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-cp-clobber",
        "files": ["reject-runid-github-env-write-operand-mask-cp-clobber.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-cp-clobber.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-lt",
        "files": ["reject-runid-github-env-write-operand-mask-mv-lt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-lt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-gt",
        "files": ["reject-runid-github-env-write-operand-mask-mv-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-append",
        "files": ["reject-runid-github-env-write-operand-mask-mv-append.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-append.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-fd2-gt",
        "files": ["reject-runid-github-env-write-operand-mask-mv-fd2-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-fd2-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-fd2-dup",
        "files": ["reject-runid-github-env-write-operand-mask-mv-fd2-dup.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-fd2-dup.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-gt-amp2",
        "files": ["reject-runid-github-env-write-operand-mask-mv-gt-amp2.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-gt-amp2.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-mv-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-fd2-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-mv-fd2-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-fd2-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-mv-clobber",
        "files": ["reject-runid-github-env-write-operand-mask-mv-clobber.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-mv-clobber.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-lt",
        "files": ["reject-runid-github-env-write-operand-mask-install-lt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-lt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-gt",
        "files": ["reject-runid-github-env-write-operand-mask-install-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-append",
        "files": ["reject-runid-github-env-write-operand-mask-install-append.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-append.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-fd2-gt",
        "files": ["reject-runid-github-env-write-operand-mask-install-fd2-gt.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-fd2-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-fd2-dup",
        "files": ["reject-runid-github-env-write-operand-mask-install-fd2-dup.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-fd2-dup.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-gt-amp2",
        "files": ["reject-runid-github-env-write-operand-mask-install-gt-amp2.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-gt-amp2.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-install-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-fd2-read-write",
        "files": ["reject-runid-github-env-write-operand-mask-install-fd2-read-write.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-fd2-read-write.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-install-clobber",
        "files": ["reject-runid-github-env-write-operand-mask-install-clobber.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-install-clobber.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-herestring",
        "files": ["reject-runid-github-env-write-operand-mask-herestring.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-herestring.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-heredoc",
        "files": ["reject-runid-github-env-write-operand-mask-heredoc.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-heredoc.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-brace-fd",
        "files": ["reject-runid-github-env-write-operand-mask-brace-fd.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-brace-fd.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-subshell-spaced",
        "files": ["reject-runid-github-env-write-operand-mask-subshell-spaced.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-subshell-spaced.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-subshell-continuation",
        "files": ["reject-runid-github-env-write-operand-mask-subshell-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-subshell-continuation.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-subshell-attached",
        "files": ["reject-runid-github-env-write-operand-mask-subshell-attached.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-subshell-attached.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-subshell-attached-redirect",
        "files": ["reject-runid-github-env-write-operand-mask-subshell-attached-redirect.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-subshell-attached-redirect.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-subshell-truncate",
        "files": ["reject-runid-github-env-write-operand-mask-subshell-truncate.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-subshell-truncate.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-array-assignment",
        "files": ["reject-overrefusal-operand-mask-array-assignment.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-array-assignment.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-subshell-touch",
        "files": ["reject-overrefusal-operand-mask-subshell-touch.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-subshell-touch.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-read",
        "files": ["reject-overrefusal-operand-mask-compensation-read.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-read.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-process-substitution",
        "files": ["reject-overrefusal-operand-mask-compensation-process-substitution.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-process-substitution.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-operand-mask-ln-s",
        "files": ["accept-operand-mask-ln-s.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-ln-sf-sh",
        "files": ["accept-operand-mask-ln-sf-sh.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-ln-t",
        "files": ["accept-operand-mask-ln-t.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-rsync-a",
        "files": ["accept-operand-mask-rsync-a.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-rsync-remote",
        "files": ["accept-operand-mask-rsync-remote.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-rsync-exclude",
        "files": ["accept-operand-mask-rsync-exclude.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-sed-w-space",
        "files": ["accept-operand-mask-sed-w-space.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-sed-1w",
        "files": ["accept-operand-mask-sed-1w.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-sed-w-attached-benign",
        "files": ["accept-operand-mask-sed-w-attached-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-subshell-benign",
        "files": ["accept-operand-mask-subshell-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-subshell-benign-attached",
        "files": ["accept-operand-mask-subshell-benign-attached.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-gt",
        "files": ["accept-operand-mask-cp-gt.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-lt",
        "files": ["accept-operand-mask-cp-lt.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-dup",
        "files": ["accept-operand-mask-cp-dup.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-tee-gt",
        "files": ["accept-operand-mask-tee-gt.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-touch-2gt",
        "files": ["accept-operand-mask-touch-2gt.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-read-write-benign",
        "files": ["accept-operand-mask-cp-read-write-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-fd-close",
        "files": ["accept-operand-mask-cp-fd-close.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-gt-fd-close",
        "files": ["accept-operand-mask-cp-gt-fd-close.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-lt-dup-2",
        "files": ["accept-operand-mask-cp-lt-dup-2.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-brace-name",
        "files": ["accept-operand-mask-cp-brace-name.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-gt-cp",
        "files": ["accept-operand-mask-cp-gt-cp.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-operand-mask-cp-gt-sed",
        "files": ["accept-operand-mask-cp-gt-sed.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-prefix-gt",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-prefix-gt.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-prefix-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-prefix-lt",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-prefix-lt.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-prefix-lt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-prefix-dup",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-prefix-dup.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-prefix-dup.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-prefix-2gt",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-prefix-2gt.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-prefix-2gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-fd-lt-amp",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-fd-lt-amp.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-fd-lt-amp.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-fd-ltlt-amp",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-fd-ltlt-amp.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-fd-ltlt-amp.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `OUT`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-fd-2lt-amp",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-fd-2lt-amp.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-fd-2lt-amp.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-fd-brace-lt-amp",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-fd-brace-lt-amp.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-fd-brace-lt-amp.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-read-write-arr",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-read-write-arr.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-read-write-arr.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-amp-gt",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-amp-gt.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-amp-gt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-amp-gtgt",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-amp-gtgt.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-amp-gtgt.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-tee-trailing",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-tee-trailing.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-tee-trailing.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-touch-trailing",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-touch-trailing.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-touch-trailing.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-truncate-trailing",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-truncate-trailing.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-truncate-trailing.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sed-inplace-trailing",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sed-inplace-trailing.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sed-inplace-trailing.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },

    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-cp-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-cp-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-cp-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-mv-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-mv-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-mv-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `mv` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-mv-lt-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-mv-lt-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-mv-lt-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `mv` with a file target `$(echo)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-install-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-install-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-install-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `install` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-install-lt-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-install-lt-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-install-lt-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `install` with a file target `$(echo)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-tee-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-tee-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-tee-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-tee-lt-multivar",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-tee-lt-multivar.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-tee-lt-multivar.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$A$B` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-touch-lt-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-touch-lt-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-touch-lt-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `touch` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-truncate-read-write-env",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-truncate-read-write-env.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-truncate-read-write-env.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `truncate` with a file target `$GITHUB_ENV` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-amp-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-amp-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-cp-lt-amp-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `cp` with a file target `$(echo)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-tee-herestring-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-tee-herestring-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-tee-herestring-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$(echo)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-python-lt-multivar",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-python-lt-multivar.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-python-lt-multivar.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `python3` with a file target `$A$B` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-sole-perl-lt-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-sole-perl-lt-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-sole-perl-lt-subst.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `perl` with a file target `$(echo)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-subst.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `touch` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-arr",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-arr.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-arr.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-out",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-out.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-touch-out.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `OUT`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-subst.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-truncate-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-truncate-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-truncate-subst.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `truncate` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-sed-inplace-subst",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-sed-inplace-subst.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-sed-inplace-subst.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `sed` with a file target `$(echo x)` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-out",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-out.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-tee-out.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `OUT`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-tee-multivar",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-ln-tee-multivar.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-ln-tee-multivar.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job runs `tee` with a file target `$A$B` the extractor cannot resolve to the env file or prove harmless (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-truncate-arr",
        "files": ["reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-truncate-arr.yml"],
        "exit": 1,
        "base_exit": 1,
        "diagnostics": [
            "reject-runid-github-env-write-operand-mask-boundary-shadow-rsync-truncate-arr.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-process-substitution-attached",
        "files": ["reject-overrefusal-operand-mask-compensation-process-substitution-attached.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-process-substitution-attached.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-ln-unknown",
        "files": ["reject-overrefusal-operand-mask-compensation-ln-unknown.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-ln-unknown.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `unknown`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-rsync-unknown",
        "files": ["reject-overrefusal-operand-mask-compensation-rsync-unknown.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-rsync-unknown.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `unknown`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-operand-mask-compensation-sed-unknown",
        "files": ["reject-overrefusal-operand-mask-compensation-sed-unknown.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-operand-mask-compensation-sed-unknown.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven \u2014 a preceding step in this job mentions `unknown`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-operand-mask-sed-read-write-benign",
        "files": ["accept-operand-mask-sed-read-write-benign.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # #350d: ANSI-C escaped-quote lexer (#350 item 17), the substitution
    # sub-family (#350 item 14 w3-w8), `;;` segmentation (w7) and the sed
    # `s///w file` flag (#350 item 13 residual). Every case segments their
    # measured base verdict as `base_exit`.
    # ------------------------------------------------------------------
    {
        "id": "reject-runid-github-env-write-ansic-escaped-quote-tail",
        "files": ["reject-runid-github-env-write-ansic-escaped-quote-tail.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-ansic-escaped-quote-tail.yml:33: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-ansic-escaped-quote-body",
        "files": ["reject-runid-github-env-write-ansic-escaped-quote-body.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-ansic-escaped-quote-body.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-ansic-concat-after-close",
        "files": ["reject-runid-github-env-write-ansic-concat-after-close.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-ansic-concat-after-close.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-ansic-cross-model-continuation",
        "files": ["reject-runid-github-env-write-ansic-cross-model-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-ansic-cross-model-continuation.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-cmdsub-assign",
        "files": ["reject-runid-github-env-write-subst-cmdsub-assign.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-cmdsub-assign.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-cmdsub-spaced",
        "files": ["reject-runid-github-env-write-subst-cmdsub-spaced.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-cmdsub-spaced.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-cmdsub-attached",
        "files": ["reject-runid-github-env-write-subst-cmdsub-attached.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-cmdsub-attached.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-backtick",
        "files": ["reject-runid-github-env-write-subst-backtick.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-backtick.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-eval-double",
        "files": ["reject-runid-github-env-write-subst-eval-double.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-eval-double.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-eval-single",
        "files": ["reject-runid-github-env-write-subst-eval-single.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-eval-single.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-case",
        "files": ["reject-runid-github-env-write-subst-case.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-case.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-case-paren",
        "files": ["reject-runid-github-env-write-subst-case-paren.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-case-paren.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-nested-parens",
        "files": ["reject-runid-github-env-write-subst-nested-parens.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-nested-parens.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-subst-cmdsub-continuation",
        "files": ["reject-runid-github-env-write-subst-cmdsub-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-subst-cmdsub-continuation.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-array-element-cmdsub-assign-continuation",
        "files": ["reject-runid-github-env-write-array-element-cmdsub-assign-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-array-element-cmdsub-assign-continuation.yml:32: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-attached",
        "files": ["reject-runid-github-env-write-sed-sflag-attached.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-attached.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-spaced",
        "files": ["reject-runid-github-env-write-sed-sflag-spaced.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-spaced.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-alt-delimiter",
        "files": ["reject-runid-github-env-write-sed-sflag-alt-delimiter.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-alt-delimiter.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-gw",
        "files": ["reject-runid-github-env-write-sed-sflag-gw.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-gw.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-attached-e",
        "files": ["reject-runid-github-env-write-sed-sflag-attached-e.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-attached-e.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-address-line",
        "files": ["reject-runid-github-env-write-sed-sflag-address-line.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-address-line.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-address-range",
        "files": ["reject-runid-github-env-write-sed-sflag-address-range.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-address-range.yml:29: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-address-regex",
        "files": ["reject-runid-github-env-write-sed-sflag-address-regex.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-address-regex.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-expression-eq",
        "files": ["reject-runid-github-env-write-sed-sflag-expression-eq.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-expression-eq.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-ex-abbrev",
        "files": ["reject-runid-github-env-write-sed-sflag-ex-abbrev.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-ex-abbrev.yml:30: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-runid-github-env-write-sed-sflag-address-alt-delimiter",
        "files": ["reject-runid-github-env-write-sed-sflag-address-alt-delimiter.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-runid-github-env-write-sed-sflag-address-alt-delimiter.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job writes `arr` through `read`, which the extractor does not model (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-subst-pure-target",
        "files": ["reject-overrefusal-runid-github-env-write-subst-pure-target.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-subst-pure-target.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job mentions `OUT`, an occurrence the extractor cannot account for (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-overrefusal-runid-github-env-write-eval-pure-name",
        "files": ["reject-overrefusal-runid-github-env-write-eval-pure-name.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-overrefusal-runid-github-env-write-eval-pure-name.yml:31: run-id: '${{ env.SOURCE_RUN_ID }}' cannot be proven — a preceding step in this job runs `eval` with a command string that names the value the download resolves through (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-runid-github-env-write-ansic-benign-env-tail",
        "files": ["accept-runid-github-env-write-ansic-benign-env-tail.yml"],
        "exit": 0,
        "base_exit": 1,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-ansic-parseint-tail",
        "files": ["accept-runid-github-env-write-ansic-parseint-tail.yml"],
        "exit": 0,
        "base_exit": 1,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-ansic-multiline-trailing-backslash",
        "files": ["accept-runid-github-env-write-ansic-multiline-trailing-backslash.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-subst-procsub-direct-target",
        "files": ["accept-runid-github-env-write-subst-procsub-direct-target.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-subst-case-separator-outside-case",
        "files": ["accept-runid-github-env-write-subst-case-separator-outside-case.yml"],
        "exit": 0,
        "base_exit": 1,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-sed-sflag-benign-literal",
        "files": ["accept-runid-github-env-write-sed-sflag-benign-literal.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-sed-sflag-no-w",
        "files": ["accept-runid-github-env-write-sed-sflag-no-w.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-sed-sflag-w-in-replacement",
        "files": ["accept-runid-github-env-write-sed-sflag-w-in-replacement.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-sed-sflag-wg-filename",
        "files": ["accept-runid-github-env-write-sed-sflag-wg-filename.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-sed-sflag-block-opener",
        "files": ["accept-runid-github-env-write-sed-sflag-block-opener.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    {
        "id": "accept-runid-github-env-write-ansic-octal-name-concat-target",
        "files": ["accept-runid-github-env-write-ansic-octal-name-concat-target.yml"],
        "exit": 0,
        "base_exit": 0,
        "excluded": 1,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # #399: shell artifact downloaders in run bodies and delegated
    # `scripts/ci/*.sh` scripts. Every reject case pins its exact diagnostic
    # (the token rendering, the nested `scripts/ci/<name>.sh:<line>`
    # provenance, the unresolved-delegation and depth-cap messages, the
    # delegated-script floor); every case declares the measured base verdict
    # of the pre-#399 gate (`base_exit: 0`).
    # ------------------------------------------------------------------
    {
        "id": "reject-shell-gh-run-download-inline",
        "files": ["reject-shell-gh-run-download-inline.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-inline.yml:9: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
            "reject-shell-gh-run-download-inline.yml:10: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-quoted-arg",
        "files": ["reject-shell-gh-run-download-quoted-arg.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-quoted-arg.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-continuation",
        "files": ["reject-shell-gh-run-download-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-continuation.yml:9: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
            "reject-shell-gh-run-download-continuation.yml:12: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-gh-run-download",
        "files": ["reject-shell-delegation-gh-run-download.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-gh-run-download.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-cmdsub",
        "files": ["reject-shell-delegation-cmdsub.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cmdsub.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-stdin-redirect",
        "files": ["reject-shell-delegation-stdin-redirect.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-stdin-redirect.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-unresolvable",
        "files": ["reject-shell-delegation-unresolvable.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-unresolvable.yml:8: delegation to `scripts/ci/shell-missing.sh` — the gate cannot resolve the referenced script (refusing rather than skipping); fix the path, restore the script, or reword the mention",
        ],
    },
    {
        "id": "reject-shell-delegation-transitive",
        "files": ["reject-shell-delegation-transitive.yml"],
        "extra_files": {
            "scripts/ci/shell-hop-a.sh": "shell-hop-a.sh",
            "scripts/ci/shell-hop-b.sh": "shell-hop-b.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-transitive.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-hop-b.sh:7` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-depth-cap",
        "files": ["reject-shell-delegation-depth-cap.yml"],
        "extra_files": {
            "scripts/ci/shell-chain-1.sh": "shell-chain-1.sh",
            "scripts/ci/shell-chain-2.sh": "shell-chain-2.sh",
            "scripts/ci/shell-chain-3.sh": "shell-chain-3.sh",
            "scripts/ci/shell-chain-4.sh": "shell-chain-4.sh",
            "scripts/ci/shell-chain-5.sh": "shell-chain-5.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-depth-cap.yml:9: delegation to `scripts/ci/shell-chain-5.sh` from `scripts/ci/shell-chain-4.sh:6` exceeds the nested-delegation depth cap (4) — the gate cannot prove the referenced script's body (refusing rather than skipping)",
        ],
    },
    {
        "id": "reject-shell-delegation-floor",
        "files": [
            "accept-needs-flow.yml",
            "accept-needs-bare.yml",
            "accept-needs-after-steps.yml",
            "accept-needs-same-indent.yml",
            "accept-needs-quoted.yml",
            "accept-bom-quoted-jobs.yml",
            "accept-templated-upload.yml",
            "accept-producer-is-consumer.yml",
            "accept-cross-run-run-id.yml",
            "accept-block-scalar.yml",
            "accept-quoted-uses.yml",
            "accept-run-id-with-needs.yml",
        ],
        "exit": 1,
        "base_exit": 0,
        "floor": True,
        "diagnostics": [
            "delegated-script floor: only 0 distinct delegated script(s) resolved from workflow run bodies; the floor is 6 — update the floor constant only if the delegations were intentionally removed (refusing rather than passing a tree where the delegation scan is vacuous)",
        ],
    },
    {
        "id": "accept-shell-run-body-comment-token",
        "files": ["accept-shell-run-body-comment-token.yml"],
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-shell-benign-delegation",
        "files": ["accept-shell-benign-delegation.yml"],
        "extra_files": {"scripts/ci/shell-benign.sh": "shell-benign.sh"},
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    {
        "id": "accept-shell-delegation-cycle",
        "files": ["accept-shell-delegation-cycle.yml"],
        "extra_files": {
            "scripts/ci/shell-cycle-a.sh": "shell-cycle-a.sh",
            "scripts/ci/shell-cycle-b.sh": "shell-cycle-b.sh",
        },
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-shell-delegation-prefixed-path",
        "files": ["reject-shell-delegation-prefixed-path.yml"],
        "extra_files": {
            "dir/scripts/ci/shell-evil.sh": "shell-evil.sh",
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-prefixed-path.yml:8: shell artifact downloader (`gh run download`) in `dir/scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    # ------------------------------------------------------------------
    # #399 fold round 1: the normalized phrase test, the executed-path
    # delegation model, the cwd refusals, the harness escape fixtures and
    # the continuation-bound fixture. Every reject case pins its measured
    # diagnostic; every case declares the measured base verdict of the
    # pre-#399 gate (`base_exit: 0`).
    # ------------------------------------------------------------------
    {
        "id": "reject-shell-gh-run-download-double-space",
        "files": ["reject-shell-gh-run-download-double-space.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-double-space.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-tab",
        "files": ["reject-shell-gh-run-download-tab.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-tab.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-cmdsub-spaced",
        "files": ["reject-shell-gh-run-download-cmdsub-spaced.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-cmdsub-spaced.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-backtick-spaced",
        "files": ["reject-shell-gh-run-download-backtick-spaced.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-backtick-spaced.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-repo-flag",
        "files": ["reject-shell-gh-run-download-repo-flag.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-repo-flag.yml:9: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-payload-continuation",
        "files": ["reject-shell-gh-run-download-payload-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-payload-continuation.yml:9: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-ifs",
        "files": ["reject-shell-gh-ifs.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-ifs.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-double-slash",
        "files": ["reject-shell-delegation-double-slash.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-double-slash.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-dot-segment",
        "files": ["reject-shell-delegation-dot-segment.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-dot-segment.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-parent-segment",
        "files": ["reject-shell-delegation-parent-segment.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-parent-segment.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-case-component",
        "files": ["reject-shell-delegation-case-component.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-case-component.yml:9: delegation to `Scripts/ci/shell-evil.sh` — the gate cannot resolve the referenced script (refusing rather than skipping); fix the path, restore the script, or reword the mention",
        ],
    },
    {
        "id": "reject-shell-delegation-case-extension",
        "files": ["reject-shell-delegation-case-extension.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-case-extension.yml:9: delegation to `scripts/ci/EVIL.SH` — the gate cannot resolve the referenced script (refusing rather than skipping); fix the path, restore the script, or reword the mention",
        ],
    },
    {
        "id": "reject-shell-delegation-quoted-inner",
        "files": ["reject-shell-delegation-quoted-inner.yml"],
        "extra_files": {"scripts/ci/evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-quoted-inner.yml:8: shell artifact downloader (`gh run download`) in `scripts/ci/evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-absolute-path",
        "files": ["reject-shell-delegation-absolute-path.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-absolute-path.yml:8: delegation to `/tmp/out/scripts/ci/shell-evil.sh` resolves outside the scanned root — the gate resolves `scripts/ci/*.sh` delegations under the scanned root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-working-directory",
        "files": ["reject-shell-delegation-working-directory.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-working-directory.yml:10: delegation to `scripts/ci/shell-evil.sh` under `working-directory: sub` — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-prefix",
        "files": ["reject-shell-delegation-cd-prefix.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-prefix.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-continuation-over-bound",
        "files": ["reject-shell-continuation-over-bound.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-continuation-over-bound.yml:8: shell text in this `run:` body has a backslash continuation chain longer than the physical-line analysis bound (64 lines), so a joined downloader or delegation cannot be extracted (refusing rather than guessing; split the chain into shorter logical lines)",
        ],
    },
    {
        "id": "accept-shell-delegation-bak-suffix",
        "files": ["accept-shell-delegation-bak-suffix.yml"],
        "extra_files": {"scripts/ci/shell-benign.sh.bak": "shell-benign.sh"},
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-shell-delegation-symlink-escape",
        "files": ["reject-shell-delegation-symlink-escape.yml"],
        "extra_symlinks": {"scripts/ci/shell-benign.sh": "shell-benign.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-symlink-escape.yml:9: delegation to `scripts/ci/shell-benign.sh` — the gate cannot resolve the referenced script (refusing rather than skipping); fix the path, restore the script, or reword the mention",
        ],
    },
    # ------------------------------------------------------------------
    # #399 fold round 2 (closure re-lens N1-N7): the every-word `cd`
    # predicate (N1), the deferred-function refusal (N1c), the
    # `defaults.run.working-directory` model (N2), the indented-scalar
    # capture (N3), the two phrase quote-strip pins (N4), the
    # bash-faithful delegation join pin (N5), the ANSI-C hex assembly
    # (N6) and the order-aware `cd` accept pin (N7). Every reject case
    # pins its exact diagnostic; every case declares the measured base
    # verdict of the pre-#399 gate (`base_exit: 0`).
    # ------------------------------------------------------------------
    {
        "id": "reject-shell-delegation-cd-if",
        "files": ["reject-shell-delegation-cd-if.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-if.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-while",
        "files": ["reject-shell-delegation-cd-while.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-while.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-brace",
        "files": ["reject-shell-delegation-cd-brace.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-brace.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-bang",
        "files": ["reject-shell-delegation-cd-bang.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-bang.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-paren-space",
        "files": ["reject-shell-delegation-cd-paren-space.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-paren-space.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-assignment-prefix",
        "files": ["reject-shell-delegation-cd-assignment-prefix.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-assignment-prefix.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-command",
        "files": ["reject-shell-delegation-cd-command.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-command.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-time",
        "files": ["reject-shell-delegation-cd-time.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-time.yml:8: delegation to `scripts/ci/shell-evil.sh` after a `cd` in the same shell body — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-deferred-function",
        "files": ["reject-shell-delegation-cd-deferred-function.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-deferred-function.yml:10: delegation to `scripts/ci/shell-evil.sh` inside a function body, in a shell body that also contains a `cd` — the gate cannot prove the deferred body's effective cwd (refusing rather than guessing)",
            "reject-shell-delegation-cd-deferred-function.yml:12: delegation to `scripts/ci/shell-evil.sh` inside a function body, in a shell body that also contains a `cd` — the gate cannot prove the deferred body's effective cwd (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-defaults-working-directory",
        "files": ["reject-shell-defaults-working-directory.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-defaults-working-directory.yml:12: delegation to `scripts/ci/shell-evil.sh` under `working-directory: sub` — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
            "reject-shell-defaults-working-directory.yml:16: delegation to `scripts/ci/shell-evil.sh` under `working-directory: sub` — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-working-directory-indented-scalar",
        "files": ["reject-shell-working-directory-indented-scalar.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-working-directory-indented-scalar.yml:10: delegation to `scripts/ci/shell-evil.sh` under `working-directory: sub` — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-defaults-working-directory-indented-scalar",
        "files": ["reject-shell-defaults-working-directory-indented-scalar.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-defaults-working-directory-indented-scalar.yml:13: delegation to `scripts/ci/shell-evil.sh` under `working-directory: sub` — the gate resolves delegations relative to the repository root only (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-cmdsub-quoted-run",
        "files": ["reject-shell-gh-run-download-cmdsub-quoted-run.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-cmdsub-quoted-run.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-backtick-quoted-run",
        "files": ["reject-shell-gh-run-download-backtick-quoted-run.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-backtick-quoted-run.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-continuation",
        "files": ["reject-shell-delegation-continuation.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-continuation.yml:8: delegation to `scripts/ci/evil.sh` — the gate cannot resolve the referenced script (refusing rather than skipping); fix the path, restore the script, or reword the mention",
        ],
    },
    {
        "id": "reject-shell-gh-run-download-ansic-hex-assembly",
        "files": ["reject-shell-gh-run-download-ansic-hex-assembly.yml"],
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-gh-run-download-ansic-hex-assembly.yml:8: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
            "reject-shell-gh-run-download-ansic-hex-assembly.yml:10: shell artifact downloader (`gh run download`) in this `run:` body — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "accept-shell-delegation-cd-after-candidate",
        "files": ["accept-shell-delegation-cd-after-candidate.yml"],
        "extra_files": {"scripts/ci/shell-self-cd.sh": "shell-self-cd.sh"},
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    # ------------------------------------------------------------------
    # #399 fold round 3 (closure re-lens N10-N14): the deferred `trap`
    # action (N10), the substitution-internal `cd` (N11), the ANSI-C
    # delegation path (N12), the sourced-helper `cd` (N13) and the
    # continuation-split function-definition opener (N14). Every reject
    # case pins its exact diagnostic; every case declares `base_exit: 0`
    # (the pre-#399 gate has no shell pass, so all five accepted).
    # ------------------------------------------------------------------
    {
        "id": "reject-shell-delegation-trap-exit",
        "files": ["reject-shell-delegation-trap-exit.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-trap-exit.yml:10: delegation to `scripts/ci/shell-evil.sh` inside a `trap` action whose shell body or action contains a `cd` — the gate cannot prove the trap's effective cwd (refusing rather than guessing)",
            "reject-shell-delegation-trap-exit.yml:13: delegation to `scripts/ci/shell-evil.sh` inside a `trap` action whose shell body or action contains a `cd` — the gate cannot prove the trap's effective cwd (refusing rather than guessing)",
            "reject-shell-delegation-trap-exit.yml:15: delegation to `scripts/ci/shell-evil.sh` inside a `trap` action whose shell body or action contains a `cd` — the gate cannot prove the trap's effective cwd (refusing rather than guessing)",
            "reject-shell-delegation-trap-exit.yml:18: delegation to `scripts/ci/shell-evil.sh` inside a `trap` action whose shell body or action contains a `cd` — the gate cannot prove the trap's effective cwd (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cmdsub-cd",
        "files": ["reject-shell-delegation-cmdsub-cd.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cmdsub-cd.yml:9: delegation to `scripts/ci/shell-evil.sh` inside a command substitution that also contains a `cd` — the substitution's own shell has already changed cwd (refusing rather than guessing)",
            "reject-shell-delegation-cmdsub-cd.yml:11: delegation to `scripts/ci/shell-evil.sh` inside a command substitution that also contains a `cd` — the substitution's own shell has already changed cwd (refusing rather than guessing)",
            "reject-shell-delegation-cmdsub-cd.yml:13: delegation to `scripts/ci/shell-evil.sh` inside a command substitution that also contains a `cd` — the substitution's own shell has already changed cwd (refusing rather than guessing)",
        ],
    },
    {
        "id": "accept-shell-delegation-cmdsub-cd-bare-newline",
        "files": ["accept-shell-delegation-cmdsub-cd-bare-newline.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 0,
        "base_exit": 0,
        "diagnostics": [],
    },
    {
        "id": "reject-shell-delegation-ansic-path",
        "files": ["reject-shell-delegation-ansic-path.yml"],
        "extra_files": {"scripts/ci/shell-evil.sh": "shell-evil.sh"},
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-ansic-path.yml:9: shell artifact downloader (`gh run download`) in `scripts/ci/shell-evil.sh:6` — shell text is refused fail-closed; the gate does not model `run-id:`/`github-token:` handoffs in shell bodies. Keep the download in a `uses: actions/download-artifact` step (or extend the gate)",
        ],
    },
    {
        "id": "reject-shell-delegation-sourced-cd",
        "files": ["reject-shell-delegation-sourced-cd.yml"],
        "extra_files": {
            "scripts/ci/helper.sh": "shell-source-cd.sh",
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-sourced-cd.yml:9: delegation to `scripts/ci/helper.sh` via `.`/`source` of a script whose body contains a `cd` — a sourced script shares this shell's cwd, so the gate cannot prove later delegations' effective cwd (refusing rather than guessing)",
            "reject-shell-delegation-sourced-cd.yml:12: delegation to `scripts/ci/helper.sh` via `.`/`source` of a script whose body contains a `cd` — a sourced script shares this shell's cwd, so the gate cannot prove later delegations' effective cwd (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-sourced-cd-nested",
        "files": ["reject-shell-delegation-sourced-cd-nested.yml"],
        "extra_files": {
            "scripts/ci/helper2.sh": "shell-source-nested.sh",
            "scripts/ci/helper.sh": "shell-source-cd.sh",
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-sourced-cd-nested.yml:9: delegation to `scripts/ci/helper2.sh` via `.`/`source` of a script whose body contains a `cd` — a sourced script shares this shell's cwd, so the gate cannot prove later delegations' effective cwd (refusing rather than guessing)",
        ],
    },
    {
        "id": "reject-shell-delegation-cd-deferred-function-split",
        "files": ["reject-shell-delegation-cd-deferred-function-split.yml"],
        "extra_files": {
            "scripts/ci/shell-evil.sh": "shell-benign.sh",
            "scripts/ci/shell-benign.sh": "shell-benign.sh",
        },
        "exit": 1,
        "base_exit": 0,
        "diagnostics": [
            "reject-shell-delegation-cd-deferred-function-split.yml:9: delegation to `scripts/ci/shell-evil.sh` inside a function body, in a shell body that also contains a `cd` — the gate cannot prove the deferred body's effective cwd (refusing rather than guessing)",
        ],
    },
]
