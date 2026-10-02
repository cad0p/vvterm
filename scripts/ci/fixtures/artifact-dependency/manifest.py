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
]
