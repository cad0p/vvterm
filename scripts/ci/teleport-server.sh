#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# teleport-server.sh — boot a REAL Teleport cluster for VVTerm integration
# tests (issue #83, milestone M1).
#
# The iOS simulator cannot reach a Teleport running on a different GitHub
# Actions runner, so the server must run on the SAME macOS runner as the
# tests. This script handles every step:
#
#   install   — download + extract the teleport/tsh/tctl binaries (cached)
#   start     — write an all-in-one config (auth+proxy+node, TLS routing on
#               the web port) and launch `teleport start` in the background
#   bootstrap — create the CI user (tctl users add), complete the invite via
#               the webapi (sets the password non-interactively), mint an SSH
#               cert with `tctl auth sign`, export the cluster TLS CA, and
#               run a tsh login + tsh ssh smoke test
#
# MFA (TELEPORT_SECOND_FACTOR, default off):
#   off — no MFA. `tctl users add` invite completes with just a password.
#   otp — TOTP. bootstrap additionally provisions a server-side TOTP device
#         (POST /v1/webapi/mfa/token/{token}/registerchallenge), decodes the
#         returned QR (scripts/ci/teleport-totp.py + opencv-python-headless)
#         so CI can compute codes, sends the code with the password PUT
#         (`second_factor_token`), and verifies a full password+TOTP login
#         (POST /v1/webapi/sessions/web).
#   webauthn/passwordless — milestone M3 (software WebAuthn key). Bootstrap
#         provisions an MFA credential via registerchallenge + password PUT
#         (`webauthnCreationResponse`), verifies the password+WebAuthn login
#         (mfa/login/begin + finishsession), then runs two smokes with the
#         resulting session: (1) headless-approval — approve a blocking
#         headless SSH cert request with a WebAuthn assertion; (2) passwordless
#         — provision a resident credential (privilege token -> passwordless
#         registerchallenge -> mfa/devices) and log in without a password
#         (login/begin {passwordless:true} + finishsession without a user).
#         Credentials are signed by scripts/ci/teleport-webauthn.py (fido2).
#
# Local user: the Teleport node runs SSH sessions as a LOCAL system user, so
# bootstrap ensures the SSH login exists (`useradd`/`sysadminctl`, falling
# back to the current user) — `ssh ci-user@node` would otherwise fail with
# "unknown user".
#   env-export— write a source-able .env file with the fixture PEMs + server
#               coordinates for the xcodebuild test step
#   status    — is the server up?
#   stop      — terminate the background teleport process
#   clean     — remove the data dir (fresh cluster next start)
#
# Why tctl auth sign instead of the app's headless/Safari flow (M1 scope):
#   `tctl auth sign` mints a user cert server-side — no password, no browser,
#   no WebAuthn. Teleport's own e2e runner does the same thing (seeds users
#   + credentials directly into the cluster state, then signs in over HTTP).
#   The app's SSH path consumes exactly this cert shape: an OpenSSH
#   authorized_keys-format cert (`ssh-ed25519-cert-v01@openssh.com …`) +
#   the OpenSSH PEM ed25519 private key + the cluster TLS CA PEMs (see
#   `SSHSession.authenticate` / `connectTeleportTLS` in SSHClient.swift).
#   M2 (TOTP + headless approval) and M3 (passwordless WebAuthn) build on
#   this same server, later.#
# Ports (all overridable):
#   VVTERM_TELEPORT_WEB_PORT   default 443   — TLS-routing multiplex listener
#                                              (needs root/sudo on CI; use a
#                                              high port for local testing)
#   VVTERM_TELEPORT_AUTH_PORT  default 3025  — auth gRPC listener
#   VVTERM_TELEPORT_SSH_PORT   default 3022  — node SSH listener (internal)
#
# Sudo: when the web port is < 1024 and we are not root, teleport/tctl run
# via `sudo -n` (GitHub macOS runners have passwordless sudo). All fixture
# outputs are written to the work dir (world-readable) so the xcodebuild
# step can read them without root.
#
# Local testing (no sudo): TELEPORT_WEB_PORT=8443 scripts/ci/teleport-server.sh install start bootstrap
#
# See: https://github.com/cad0p/vvterm/issues/83

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (env-overridable)
# ---------------------------------------------------------------------------

TELEPORT_VERSION="${TELEPORT_VERSION:-16.4.0}"   # pinned; darwin+linux both publish this
TELEPORT_HOST="${TELEPORT_HOST:-127.0.0.1}"
TELEPORT_WEB_PORT="${TELEPORT_WEB_PORT:-443}"
TELEPORT_AUTH_PORT="${TELEPORT_AUTH_PORT:-3025}"
TELEPORT_NODE="${TELEPORT_NODE:-ci-node}"
TELEPORT_CLUSTER="${TELEPORT_CLUSTER:-ci-cluster}"
TELEPORT_USER="${TELEPORT_USER:-ci-user}"
TELEPORT_LOGIN="${TELEPORT_LOGIN:-ci-user}"       # SSH login/principal in the cert
# The ceremony-test user (M4): a device-less user the APP registers its
# first MFA device for via Phase 2 gRPC (first-device path — no Safari
# Browser-MFA ceremony). The invite is deliberately left pending: the user
# never logs in with a password (cert auth + passwordless are
# invite-independent), and a completed invite would force an MFA device,
# breaking the first-device path.
TELEPORT_APP_USER="${TELEPORT_APP_USER:-ci-app}"
TELEPORT_SECOND_FACTOR="${TELEPORT_SECOND_FACTOR:-off}"  # off | otp | webauthn
# WebAuthn relying-party ID — must match the clientDataJSON origin host the
# signer emits (lib/auth/webauthn/origin.go: only host==rp_id or subdomains
# are accepted). Defaults to the dial host.
TELEPORT_RP_ID="${TELEPORT_RP_ID:-${TELEPORT_HOST}}"
TELEPORT_PASSWORD="${TELEPORT_PASSWORD:-}"          # random if empty

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/vvterm-teleport}"
BIN_DIR="${WORK_DIR}/bin"
DATA_DIR="${WORK_DIR}/data"
FIXTURES_DIR="${WORK_DIR}/fixtures"
CONF_FILE="${WORK_DIR}/teleport.yaml"
PID_FILE="${WORK_DIR}/teleport.pid"
LOG_FILE="${WORK_DIR}/teleport.log"
ENV_FILE="${WORK_DIR}/vvterm-teleport.env"

