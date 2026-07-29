#!/usr/bin/env bash
# create-adhoc-profiles.sh — create Apple ad-hoc provisioning profiles for
# per-PR OTA distribution, via the asc CLI (App Store Connect API).
#
# Reusable across apps: everything app-specific is a flag.
#
# What it does (idempotent):
#   1. Ensures each --device-udid is registered in App Store Connect
#      (registers when missing, reuses when present).
#   2. For each --profile "bundle_id:Profile Name:SECRET_NAME" triple:
#      deletes any existing profile with the same name, creates a fresh
#      IOS_APP_ADHOC profile bound to the bundle id + distribution
#      certificate + the device set, and downloads the .mobileprovision.
#      (Recreate-on-run is deliberate: ASC profiles are immutable w.r.t.
#      devices/certs via the API, so "add a device" = re-run this script.)
#   3. With --set-secrets, base64-encodes each profile and pushes it to the
#      given GitHub repo secret via gh.
#
# Certificate selection: pass --certificate-id explicitly (recommended —
# find it with `asc certificates list`), or omit to auto-select when the
# account has exactly one IOS_DISTRIBUTION/DISTRIBUTION certificate. The
# cert MUST be the one whose p12 the CI signing workflow holds (for VVTerm:
# the same cert the TestFlight App Store profile links to — check with
# `asc profiles links certificates --id <appstore-profile-id>`).
#
# Auth: uses the local asc profile (see `asc auth status`), or env
# credentials (ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH) like the
# TestFlight CI does.
#
# Prereqs: asc (App Store Connect CLI), python3; gh when --set-secrets.
#
# Example (VVTerm):
#   ./scripts/create-adhoc-profiles.sh \
#     --certificate-id T5P4KKH2A6 \
#     --device-udid 00008101-0011353A00E1401E \
#     --profile "it.pcad.vvterm:VVTerm AdHoc OTA:IOS_ADHOC_PROFILE_B64" \
#     --profile "it.pcad.vvterm.liveactivity:VVTerm LiveActivity AdHoc OTA:IOS_LIVE_ACTIVITY_ADHOC_PROFILE_B64" \
#     --repo cad0p/vvterm --set-secrets
#
# Related: .github/workflows/ios-adhoc-pr.yml (consumer), pcad.it-infra #154.

