#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Commit the ghostty probe's rebuilt artifacts to the evergreen bump branch
# and create or update its bump PR with a GitHub-signed (verified) commit.
# Extracted from the `Commit artifacts, push bump branch, create or reuse
# bump PR` step of .github/workflows/ghostty-upstream-probe.yml so the step
# stops spending the GitHub expression-length budget on shell text (issue
# #396, following the #249 extraction pattern). The probe is
# schedule/dispatch-only, so a parse rejection would not show the recorded
# 0-job-run push signature — it would silently stop the weekly bump; the
# step's size pin plus the repo-wide expression budget guard are the
# structural guards and the PR's parity diff covers the move.
#
# Usage: ghostty-bump-pr.sh <owner/repo> <run-url>
#   <owner/repo>  github.repository — the target for every `gh api`/`gh pr`
#   <run-url>     github.server_url + repository + run_id — embedded in the
#                 PR/canary bodies via the ${RUN_URL} placeholder
#
# Environment (inherited from the step's env: block and the runner):
#   GH_TOKEN       app installation token (Contents + Pull requests write)
#   GITHUB_TOKEN   workflow token, used for issue ops (Issues write)
#   PR_BODY, CANARY_BODY  body templates carrying ${...} placeholders
#   RESOLVED_SHA, OLD_VERSION  exported by earlier probe steps via $GITHUB_ENV
#   GITHUB_RUN_ID, GITHUB_OUTPUT, RUNNER_TEMP  set by the runner
#
# Parity contract: everything from `SHA7="${RESOLVED_SHA:0:7}"` to EOF is
# byte-identical to the parsed (de-indented) block scalar of the former step;
# only the two `${{ github.* }}` assignments above it are normalized to
# `REPO="$1"` / `RUN_URL="$2"`. The single `<<JSON` heredoc's body line and
# its `JSON` terminator MUST stay at column 0: an indented body would change
# the payload shape, and a lost or column-shifted terminator would break the
# API call that creates the verified commit.
#
# Non-region deltas versus the former scalar (deliberate, enumerated so the
# no-behavior-change claim stays falsifiable):
#   (a) `shell: bash` on the step changes the invocation from the macOS
#       default `bash -e {0}` to `bash --noprofile --norc -eo pipefail {0}`
#       — it adds `-o pipefail` and suppresses profile/rc, unobservable for
#       this body (no pipeline, and the two non-`pipefail` echoes read only
#       `$RUNNER_TEMP`/expressions);
#   (b) the 2-arg usage check above is a new defensive early-abort surface
#       (`exit 2`), unreachable with the runner's `github.repository` and
#       run-URL arguments;
#   (c) the step's marker + diagnostic now run before the `REPO`/`RUN_URL`
#       bindings (here `$1`/`$2`) that they never read.

set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "::error::usage: ghostty-bump-pr.sh <owner/repo> <run-url>" >&2
  exit 2
fi

REPO="$1"
RUN_URL="$2"

SHA7="${RESOLVED_SHA:0:7}"
BRANCH="chore/ghostty-upstream-bump"

if [[ -z "$GH_TOKEN" ]]; then
  echo "::error::App token is empty — check the GHOSTTY_BUMP_CLIENT_ID variable and GHOSTTY_BUMP_PRIVATE_KEY secret (see scripts/patches/ghostty/README.md)."
  exit 1
fi

# The PR_BODY env scalar carries ${...} placeholders; bash never
# re-expands them, so substitute explicitly.
PR_BODY="${PR_BODY//\$\{SHA7\}/$SHA7}"
PR_BODY="${PR_BODY//\$\{OLD_VERSION\}/$OLD_VERSION}"
PR_BODY="${PR_BODY//\$\{RESOLVED_SHA\}/$RESOLVED_SHA}"
PR_BODY="${PR_BODY//\$\{RUN_URL\}/$RUN_URL}"
CANARY_BODY="${CANARY_BODY//\$\{SHA7\}/$SHA7}"
CANARY_BODY="${CANARY_BODY//\$\{RESOLVED_SHA\}/$RESOLVED_SHA}"
CANARY_BODY="${CANARY_BODY//\$\{RUN_URL\}/$RUN_URL}"