# Resolve OS/ARCH for the download URL (darwin/linux × arm64/amd64).
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "${UNAME_S}" in
  Darwin)  TELEPORT_OS="darwin" ;;
  Linux)   TELEPORT_OS="linux" ;;
  *)       echo "error: unsupported OS ${UNAME_S}" >&2; exit 1 ;;
esac
case "${UNAME_M}" in
  arm64|aarch64) TELEPORT_ARCH="arm64" ;;
  x86_64|amd64)  TELEPORT_ARCH="amd64" ;;
  *)             echo "error: unsupported arch ${UNAME_M}" >&2; exit 1 ;;
esac

if [ -z "${TELEPORT_PASSWORD}" ]; then
  TELEPORT_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '+/=' | cut -c1-16)"
fi

# Sudo prefix for root-only operations (binding a privileged web port,
# tctl access to the root-owned auth data dir on macOS runners). Populate
# whenever passwordless sudo exists — macOS ships bash 3.2, where expanding
# an EMPTY array under `set -u` is an unbound-variable error, and the 8443
# smoke legs must not trip it. Fail hard only when a privileged port
# actually requires root and none is available.
SUDO_PREFIX=()
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO_PREFIX=(sudo -n)
  elif [ "${TELEPORT_WEB_PORT}" -lt 1024 ]; then
    echo "error: web port ${TELEPORT_WEB_PORT} requires root (no passwordless sudo)" >&2
    exit 1
  fi
fi

log() { echo "[teleport-server] $*"; }

# macOS ships no GNU `timeout`; emulate it (background + bounded sleep).
# Only used where a hung child would otherwise wedge the bootstrap.
if ! command -v timeout >/dev/null 2>&1; then
  timeout() {
    local seconds="$1"
    shift
    local pid rc killer
    "$@" &
    pid=$!
    ( sleep "${seconds}"; kill "${pid}" 2>/dev/null ) &
    killer=$!
    wait "${pid}" 2>/dev/null || rc=$?
    kill "${killer}" 2>/dev/null || true
    wait "${killer}" 2>/dev/null || true
    return "${rc:-0}"
  }
fi

# ---------------------------------------------------------------------------
# install — fetch + extract the binaries (idempotent)
# ---------------------------------------------------------------------------
cmd_install() {
  if [ -x "${BIN_DIR}/teleport" ]; then
    log "binaries already present (${BIN_DIR}/teleport)"
    return
  fi
  mkdir -p "${BIN_DIR}"
  local url="https://cdn.teleport.dev/teleport-v${TELEPORT_VERSION}-${TELEPORT_OS}-${TELEPORT_ARCH}-bin.tar.gz"
  local tarball="${WORK_DIR}/teleport.tar.gz"
  log "downloading ${url}"
  curl -fsSL -o "${tarball}" "${url}"
  tar -xzf "${tarball}" -C "${BIN_DIR}" --strip-components=1
  log "installed: $("${BIN_DIR}/teleport" version)"
}

# ---------------------------------------------------------------------------
# config — write the all-in-one teleport.yaml (auth + proxy + node)
# ---------------------------------------------------------------------------
write_config() {
  mkdir -p "${DATA_DIR}" "${FIXTURES_DIR}"
  cat > "${CONF_FILE}" <<EOF
#
# VVTerm CI Teleport (generated by scripts/ci/teleport-server.sh)
#
version: v3
teleport:
  nodename: ${TELEPORT_NODE}
  data_dir: ${DATA_DIR}
  # The default 'lite' (SQLite) backend serializes writes behind a single
  # lock; on CI runners its periodic pruning/rotation transactions stall
  # every other operation for seconds (observed: 37s cert auth + audit
  # events never flushing). 'dir' (bbolt) has no such contention.
  storage:
    type: dir
  log:
    output: stderr
    severity: INFO
auth_service:
  enabled: "yes"
  listen_addr: 0.0.0.0:${TELEPORT_AUTH_PORT}
  cluster_name: ${TELEPORT_CLUSTER}
  proxy_listener_mode: multiplex
  authentication:
    # M1: no MFA (off). M2: TOTP (otp) — bootstrap registers a server-side
    # TOTP device and completes the invite with its code. M3 adds
    # webauthn/passwordless.
    second_factor: ${TELEPORT_SECOND_FACTOR}
    local_auth: "yes"
EOF
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    cat >> "${CONF_FILE}" <<EOF2
    webauthn:
      # Software-signer ceremony origin is https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT};
      # rp_id must equal the origin HOST (or be a parent domain of it).
      rp_id: ${TELEPORT_RP_ID}
EOF2
  fi
  cat >> "${CONF_FILE}" <<EOF3
ssh_service:
  enabled: "yes"
  listen_addr: 0.0.0.0:3022
  labels:
    env: ci
proxy_service:
  enabled: "yes"
  listen_addr: 0.0.0.0:3023
  # The TLS-routing multiplex listener: SSH (ALPN teleport-proxy-ssh),
  # web, and gRPC auth all share this port (RFD 39 / Teleport >= 13).
  web_listen_addr: 0.0.0.0:${TELEPORT_WEB_PORT}
  tunnel_listen_addr: 0.0.0.0:3024
  public_addr: ${TELEPORT_HOST}:${TELEPORT_WEB_PORT}
  https_keypairs: []
  acme: {}
EOF3
  log "wrote ${CONF_FILE}"
}

# ---------------------------------------------------------------------------
# start — launch teleport in the background and wait for readiness
# ---------------------------------------------------------------------------
cmd_start() {
  if cmd_status >/dev/null 2>&1; then
    log "teleport already running (pid $(cat "${PID_FILE}"))"
    return
  fi
  if [ ! -x "${BIN_DIR}/teleport" ]; then
    cmd_install
  fi
  write_config
  log "starting teleport (web :${TELEPORT_WEB_PORT}, cluster ${TELEPORT_CLUSTER}, node ${TELEPORT_NODE})"
  # TELEPORT_ALLOW_NO_SECOND_FACTOR: v16 guards `second_factor: off` at cluster
  # init (modules.ErrCannotDisableSecondFactor) unless this dev/test escape
  # hatch is set — see lib/auth/init.go initializeAuthPreference. CI only.
  ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} env TELEPORT_ALLOW_NO_SECOND_FACTOR=yes \
    nohup "${BIN_DIR}/teleport" start -c "${CONF_FILE}" > "${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  # Wait for the auth service to come up (poll tctl status).
  local deadline=$((SECONDS + 90))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if cmd_status >/dev/null 2>&1; then
      log "teleport is up: $(${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} "${BIN_DIR}/tctl" -c "${CONF_FILE}" status 2>/dev/null | head -1)"
      return
    fi
    sleep 2
  done
  echo "error: teleport did not become ready in 90s (see ${LOG_FILE})" >&2
  tail -40 "${LOG_FILE}" >&2 || true
  exit 1
}

