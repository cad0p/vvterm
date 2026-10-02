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
]