git config user.name "vvterm-ghostty-bump[bot]"
git config user.email "vvterm-ghostty-bump[bot]@users.noreply.github.com"

# Fresh parent for the create path (design NIT 5): the checkout
# step fetched main hours ago and a long probe run can take 1-2h —
# re-fetch keeps the create-path parent fresh.
git fetch -q origin main
MAIN_TIP="$(git rev-parse origin/main)"

# Works whether a local branch of this name exists or not (fresh
# runner per run — none does); the local branch is only a worktree
# for the artifact commit, the server-side ref is the source of
# truth. No local branch is created at all — the worktree stays on
# the checkout's main tip; index-only ops (add/write-tree) below
# don't care, and the ref write happens via the Git API.
# BASE (patch base, read by scripts/build.sh by default) tracks
# the resolved upstream SHA; VERSION was written by build.sh from
# the same SHA. BSD sed on macOS: -i requires the '' extension arg.
sed -i '' "s|.*|${RESOLVED_SHA}|" scripts/patches/ghostty/BASE
git add Vendor/libghostty VVTerm/Resources/terminfo scripts/patches/ghostty/BASE

if git diff --cached --quiet; then
  echo "::notice::No changes to commit (forced rebuild produced identical artifacts) — skipping bump PR."
  exit 0
fi

# --- Discover the evergreen bump state (alarm-invariant ordering) ---
BRANCH_SHA="$(gh api "repos/${REPO}/git/refs/heads/${BRANCH}" --jq '.object.sha' 2>/dev/null || true)"
# Create path: the ref does not exist and gh api 404s — on a
# non-TTY runner the raw error body lands on stdout, so validate
# the shape before trusting it as a parent sha.
[[ "$BRANCH_SHA" =~ ^[0-9a-f]{40}$ ]] || BRANCH_SHA=""
PR_NUMBER=""
for _ in 1 2; do
  PR_JSON="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number,state --jq '.[0] // empty' 2>/dev/null || true)"
  PR_NUMBER="$(jq -r '.number // empty' <<<"$PR_JSON")"
  [[ -n "$PR_NUMBER" ]] && break
  sleep 5
done
if [[ -n "$PR_NUMBER" ]]; then
  # Post-PR ownership: with an evergreen PR, any later failure in
  # this step warns/reds the run but must NEVER file a pre-PR alarm
  # (the open PR + canary issue are the signal).
  echo "probe-passed" > "$RUNNER_TEMP/ghostty-probe-ok"
  echo "Evergreen bump PR #${PR_NUMBER} exists — updating in place."
fi