# ---------------------------------------------------------------------------
# bootstrap — create user, set password via invite webapi, mint cert, smoke
# ---------------------------------------------------------------------------
ensure_local_login_user() {
  # The Teleport node (regular mode) runs the SSH session as a LOCAL system
  # user — `ssh ci-user@node` fails with "unknown user" when the login has no
  # matching local account. CI runners don't ship a `ci-user` account, so
  # create one when possible (sudo is available on GH runners); fall back to
  # the current user, which exists by definition.
  if id "${TELEPORT_LOGIN}" >/dev/null 2>&1; then
    return
  fi
  local prefix=()
  if [ "$(id -u)" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
      log "cannot create local user ${TELEPORT_LOGIN} (no sudo) — falling back to $(id -un)"
      TELEPORT_LOGIN="$(id -un)"
      return
    fi
    prefix=(sudo -n)
  fi
  if command -v useradd >/dev/null 2>&1; then
    "${prefix[@]}" useradd -m -s /bin/bash "${TELEPORT_LOGIN}" 2>/dev/null || true
  fi
  if command -v sysadminctl >/dev/null 2>&1; then
    "${prefix[@]}" sysadminctl -addUser "${TELEPORT_LOGIN}" -shell /bin/zsh 2>/dev/null || true
  fi
  if ! id "${TELEPORT_LOGIN}" >/dev/null 2>&1; then
    log "could not create local user ${TELEPORT_LOGIN} — falling back to $(id -un)"
    TELEPORT_LOGIN="$(id -un)"
  fi
}

cmd_bootstrap() {
  ensure_local_login_user
  local tctl=(${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} "${BIN_DIR}/tctl" -c "${CONF_FILE}")

  # 1. Create the user (inactive) + parse the invite token from the output.
  log "creating user ${TELEPORT_USER} (roles: access,editor; logins: ${TELEPORT_LOGIN})"
  local users_out
  users_out="$("${tctl[@]}" users add --roles=access,editor --logins="${TELEPORT_LOGIN}" "${TELEPORT_USER}" 2>&1)"
  local token
  token="$(printf '%s\n' "${users_out}" | sed -n 's/.*Invite token: *\([^ ]*\).*/\1/p' | head -1)"
  if [ -z "${token}" ]; then
    # Fallback: some versions print only the invite URL.
    token="$(printf '%s\n' "${users_out}" | grep -oE 'invite/[A-Za-z0-9_-]+' | head -1 | cut -d/ -f2)"
  fi
  if [ -z "${token}" ]; then
    echo "error: could not parse invite token from tctl users add output:" >&2
    printf '%s\n' "${users_out}" >&2
    exit 1
  fi
  log "invite token parsed (${#token} chars)"

  # 2. Complete the invite over the webapi — sets the password
  #    non-interactively (this is what the web UI's invite page does).
  #    Modern Teleport has no /webapi/invite POST; the flow is:
  #      a. GET /web/… to obtain the __Host-grv_csrf double-submit cookie
  #      b. PUT /v1/webapi/users/password/token with the invite token in
  #         the body, the password as base64(utf8), and X-CSRF-Token
  #         (lib/web/apiserver.go changeUserAuthentication + WithCSRFProtection)
  #    -k: self-signed cert.
  log "completing invite (setting password) via PUT /v1/webapi/users/password/token"
  local cookie_jar="${WORK_DIR}/cookies.txt"
  curl -ksS -c "${cookie_jar}" -o /dev/null "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/web/invite/${token}"
  local csrf
  csrf="$(awk '$6 == "__Host-grv_csrf" {print $7}' "${cookie_jar}" | head -1)"
  if [ -z "${csrf}" ]; then
    echo "error: no CSRF cookie from /web/invite page" >&2
    cat "${cookie_jar}" >&2
    exit 1
  fi

  # M2: for an `otp` cluster, provision a TOTP device bound to the invite
  # token BEFORE the password PUT. Teleport generates the secret server-side
  # and returns it only as a QR (image/png otpauth:// URI); CI decodes it
  # with scripts/ci/teleport-totp.py so it can compute the codes the PUT
  # (second_factor_token) and later logins require.
  # M3: for a `webauthn` cluster, provision a SOFTWARE WebAuthn credential
  # bound to the invite token (scripts/ci/teleport-webauthn.py — fido2). The
  # registerchallenge options come back as
  # {"webauthn":{"publicKey":{...}}} (attestation "none", which the CI
  # cluster accepts by default); the password PUT then carries the signed
  # creation response instead of a TOTP code. The same credential signs the
  # later login/headless assertions.
  local second_factor_arg=""
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    log "provisioning software WebAuthn device (POST /v1/webapi/mfa/token/{token}/registerchallenge)"
    curl -ksS -b "${cookie_jar}" -X POST \
      "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/token/${token}/registerchallenge" \
      -H "X-CSRF-Token: ${csrf}" \
      -H 'Content-Type: application/json' \
      -d '{"deviceType":"webauthn"}' \
      -o "${FIXTURES_DIR}/webauthn-register-options.json"
    if [ ! -s "${FIXTURES_DIR}/webauthn-register-options.json" ]; then
      echo "error: registerchallenge returned no response" >&2
      exit 1
    fi
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" register \
      --options "${FIXTURES_DIR}/webauthn-register-options.json" \
      --out "${FIXTURES_DIR}/webauthn-register-response.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${WORK_DIR}/webauthn-state"
    log "software WebAuthn credential provisioned"
    second_factor_arg=",\"webauthnCreationResponse\":$(cat "${FIXTURES_DIR}/webauthn-register-response.json")"
  elif [ "${TELEPORT_SECOND_FACTOR}" = "otp" ]; then
    log "provisioning TOTP device (POST /v1/webapi/mfa/token/{token}/registerchallenge)"
    curl -ksS -b "${cookie_jar}" -X POST \
      "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/token/${token}/registerchallenge" \
      -H "X-CSRF-Token: ${csrf}" \
      -H 'Content-Type: application/json' \
      -d '{"deviceType":"totp"}' \
      -o "${FIXTURES_DIR}/totp-qr.json"
    if [ ! -s "${FIXTURES_DIR}/totp-qr.json" ]; then
      echo "error: registerchallenge returned no response" >&2
      exit 1
    fi
    # v16 returns JSON {"webauthn":null,"totp":{"qrCode":"<base64 PNG>"}};
    # teleport-totp.py handles both that envelope and a raw PNG.
    TOTP_SECRET="$(python3 "${SCRIPT_DIR}/teleport-totp.py" qr-secret "${FIXTURES_DIR}/totp-qr.json")"
    log "TOTP device provisioned (secret ${#TOTP_SECRET} chars base32)"
    # The password step requires a fresh valid code from the registered device.
    second_factor_arg=",\"second_factor_token\":\"$(python3 "${SCRIPT_DIR}/teleport-totp.py" code "${TOTP_SECRET}")\""
  fi

  local invite_resp
  invite_resp="$(
    curl -ksS -b "${cookie_jar}" -X PUT \
      "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/users/password/token" \
      -H "X-CSRF-Token: ${csrf}" \
      -H 'Content-Type: application/json' \
      -d "{\"token\":\"${token}\",\"password\":\"$(printf '%s' "${TELEPORT_PASSWORD}" | base64)\",\"deviceName\":\"ci\"${second_factor_arg}}"
  )"
  if ! printf '%s' "${invite_resp}" | grep -q '"kind"\|"session"\|"recovery"\|^{}$'; then
    echo "error: invite completion failed:" >&2
    printf '%s\n' "${invite_resp}" >&2
    exit 1
  fi

  # M2: verify the full password+TOTP chain through the webapi — the same
  # CSRF double-submit + cookie machinery the app's login flows use.
  # Two gotchas: the password PUT rotates the CSRF cookie (re-fetch it), and
  # Teleport treats TOTP codes as single-use (the PUT consumed the code from
  # its 30s window, so the login in the same window is rejected with
  # "invalid credentials" — retry once after the window rolls, ≤30s).
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    # M3: verify the full password+WebAuthn chain. NOTE: POST
    # /v1/webapi/sessions/web REJECTS webauthn clusters ("unknown second
    # factor type", lib/web/apiserver.go createWebSession) — the web UI's
    # flow is mfa/login/begin -> mfa/login/finishsession, which sets the
    # __Host-session cookie used by the headless approval below.
    log "verifying webauthn login (POST /v1/webapi/mfa/login/begin + finishsession)"
    curl -ksS -c "${cookie_jar}" -o /dev/null "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/web/login"
    local csrf2
    csrf2="$(awk '$6 == "__Host-grv_csrf" {print $7}' "${cookie_jar}" | head -1)"
    local begin_resp
    begin_resp="$(
      curl -ksS -b "${cookie_jar}" -c "${cookie_jar}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/login/begin" \
        -H "X-CSRF-Token: ${csrf2}" \
        -H 'Content-Type: application/json' \
        -d "{\"passwordless\":false,\"user\":\"${TELEPORT_USER}\",\"pass\":\"${TELEPORT_PASSWORD}\"}"
    )"
    if ! printf '%s' "${begin_resp}" | grep -q 'webauthn_challenge'; then
      echo "error: webauthn login/begin failed:" >&2
      printf '%s\n' "${begin_resp}" >&2
      exit 1
    fi
    printf '%s' "${begin_resp}" > "${FIXTURES_DIR}/webauthn-login-options.json"
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" assert \
      --options "${FIXTURES_DIR}/webauthn-login-options.json" \
      --out "${FIXTURES_DIR}/webauthn-login-assertion.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${WORK_DIR}/webauthn-state" \
      --no-user-handle
    local finish_resp
    finish_resp="$(
      curl -ksS -b "${cookie_jar}" -c "${cookie_jar}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/login/finishsession" \
        -H "X-CSRF-Token: ${csrf2}" \
        -H 'Content-Type: application/json' \
        -d "{\"user\":\"${TELEPORT_USER}\",\"webauthnAssertionResponse\":$(cat "${FIXTURES_DIR}/webauthn-login-assertion.json")}"
    )"
    if ! printf '%s' "${finish_resp}" | grep -q '"token"'; then
      echo "error: webauthn login/finishsession failed:" >&2
      printf '%s\n' "${finish_resp}" >&2
      exit 1
    fi
    local bearer
    bearer="$(printf '%s' "${finish_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
    # The session cookie + bearer token are the approver identity for the
    # headless approval smoke below.
    printf '%s' "${bearer}" > "${WORK_DIR}/approver-bearer.txt"
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${bearer}" \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/sites" | grep -q '\"name\"'; then
      echo "error: webauthn session not usable (GET /v1/webapi/sites)" >&2
      exit 1
    fi
    log "webauthn login verified (session + bearer)"
  elif [ "${TELEPORT_SECOND_FACTOR}" = "otp" ]; then
    log "verifying otp login (POST /v1/webapi/sessions/web)"
    curl -ksS -c "${cookie_jar}" -o /dev/null "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/web/login"
    local csrf2
    csrf2="$(awk '$6 == "__Host-grv_csrf" {print $7}' "${cookie_jar}" | head -1)"
    local login_resp=""
    local attempt
    for attempt in 1 2; do
      login_resp="$(
        curl -ksS -b "${cookie_jar}" -c "${cookie_jar}" -X POST \
          "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/sessions/web" \
          -H "X-CSRF-Token: ${csrf2}" \
          -H 'Content-Type: application/json' \
          -d "{\"user\":\"${TELEPORT_USER}\",\"pass\":\"${TELEPORT_PASSWORD}\",\"second_factor_token\":\"$(python3 "${SCRIPT_DIR}/teleport-totp.py" code "${TOTP_SECRET}")\"}"
      )"
      if printf '%s' "${login_resp}" | grep -q '"token"\|"session"'; then
        break
      fi
      if [ "${attempt}" -lt 2 ]; then
        log "login rejected (code consumed by password step?) — waiting for next TOTP window"
        sleep "$((30 - ($(date +%s) % 30) + 1))"
      fi
    done
    if ! printf '%s' "${login_resp}" | grep -q '"token"\|"session"'; then
      echo "error: otp login verification failed:" >&2
      printf '%s\n' "${login_resp}" >&2
      exit 1
    fi
    log "otp login verified"
  fi

  # 3. Mint the SSH cert + key for the app's SSH path.
  #    --format=openssh writes exactly what SSHSession.authenticate needs:
  #      <out>          — private key (PEM; libssh2_userauth_publickey_frommemory)
  #      <out>-cert.pub — the cert in authorized_keys format
  #                       (`ssh-rsa-cert-v01@openssh.com AAAA…`), passed as
  #                       publicKeyData. No passphrase (Teleport certs).
  log "signing SSH cert for ${TELEPORT_USER} (tctl auth sign)"
  local identity_prefix="${FIXTURES_DIR}/identity"
  rm -f "${identity_prefix}"* "${identity_prefix}-cert.pub"
  "${tctl[@]}" auth sign --user="${TELEPORT_USER}" --format=openssh --out="${identity_prefix}" >/dev/null
  local cert_file="${identity_prefix}-cert.pub"
  local key_file="${identity_prefix}"
  if [ ! -s "${cert_file}" ] || [ ! -s "${key_file}" ]; then
    echo "error: tctl auth sign did not produce cert/key" >&2
    ls -la "${FIXTURES_DIR}" >&2
    exit 1
  fi

  # tctl runs as root on macOS runners (passwordless sudo), so its output
  # files land root-owned 0600. Hand the fixtures to the runner user or
  # every read below fails with EACCES (Linux/no-sudo: no-op).
  ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} chown -R "$(id -un):$(id -gn)" "${FIXTURES_DIR}"

  log "cert: $(head -c 40 "${cert_file}")…"

  # 4. Export the cluster TLS CA (PEM bundle) — the SSH path uses these as
  #    NWProtocolTLS trust anchors (see connectTeleportTLS).
  "${tctl[@]}" auth export --type=tls-host > "${FIXTURES_DIR}/tls-ca.pem"
  log "tls-ca: $(grep -c 'BEGIN CERTIFICATE' "${FIXTURES_DIR}/tls-ca.pem") cert(s) exported"

  # 4b. M4: the app-ceremony identity (webauthn clusters only). The app's
  #     Phase-2 gRPC registration needs a user with NO MFA devices
  #     (first-device path — no Safari Browser-MFA ceremony;
  #     CreateAuthenticateChallenge returns an empty challenge for a
  #     device-less user) and a TLS cert identity for the mTLS auth dial.
  #     `tctl auth sign --format=tls` mints exactly the identity shape
  #     Phase 1 would produce:
  #       app-identity.crt  — the signed TLS certificate (client cert)
  #       app-identity.key  — the private key (RSA PKCS1 PEM)
  #       app-identity.cas  — the cluster CA bundle (PEMs)
  #     The invite is deliberately left pending (see TELEPORT_APP_USER
  #     above): the user never logs in with a password (cert auth +
  #     passwordless are invite-independent), and a completed invite would
  #     force an MFA device, breaking the first-device path.
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    log "minting app-ceremony identity (${TELEPORT_APP_USER}, TLS identity)"
    "${tctl[@]}" users add "${TELEPORT_APP_USER}" --roles=access --logins="${TELEPORT_LOGIN}" >/dev/null
    rm -f "${FIXTURES_DIR}/app-identity"*
    "${tctl[@]}" auth sign --user="${TELEPORT_APP_USER}" --format=tls --out="${FIXTURES_DIR}/app-identity" >/dev/null
    for f in "${FIXTURES_DIR}/app-identity.crt" "${FIXTURES_DIR}/app-identity.key" "${FIXTURES_DIR}/app-identity.cas"; do
      if [ ! -s "$f" ]; then
        echo "error: tctl auth sign --format=tls did not produce $f" >&2
        ls -la "${FIXTURES_DIR}" >&2
        exit 1
      fi
    done
    # tctl runs as root on macOS runners (passwordless sudo) — hand the
    # fixtures to the runner user before reading them (Linux/no-sudo: no-op).
    ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} chown -R "$(id -un):$(id -gn)" "${FIXTURES_DIR}"
    APP_IDENTITY_CRT="$(cat "${FIXTURES_DIR}/app-identity.crt")"
    APP_IDENTITY_KEY="$(cat "${FIXTURES_DIR}/app-identity.key")"
    APP_IDENTITY_CAS="$(cat "${FIXTURES_DIR}/app-identity.cas")"
    log "app-ceremony identity minted (crt/key/cas)"
  else
    APP_IDENTITY_CRT=""
    APP_IDENTITY_KEY=""
    APP_IDENTITY_CAS=""
  fi

  # 5. Write the source-able env file for the xcodebuild test step.
  write_env_file

  # 6. Smoke: an SSH round trip through the TLS-routing proxy using the
  #    signed identity (`tsh login` refuses non-TTY password input, so the
  #    identity-file route — `tsh -i` + `--proxy` — is the CI-safe path).
  log "tsh smoke (ssh ${TELEPORT_LOGIN}@${TELEPORT_NODE} via :${TELEPORT_WEB_PORT})"
  local identity_file="${WORK_DIR}/smoke-identity"
  rm -f "${identity_file}"
  "${tctl[@]}" auth sign --user="${TELEPORT_USER}" --out="${identity_file}" >/dev/null
  # Same root-owned handover as step 4 (macOS runners).
  ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} chown "$(id -un):$(id -gn)" "${identity_file}"
  local tsh_home="${WORK_DIR}/tsh-home"
  mkdir -p "${tsh_home}"
  local smoke
  smoke="$(
    HOME="${tsh_home}" timeout 60 "${BIN_DIR}/tsh" --insecure \
      -i "${identity_file}" --proxy="${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" ssh \
      -o StrictHostKeyChecking=no "${TELEPORT_LOGIN}@${TELEPORT_NODE}" 'echo TELEPORT_E2E_OK'
  )"
  if ! printf '%s' "${smoke}" | grep -q 'TELEPORT_E2E_OK'; then
    echo "error: tsh ssh smoke failed — output:" >&2
    printf '%s\n' "${smoke}" >&2
    exit 1
  fi
  log "smoke passed: ${smoke}"

  # 7. M3: headless-approval smoke (webauthn clusters only). This is the
  #    CI-able version of the app's Phase-1 ceremony: a client requests a
  #    cert via the blocking headless login, and an already-logged-in
  #    approver approves it with a WebAuthn assertion signed by the same
  #    software credential. The approval is REQUIRED to be WebAuthn
  #    (lib/auth/auth_with_roles.go UpdateHeadlessAuthenticationState —
  #    scope CHALLENGE_SCOPE_HEADLESS_LOGIN=3), so this only runs when the
  #    cluster has webauthn enabled.
  #
  #    Sequence (verified against v16.4.0):
  #      a. POST /v1/webapi/ssh/certs with headless_id + pub_key — BLOCKS
  #         until approved (run in background). NOTE: v16 routes headless
  #         login under ssh/certs with a `headless_id`; the app's
  #         /webapi/headless/login path is v17+.
  #      b. GET /v1/webapi/headless/{id} (approver session) — upserts the
  #         stub that lets the login process insert the real resource.
  #      c. POST /v1/webapi/mfa/authenticatechallenge
  #         {"challenge_scope": 3} (headless login scope).
  #      d. Sign the assertion + PUT /v1/webapi/headless/{id}
  #         {"action":"accept","webauthnAssertionResponse":{...}}.
  #      e. The background POST returns the signed SSH cert.
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    log "headless-approval smoke (software WebAuthn approver)"
    if [ ! -s "${WORK_DIR}/approver-bearer.txt" ]; then
      echo "error: headless smoke needs the webauthn approver session (login step must run first)" >&2
      exit 1
    fi
    local hl_key="${WORK_DIR}/hl-key"
    rm -f "${hl_key}" "${hl_key}.pub"
    ssh-keygen -t ed25519 -f "${hl_key}" -N "" -q
    local hl_id
    hl_id="$(python3 "${SCRIPT_DIR}/teleport-webauthn.py" headless-id --pubkey "${hl_key}.pub")"
    log "headless id: ${hl_id}"
    local hl_pub_b64
    hl_pub_b64="$(base64 < "${hl_key}.pub" | tr -d '\n')"
    local hl_bearer
    hl_bearer="$(cat "${WORK_DIR}/approver-bearer.txt")"
    # a. Blocking client request in the background.
    curl -ksS -X POST \
      "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/ssh/certs" \
      -H 'Content-Type: application/json' \
      -d "{\"user\":\"${TELEPORT_USER}\",\"headless_id\":\"${hl_id}\",\"pub_key\":\"${hl_pub_b64}\",\"ttl\":1800000000000,\"compatibility\":\"\"}" \
      -o "${FIXTURES_DIR}/headless-cert.json" -w '%{http_code}' > "${WORK_DIR}/headless-http.txt" 2>&1 &
    local hl_curl_pid=$!
    # b. Approver GET — creates the stub / waits for the resource.
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${hl_bearer}" \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/headless/${hl_id}" \
        -o "${WORK_DIR}/headless-get.json" -w '%{http_code}' | grep -q '200'; then
      kill "${hl_curl_pid}" 2>/dev/null || true
      echo "error: headless GET (stub) failed:" >&2
      cat "${WORK_DIR}/headless-get.json" >&2
      exit 1
    fi
    # c. Authenticate challenge, headless-login scope.
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${hl_bearer}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/authenticatechallenge" \
        -H 'Content-Type: application/json' \
        -d '{"challenge_scope": 3, "challenge_allow_reuse": false}' \
        -o "${FIXTURES_DIR}/webauthn-headless-options.json" -w '%{http_code}' | grep -q '200'; then
      kill "${hl_curl_pid}" 2>/dev/null || true
      echo "error: headless authenticatechallenge failed:" >&2
      cat "${FIXTURES_DIR}/webauthn-headless-options.json" >&2
      exit 1
    fi
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" assert \
      --options "${FIXTURES_DIR}/webauthn-headless-options.json" \
      --out "${FIXTURES_DIR}/webauthn-headless-assertion.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${WORK_DIR}/webauthn-state" \
      --no-user-handle
    # d. Approve.
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${hl_bearer}" -X PUT \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/headless/${hl_id}" \
        -H 'Content-Type: application/json' \
        -d "{\"action\":\"accept\",\"webauthnAssertionResponse\":$(cat "${FIXTURES_DIR}/webauthn-headless-assertion.json")}" \
        -w '%{http_code}' -o "${WORK_DIR}/headless-put.json" | grep -q '200'; then
      kill "${hl_curl_pid}" 2>/dev/null || true
      echo "error: headless approval PUT failed:" >&2
      cat "${WORK_DIR}/headless-put.json" >&2
      exit 1
    fi
    # e. Wait for the blocking client POST to complete with a signed cert.
    local hl_wait=0
    while kill -0 "${hl_curl_pid}" 2>/dev/null && [ "${hl_wait}" -lt 20 ]; do
      sleep 1
      hl_wait=$((hl_wait + 1))
    done
    if kill -0 "${hl_curl_pid}" 2>/dev/null; then
      kill "${hl_curl_pid}" 2>/dev/null || true
      echo "error: headless client POST did not complete after approval" >&2
      exit 1
    fi
    if ! grep -q '200' "${WORK_DIR}/headless-http.txt" \
       || ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("cert") else 1)' "${FIXTURES_DIR}/headless-cert.json"; then
      echo "error: headless login did not issue a cert:" >&2
      cat "${FIXTURES_DIR}/headless-cert.json" >&2
      exit 1
    fi
    log "headless-approval smoke passed (cert issued)"
  fi

  # 8. M3: passwordless smoke (webauthn clusters only). This is the CI-able
  #    version of the app's Phase-3 passwordless login: the already-logged-in
  #    approver provisions a resident credential (privilege token -> passwordless
  #    registerchallenge -> mfa/devices) and then logs in WITHOUT a password
  #    (login/begin passwordless -> finishsession). Verified against v16.4.0:
  #
  #    a. POST /v1/webapi/mfa/authenticatechallenge
  #       {"challenge_scope": 4} (MANAGE_DEVICES) — the web UI's
  #       createPrivilegeTokenWithWebauthn uses this exact scope.
  #    b. POST /v1/webapi/users/privilege/token
  #       {"webauthnAssertionResponse": ...} — NOTE the field name is
  #       webauthnAssertionResponse (users.go privilegeTokenRequest), not
  #       webauthnResponse.
  #    c. POST /v1/webapi/mfa/token/{privilege_token}/registerchallenge
  #       {"deviceType":"webauthn","deviceUsage":"passwordless"} — the
  #       challenge demands userVerification "required" and a resident key.
  #    d. POST /v1/webapi/mfa/devices with the registration response
  #       {"tokenId","deviceName","deviceUsage":"passwordless",
  #        "webauthnRegisterResponse"}.
  #    e. POST /v1/webapi/mfa/login/begin {"passwordless": true} -> assert
  #       (UV flag + userHandle echo) -> finishsession WITHOUT a "user" field
  #       (sending it switches the server to LOGIN scope and the challenge
  #       lookup fails; the web UI omits it exactly this way).
  if [ "${TELEPORT_SECOND_FACTOR}" = "webauthn" ]; then
    log "passwordless smoke (resident credential + passwordless login)"
    if [ ! -s "${WORK_DIR}/approver-bearer.txt" ]; then
      echo "error: passwordless smoke needs the webauthn approver session" >&2
      exit 1
    fi
    local pl_bearer
    pl_bearer="$(cat "${WORK_DIR}/approver-bearer.txt")"
    # a. Manage-devices authenticate challenge.
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${pl_bearer}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/authenticatechallenge" \
        -H 'Content-Type: application/json' \
        -d '{"challenge_scope": 4, "challenge_allow_reuse": false}' \
        -o "${FIXTURES_DIR}/webauthn-pt-options.json" -w '%{http_code}' | grep -q '200'; then
      echo "error: passwordless privilege challenge failed:" >&2
      cat "${FIXTURES_DIR}/webauthn-pt-options.json" >&2
      exit 1
    fi
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" assert \
      --options "${FIXTURES_DIR}/webauthn-pt-options.json" \
      --out "${FIXTURES_DIR}/webauthn-pt-assertion.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${WORK_DIR}/webauthn-state" \
      --no-user-handle
    # b. Privilege token (field name webauthnAssertionResponse).
    local pt_token
    pt_token="$(
      curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${pl_bearer}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/users/privilege/token" \
        -H 'Content-Type: application/json' \
        -d "{\"webauthnAssertionResponse\":$(cat "${FIXTURES_DIR}/webauthn-pt-assertion.json")}"
    )"
    if ! printf '%s' "${pt_token}" | grep -qE '^"[a-f0-9]{32}"$'; then
      echo "error: privilege token request failed:" >&2
      printf '%s\n' "${pt_token}" >&2
      exit 1
    fi
    local pt_id
    pt_id="$(printf '%s' "${pt_token}" | tr -d '"')"
    # c. Passwordless register challenge (token-scoped).
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${pl_bearer}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/token/${pt_id}/registerchallenge" \
        -H 'Content-Type: application/json' \
        -d '{"deviceType":"webauthn","deviceUsage":"passwordless"}' \
        -o "${FIXTURES_DIR}/webauthn-pl-register-options.json" -w '%{http_code}' | grep -q '200'; then
      echo "error: passwordless registerchallenge failed:" >&2
      cat "${FIXTURES_DIR}/webauthn-pl-register-options.json" >&2
      exit 1
    fi
    if ! grep -q '"userVerification":"required"' "${FIXTURES_DIR}/webauthn-pl-register-options.json"; then
      echo "error: passwordless challenge must demand user verification:" >&2
      cat "${FIXTURES_DIR}/webauthn-pl-register-options.json" >&2
      exit 1
    fi
    local pl_state="${WORK_DIR}/webauthn-passwordless-state"
    rm -rf "${pl_state}"
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" register \
      --options "${FIXTURES_DIR}/webauthn-pl-register-options.json" \
      --out "${FIXTURES_DIR}/webauthn-pl-register-response.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${pl_state}"
    # d. Register the resident device.
    if ! curl -ksS -b "${cookie_jar}" -H "Authorization: Bearer ${pl_bearer}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/devices" \
        -H 'Content-Type: application/json' \
        -d "{\"tokenId\":\"${pt_id}\",\"deviceName\":\"ci-passwordless\",\"deviceUsage\":\"passwordless\",\"webauthnRegisterResponse\":$(cat "${FIXTURES_DIR}/webauthn-pl-register-response.json")}" \
        -o "${WORK_DIR}/pl-add-device.json" -w '%{http_code}' | grep -q '200'; then
      echo "error: passwordless device registration failed:" >&2
      cat "${WORK_DIR}/pl-add-device.json" >&2
      exit 1
    fi
    # e. Passwordless login: begin -> assert -> finishsession (NO user field).
    local pl_cookie="${WORK_DIR}/pl-cookies.txt"
    rm -f "${pl_cookie}"
    curl -ksS -c "${pl_cookie}" -o /dev/null "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/web/login"
    local pl_csrf
    pl_csrf="$(awk '$6 == "__Host-grv_csrf" {print $7}' "${pl_cookie}" | head -1)"
    if ! curl -ksS -b "${pl_cookie}" -c "${pl_cookie}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/login/begin" \
        -H "X-CSRF-Token: ${pl_csrf}" \
        -H 'Content-Type: application/json' \
        -d '{"passwordless": true}' \
        -o "${FIXTURES_DIR}/webauthn-pl-login-options.json" -w '%{http_code}' | grep -q '200'; then
      echo "error: passwordless login/begin failed:" >&2
      cat "${FIXTURES_DIR}/webauthn-pl-login-options.json" >&2
      exit 1
    fi
    python3 "${SCRIPT_DIR}/teleport-webauthn.py" assert \
      --options "${FIXTURES_DIR}/webauthn-pl-login-options.json" \
      --out "${FIXTURES_DIR}/webauthn-pl-login-assertion.json" \
      --origin "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" \
      --state "${pl_state}"
    local pl_finish
    pl_finish="$(
      curl -ksS -b "${pl_cookie}" -c "${pl_cookie}" -X POST \
        "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/mfa/login/finishsession" \
        -H "X-CSRF-Token: ${pl_csrf}" \
        -H 'Content-Type: application/json' \
        -d "{\"webauthnAssertionResponse\":$(cat "${FIXTURES_DIR}/webauthn-pl-login-assertion.json")}"
    )"
    if ! printf '%s' "${pl_finish}" | grep -q '"token"'; then
      echo "error: passwordless login/finishsession failed:" >&2
      printf '%s\n' "${pl_finish}" >&2
      exit 1
    fi
    log "passwordless smoke passed (resident credential + passwordless login)"
  fi
}