set -euo pipefail

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
error(){ printf '[ERROR] %s\n' "$*" >&2; }
die()  { error "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# base64 single-line, portable (GNU wraps at 76 cols by default, BSD doesn't).
b64() { base64 -w0 "$1" 2>/dev/null || base64 "$1"; }

# asc JSON → parsed with python3 (jq is not universally installed).
jqv() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

CERTIFICATE_ID=""
DEVICE_UDIDS=()
DEVICE_NAME="OTA device"
ALL_DEVICES=0
PROFILE_SPECS=()
REPO=""
SET_SECRETS=0
OUT_DIR=""

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --certificate-id) CERTIFICATE_ID="$2"; shift 2 ;;
    --device-udid)    DEVICE_UDIDS+=("$2"); shift 2 ;;
    --device-name)    DEVICE_NAME="$2"; shift 2 ;;
    --all-devices)    ALL_DEVICES=1; shift ;;
    --profile)        PROFILE_SPECS+=("$2"); shift 2 ;;
    --repo)           REPO="$2"; shift 2 ;;
    --set-secrets)    SET_SECRETS=1; shift ;;
    --out-dir)        OUT_DIR="$2"; shift 2 ;;
    -h|--help)        usage 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ ${#PROFILE_SPECS[@]} -gt 0 ]] || die "At least one --profile \"bundle_id:Name:SECRET_NAME\" is required"
[[ ${#DEVICE_UDIDS[@]} -gt 0 || $ALL_DEVICES -eq 1 ]] || die "Pass --device-udid (repeatable) or --all-devices"
if [[ $SET_SECRETS -eq 1 && -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  [[ -n "$REPO" ]] || die "--set-secrets needs --repo owner/name (or run inside a gh-enabled repo)"
fi

require_cmd asc
require_cmd python3
[[ $SET_SECRETS -eq 1 ]] && require_cmd gh

OUT_DIR="${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/adhoc-profiles.XXXXXX")}"
mkdir -p "$OUT_DIR"
log "Output directory: $OUT_DIR"

asc auth status >/dev/null 2>&1 || die "asc is not authenticated (see: asc auth status)"

# --- 1. Devices --------------------------------------------------------------

log "Fetching registered devices..."
devices_json="$(asc devices list --paginate --output json)"

DEVICE_IDS=()
if [[ $ALL_DEVICES -eq 1 ]]; then
  while IFS=$'\t' read -r id udid; do
    [[ -n "$id" ]] || continue
    DEVICE_IDS+=("$id")
    log "Including device: $udid ($id)"
  done < <(printf '%s' "$devices_json" | jqv "
for x in d.get('data', []):
    a = x['attributes']
    if a.get('platform') == 'IOS' and a.get('status') == 'ENABLED':
        print(x['id'] + '\t' + a.get('udid', '?'))
")
fi

for udid in "${DEVICE_UDIDS[@]+"${DEVICE_UDIDS[@]}"}"; do
  [[ -n "$udid" ]] || continue
  existing="$(printf '%s' "$devices_json" | jqv "
for x in d.get('data', []):
    if x['attributes'].get('udid', '').upper() == '${udid}'.upper():
        print(x['id'])
        break
")"
  if [[ -n "$existing" ]]; then
    log "Device $udid already registered ($existing)"
    DEVICE_IDS+=("$existing")
  else
    log "Registering device $udid as \"$DEVICE_NAME\"..."
    reg_json="$(asc devices register --name "$DEVICE_NAME" --udid "$udid" --platform IOS --output json)"
    new_id="$(printf '%s' "$reg_json" | jqv "print(d['data']['id'])")"
    log "Registered device $udid ($new_id)"
    DEVICE_IDS+=("$new_id")
  fi
done

# De-duplicate device IDs.
DEVICE_IDS=($(printf '%s\n' "${DEVICE_IDS[@]}" | sort -u))
DEVICE_CSV="$(IFS=,; printf '%s' "${DEVICE_IDS[*]}")"
log "Device set (${#DEVICE_IDS[@]}): $DEVICE_CSV"

# --- 2. Certificate ----------------------------------------------------------

if [[ -z "$CERTIFICATE_ID" ]]; then
  log "No --certificate-id given; looking for a single distribution certificate..."
  certs_json="$(asc certificates list --paginate --output json)"
  mapfile -t dist_certs < <(printf '%s' "$certs_json" | jqv "
for c in d.get('data', []):
    if c['attributes'].get('certificateType') in ('IOS_DISTRIBUTION', 'DISTRIBUTION'):
        print(c['id'])
")
  if [[ ${#dist_certs[@]} -eq 1 ]]; then
    CERTIFICATE_ID="${dist_certs[0]}"
    log "Auto-selected certificate: $CERTIFICATE_ID"
  else
    printf '%s' "$certs_json" | jqv "
for c in d.get('data', []):
    a = c['attributes']
    print(c['id'], a.get('certificateType'), a.get('expirationDate', '')[:10], a.get('serialNumber', ''))
" >&2
    die "Multiple distribution certificates — re-run with --certificate-id <id> (list above). Must match the p12 your CI holds."
  fi
fi
log "Using certificate: $CERTIFICATE_ID"

# --- 3. Profiles -------------------------------------------------------------

profiles_json="$(asc profiles list --paginate --output json)"

for spec in "${PROFILE_SPECS[@]}"; do
  IFS=':' read -r bundle_id profile_name secret_name <<< "$spec"
  [[ -n "$bundle_id" && -n "$profile_name" && -n "$secret_name" ]] \
    || die "Malformed --profile spec (want bundle_id:Name:SECRET_NAME): $spec"

  # Delete existing profile(s) with this name (immutable → recreate).
  while IFS= read -r old_id; do
    [[ -n "$old_id" ]] || continue
    log "Deleting existing profile \"$profile_name\" ($old_id) for recreate..."
    asc profiles delete --id "$old_id" --confirm >/dev/null
  done < <(printf '%s' "$profiles_json" | jqv "
for p in d.get('data', []):
    if p['attributes'].get('name') == '''${profile_name}''':
        print(p['id'])
")

  # --bundle expects the App ID RESOURCE id (e.g. VW84CU9FF9), not the
  # reverse-DNS identifier — resolve it.
  bundle_resource="$(asc bundle-ids list --paginate --output json | jqv "
for b in d.get('data', []):
    if b['attributes'].get('identifier') == '${bundle_id}':
        print(b['id'])
        break
")"
  [[ -n "$bundle_resource" ]] || die "Bundle id '$bundle_id' not found in App Store Connect"

  log "Creating ad-hoc profile \"$profile_name\" for $bundle_id ($bundle_resource)..."
  create_json="$(asc profiles create \
    --name "$profile_name" \
    --profile-type IOS_APP_ADHOC \
    --bundle "$bundle_resource" \
    --certificate "$CERTIFICATE_ID" \
    --device "$DEVICE_CSV" \
    --output json)"
  profile_id="$(printf '%s' "$create_json" | jqv "print(d['data']['id'])")"
  log "Created profile $profile_id"

  out_file="$OUT_DIR/${bundle_id}.adhoc.mobileprovision"
  asc profiles download --id "$profile_id" --output "$out_file" >/dev/null
  log "Downloaded: $out_file"

  if [[ $SET_SECRETS -eq 1 ]]; then
    log "Setting secret $secret_name on $REPO..."
    gh secret set "$secret_name" --repo "$REPO" --body "$(b64 "$out_file")"
  fi
done

log "Done."
if [[ $SET_SECRETS -eq 0 ]]; then
  cat >&2 <<EOF
[INFO] Profiles are in $OUT_DIR — upload manually with:
[INFO]   gh secret set <SECRET_NAME> -R <owner/repo> -b "\$(base64 -w0 <file> 2>/dev/null || base64 <file>)"
EOF
fi