# --- Verified commit via the Git API ---
# gh-ruleset-main requires verified signatures (required_signatures)
# and checks ALL commits in the PR range. A local `git commit` as
# the app is unsigned → mergeability BLOCKED → auto-merge never
# fires (observed 2026-08-13: PRs #159/#162 stalled, control #160
# with a signed commit auto-merged). POST /git/commits with the
# app token and NO custom author/committer/signature makes GitHub
# sign the commit with its web-flow key and mark it Verified (the
# dependabot mechanism — docs.github.com "Signature verification
# for bots"), satisfying required_signatures.
TREE="$(git write-tree)"
# Update path: parent on the existing evergreen branch head (so the
# new commit fast-forwards it); create path: fresh main tip.
PARENT="${BRANCH_SHA:-$MAIN_TIP}"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
# Upload the tree+blobs server-side (POST /git/commits validates
# the tree exists; pushing a temp commit to a scratch ref is the
# only practical way to upload the xcframework blobs). The scratch
# commit is ALWAYS parented on local HEAD (main tip) — never on
# the evergreen branch head (design FIX-NOW 1): the branch head
# exists only server-side and is NOT a local object on the fresh
# runner checkout, so `git commit-tree -p <branch-head>` dies
# `fatal: <sha> is not a valid object`. The scratch commit is
# only a blob-upload vehicle; its parents are irrelevant — the
# server-side API commit below carries the real parents. The
# scratch ref must be a TAG, not a branch: the scratch commit is
# unsigned (Apps have no local signing key) and gh-ruleset-all
# enforces required_signatures on ALL branches (2026-08-14) —
# branch pushes of it were rejected (alarm issue #173, run
# 32004444535). Tags are outside the branch rulesets' scope, and
# the only push-triggered workflows (ios-testflight,
# sep-webauthn-fixtures) filter to branches: [main], so the tag
# triggers nothing. The `+` force refspec makes a re-run of the
# same workflow run id (re-runs reuse GITHUB_RUN_ID) replace any
# leftover tag instead of erroring; non_fast_forward does not
# apply to tags.
SCRATCH="ci/ghostty-bump-upload-${GITHUB_RUN_ID}"
TMP_COMMIT="$(git commit-tree "$TREE" -p "$MAIN_TIP" -m "scratch upload ${GITHUB_RUN_ID}")"
git push -q origin "+${TMP_COMMIT}:refs/tags/${SCRATCH}"
NEW_COMMIT="$(gh api -X POST "repos/${REPO}/git/commits" --input - <<JSON | jq -r .sha
{"message": "chore: ghostty upstream bump to ${SHA7}", "tree": "${TREE}", "parents": ["${PARENT}"]}
JSON
)"
# Sanity: the API-created commit MUST be verified, else the PR
# would be mergeability-BLOCKED again. Abort on failure (exit 1):
# on the create path no marker exists yet, so the pre-PR alarm
# still fires; on the update path the marker was already written
# at discovery, so the run just reds with no alarm — correct (the
# evergreen PR + canary issue own the outcome).
VERIFIED="$(gh api "repos/${REPO}/commits/${NEW_COMMIT}" --jq '.commit.verification.verified')"
if [[ "$VERIFIED" != "true" ]]; then
  echo "::error::API-created commit ${NEW_COMMIT} is NOT verified (verification=${VERIFIED}) — required_signatures would block the PR. Aborting."
  gh api -X DELETE "repos/${REPO}/git/refs/tags/${SCRATCH}" >/dev/null 2>&1 || true
  exit 1
fi
# Canary issue: a single visible "bump hasn't landed" lead that
# tracks the LATEST in-flight sha and auto-closes when the bump PR
# merges. Closing channel: the PR title carries "(closes #N)" →
# with squash_merge_commit_title=PR_TITLE the title becomes the
# squash commit subject → GitHub commit-message keyword close on
# auto-merge (subject-only doctrine; the PR body stays
# keyword-free). The canary is REUSED while open (title edited to
# the current sha) so at most ONE canary issue exists at a time;
# a weekly "now tracking" comment keeps the trail. Non-fatal: on
# any failure we warn and continue WITHOUT the canary. Issue calls
# must use GITHUB_TOKEN (the app token has Contents+Pull-requests
# only, no Issues permission). The NUMBER is RESOLVED here (needed
# for the PR title) but CREATION + title edit + comments are
# deferred until AFTER the ref write succeeds (design FIX-NOW 3) —
# a pre-ref failure can never leave a canary claiming to track a
# sha that has no bump.
CANARY_TITLE="ghostty bump in-flight: ${SHA7}"
CANARY_ISSUE="$(GH_TOKEN="$GITHUB_TOKEN" gh issue list --repo "$REPO" --state open --search 'in:title "ghostty bump in-flight:"' --json number --jq '.[0].number // empty' 2>/dev/null || true)"
if [[ -n "$CANARY_ISSUE" ]]; then
  echo "Reusing canary issue #${CANARY_ISSUE}"
fi
if [[ -z "$CANARY_ISSUE" ]]; then
  echo "No open canary issue yet — creation deferred to after the ref write."
fi