# ---------------------------------------------------------------------------
# env-export — source-able fixture env (PEM contents + server coordinates)
# ---------------------------------------------------------------------------
write_env_file() {
  cat > "${ENV_FILE}" <<EOF
# VVTerm Teleport integration-test fixtures (generated by teleport-server.sh)
VVTERM_TELEPORT_CERT="$(cat "${FIXTURES_DIR}/identity-cert.pub")"
VVTERM_TELEPORT_KEY="$(cat "${FIXTURES_DIR}/identity")"
VVTERM_TELEPORT_CA_CERTS="$(cat "${FIXTURES_DIR}/tls-ca.pem")"
VVTERM_TELEPORT_CLUSTER_NAME="${TELEPORT_CLUSTER}"
VVTERM_TELEPORT_HOST="${TELEPORT_HOST}"
VVTERM_TELEPORT_PORT="${TELEPORT_WEB_PORT}"
VVTERM_TELEPORT_NODE="${TELEPORT_NODE}"
VVTERM_TELEPORT_USER="${TELEPORT_USER}"
# The SSH login the app must present — must be a principal in the cert.
VVTERM_TELEPORT_LOGIN="${TELEPORT_LOGIN}"
# MFA mode the cluster was booted with (off | otp). TOTP secret is the
# base32 shared secret of the CI-registered device (empty when off).
VVTERM_TELEPORT_SECOND_FACTOR="${TELEPORT_SECOND_FACTOR}"
VVTERM_TELEPORT_TOTP_SECRET="${TOTP_SECRET:-}"
# M4 ceremony-test identity (webauthn clusters only — empty otherwise):
# a device-less user + the TLS identity the app's Phase-2 gRPC dial uses
# (tctl auth sign --format=tls: crt = client cert, key = private key
# [RSA PKCS1 PEM], cas = cluster CA bundle). The app's Phase-2
# registration registers this user's first (passwordless) MFA device.
VVTERM_TELEPORT_APP_USER="${TELEPORT_APP_USER:-}"
VVTERM_TELEPORT_APP_TLS_CERT="${APP_IDENTITY_CRT:-}"
VVTERM_TELEPORT_APP_TLS_KEY="${APP_IDENTITY_KEY:-}"
VVTERM_TELEPORT_APP_TLS_CAS="${APP_IDENTITY_CAS:-}"
EOF
  log "wrote ${ENV_FILE}"
}

cmd_env_export() {
  if [ ! -f "${ENV_FILE}" ]; then
    echo "error: ${ENV_FILE} missing — run bootstrap first" >&2
    exit 1
  fi
  cat "${ENV_FILE}"
}

# ---------------------------------------------------------------------------
# status / stop / clean
# ---------------------------------------------------------------------------
cmd_status() {
  if [ ! -f "${PID_FILE}" ]; then
    echo "not running (no pid file)" >&2
    return 1
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "not running (pid ${pid} dead)" >&2
    return 1
  fi
  if ! ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} "${BIN_DIR}/tctl" -c "${CONF_FILE}" status >/dev/null 2>&1; then
    echo "pid ${pid} alive but auth not ready" >&2
    return 1
  fi
  echo "running (pid ${pid})"
}

cmd_stop() {
  if [ ! -f "${PID_FILE}" ]; then
    log "not running"
    return
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  log "stopping teleport (pid ${pid})"
  ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} kill "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  kill -0 "${pid}" 2>/dev/null && ${SUDO_PREFIX[@]+"${SUDO_PREFIX[@]}"} kill -9 "${pid}" 2>/dev/null || true
  rm -f "${PID_FILE}"
}

cmd_clean() {
  cmd_stop
  rm -rf "${DATA_DIR}"
  log "data dir removed — next start creates a fresh cluster"
}