# Ref write: fast-forward the evergreen branch (non_fast_forward
# permits FF updates under gh-ruleset-all; required_signatures is
# satisfied because the new commit is API-verified and the whole
# range stays verified — no unsigned commits ever exist, so the old
# delete+recreate dance is obsolete). The PR title is only edited
# AFTER this succeeds so a title never claims a sha the branch
# doesn't point at.
if [[ -n "$BRANCH_SHA" ]]; then
  gh api -X PATCH "repos/${REPO}/git/refs/heads/${BRANCH}" -f sha="$NEW_COMMIT" >/dev/null \
    || { echo "::error::Could not fast-forward bump branch ${BRANCH} to ${NEW_COMMIT}."; gh api -X DELETE "repos/${REPO}/git/refs/tags/${SCRATCH}" >/dev/null 2>&1 || true; exit 1; }
else
  gh api -X POST "repos/${REPO}/git/refs" \
    -f ref="refs/heads/${BRANCH}" -f sha="$NEW_COMMIT" >/dev/null
fi
# Scratch tag cleanup is best-effort; a leftover tag is harmless.
gh api -X DELETE "repos/${REPO}/git/refs/tags/${SCRATCH}" >/dev/null 2>&1 || true
echo "Bump branch ${BRANCH} @ ${NEW_COMMIT} (verified, signed by GitHub)"

# Canary mutations, gated on ref success (FIX-NOW 3): CREATION
# (first bump) also happens here — only once the branch actually
# points at the new sha — then the "now tracking" title edit +
# trail comment. Pre-ref failures therefore never leave canary
# state behind. Non-fatal throughout.
if [[ -z "$CANARY_ISSUE" ]]; then
  CANARY_URL="$(GH_TOKEN="$GITHUB_TOKEN" gh issue create --repo "$REPO" --title "$CANARY_TITLE" --body "$CANARY_BODY" 2>/dev/null || true)"
  CANARY_ISSUE="$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$CANARY_URL")"
  [[ -n "$CANARY_ISSUE" ]] && echo "Created canary issue #${CANARY_ISSUE} (${CANARY_TITLE})"
fi
if [[ -n "$CANARY_ISSUE" ]]; then
  GH_TOKEN="$GITHUB_TOKEN" gh issue edit "$CANARY_ISSUE" --repo "$REPO" --title "$CANARY_TITLE" >/dev/null 2>&1 || true
  GH_TOKEN="$GITHUB_TOKEN" gh issue comment "$CANARY_ISSUE" --repo "$REPO" --body "Now tracking ${SHA7} — probe run: ${RUN_URL}" >/dev/null 2>&1 || true
  echo "Canary issue #${CANARY_ISSUE} now tracking ${SHA7}"
else
  echo "::warning::Could not create canary issue (${CANARY_TITLE}) — continuing without it."
fi

# "Never merge an older ghostty core" holds by construction: there
# is exactly ONE evergreen bump branch+PR, always tracking the
# latest build — no other PR can exist to close.

PR_TITLE="chore: ghostty upstream bump to ${SHA7}"
[[ -n "$CANARY_ISSUE" ]] && PR_TITLE="${PR_TITLE} (closes #${CANARY_ISSUE})"