cmd_probe() {
  # Test-time server health probe: a tsh exec through the proxy + node,
  # run minutes AFTER the bootstrap smoke. The off-leg outer-handshake
  # stalls happen between bootstrap and the app tests (backend contention
  # window) — this probe attributes them decisively: a failing probe means
  # the server can't complete an SSH exec at test time (server-side), a
  # passing probe means the app side stalled (app-side).
  local identity_file="${WORK_DIR}/smoke-identity"
  if [ ! -s "${identity_file}" ]; then
    echo "error: probe needs bootstrap first (smoke-identity missing)" >&2
    exit 1
  fi
  local tsh_home="${WORK_DIR}/tsh-home"
  mkdir -p "${tsh_home}"
  local out
  out="$(
    HOME="${tsh_home}" timeout 60 "${BIN_DIR}/tsh" --insecure \
      -i "${identity_file}" --proxy="${TELEPORT_HOST}:${TELEPORT_WEB_PORT}" ssh \
      -o StrictHostKeyChecking=no "${TELEPORT_LOGIN}@${TELEPORT_NODE}" 'echo TELEPORT_PROBE_OK'
  )" || {
    echo "error: test-time tsh probe FAILED (server-side stall?) — output:" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  }
  if ! printf '%s' "${out}" | grep -q 'TELEPORT_PROBE_OK'; then
    echo "error: probe output missing TELEPORT_PROBE_OK — output:" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
  log "probe passed: $(printf '%s' "${out}" | tail -1)"
}

# ---------------------------------------------------------------------------
cmd="${1:-help}"
shift || true
case "${cmd}" in
  install)  cmd_install ;;
  start)    cmd_start ;;
  bootstrap) cmd_bootstrap ;;
  env-export) cmd_env_export ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  clean)    cmd_clean ;;
  probe)    cmd_probe ;;
  help|-h|--help)
    sed -n '2,40p' "$0" | grep -E '^#   ' | sed 's/^#   //' ;;
  *)
    echo "error: unknown command ${cmd}" >&2
    echo "commands: install start bootstrap env-export status stop clean probe" >&2
    exit 1 ;;
esac