# Update path: the evergreen PR already exists (discovered above).
# The PR discovery + probe-passed marker happened BEFORE the ref
# write, so any failure in this branch warns/reds the run but is
# NOT a pre-PR alarm — the open PR + canary issue own the outcome.
# Shared with the create-fallback below (a transient discovery miss
# must never fall through to a failed create that would file a
# false pre-PR alarm).
update_existing_pr() {
  local n="$1"
  echo "Updating evergreen bump PR #${n} to ${SHA7}"
  # Title keyword is the ONLY canary-close channel — failures here
  # must be LOUD, not swallowed (retry once for transient blips).
  local edited=0
  for _ in 1 2; do
    if gh pr edit "$n" --repo "$REPO" --title "$PR_TITLE" --body "$PR_BODY"; then
      edited=1
      break
    fi
    sleep 5
  done
  if (( edited == 0 )); then
    echo "::warning::Could not edit bump PR #${n} title/body — the closing keyword may be missing on merge; investigate."
  fi
  # Issue comments need Issues write → GITHUB_TOKEN override (the
  # step's app token has Contents+Pull-requests only).
  if [[ -n "$CANARY_ISSUE" ]]; then
    GH_TOKEN="$GITHUB_TOKEN" gh issue comment "$CANARY_ISSUE" --repo "$REPO" --body "Bump PR: https://github.com/${REPO}/pull/${n} (updated to ${SHA7})" >/dev/null 2>&1 || true
  fi
  echo "bump_pr_number=${n}" >> "$GITHUB_OUTPUT"
  # (Re-)enable auto-merge with retries: after the fast-forward
  # GitHub can take a moment to re-evaluate mergeability. Failures
  # are never a probe alarm.
  for _ in 1 2 3; do
    if gh pr merge "$n" --repo "$REPO" --auto --squash 2>/dev/null; then
      echo "Auto-merge (re)enabled on #${n}"
      break
    fi
    sleep 10
  done
  # Marker: the evergreen PR owns the outcome from here on (a no-op
  # on the discovery path where it was already written).
  echo "probe-passed" > "$RUNNER_TEMP/ghostty-probe-ok"
}

if [[ -n "$PR_NUMBER" ]]; then
  update_existing_pr "$PR_NUMBER"
  exit 0
fi

# Create path: first-ever bump — the evergreen branch + PR are born
# here (no PR existed at discovery time).
PR_URL="$(gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" 2>/dev/null || true)"
if [[ -z "$PR_URL" ]]; then
  # Transient discovery miss? Re-discover before alerting — a live
  # evergreen PR plus a failed create must never file a pre-PR
  # alarm.
  RECOVERED="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [[ -n "$RECOVERED" ]]; then
    echo "PR #${RECOVERED} existed after all — switching to update path."
    update_existing_pr "$RECOVERED"
    exit 0
  fi
  echo "::error::gh pr create failed and no evergreen PR was found — pre-PR alarm will fire."
  exit 1
fi
echo "Created bump PR: $PR_URL"
PR_NUMBER="$(sed -E 's#.*/pull/([0-9]+).*#\1#' <<<"$PR_URL")"
# Link the canary to the PR so it is traceable before auto-close.
# Issue comments need Issues write → GITHUB_TOKEN override.
if [[ -n "$CANARY_ISSUE" ]]; then
  GH_TOKEN="$GITHUB_TOKEN" gh issue comment "$CANARY_ISSUE" --repo "$REPO" --body "Bump PR: $PR_URL" >/dev/null 2>&1 || true
fi
echo "bump_pr_number=${PR_NUMBER}" >> "$GITHUB_OUTPUT"
# Marker for the alarm step: ONLY now that the bump PR exists
# (create path). Any failure after this point is NOT a probe alarm
# — the open PR + canary issue own the outcome. A failure BEFORE
# this point — e.g. gh pr create itself — still files the alarm.
echo "probe-passed" > "$RUNNER_TEMP/ghostty-probe-ok"

# Enable auto-merge (squash) with retries. gh-ruleset-main
# requires `build` and `unit-tests`, so auto-merge fires once those
# pass on the new binaries — the UI shards report without gating
# (2026-09-25). If auto-merge cannot be enabled (PR not mergeable
# yet), the evergreen PR stays open; the open canary is the signal
# — never a probe alarm.
AUTO_MERGED=0
for _ in 1 2 3; do
  if gh pr merge "$PR_NUMBER" --repo "$REPO" --auto --squash 2>/dev/null; then
    echo "Auto-merge enabled on bump PR #${PR_NUMBER}"
    AUTO_MERGED=1
    break
  fi
  sleep 10
done
if (( AUTO_MERGED == 0 )); then
  echo "::warning::Could not enable auto-merge on #${PR_NUMBER} (PR may already be merged or not yet mergeable). The evergreen PR stays open; the open canary is the signal — never a probe alarm."
fi
