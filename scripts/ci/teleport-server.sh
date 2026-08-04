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
#   this same server, later.
#
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
TELEPORT_PASSWORD="${TELEPORT_PASSWORD:-}"          # random if empty

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

# Sudo prefix when the web port needs root and we don't have it.
SUDO_PREFIX=()
if [ "${TELEPORT_WEB_PORT}" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO_PREFIX=(sudo -n)
  else
    echo "error: web port ${TELEPORT_WEB_PORT} requires root (no passwordless sudo)" >&2
    exit 1
  fi
fi

log() { echo "[teleport-server] $*"; }

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
  log:
    output: stderr
    severity: INFO
auth_service:
  enabled: "yes"
  listen_addr: 0.0.0.0:${TELEPORT_AUTH_PORT}
  cluster_name: ${TELEPORT_CLUSTER}
  proxy_listener_mode: multiplex
  authentication:
    # M1: no MFA. M2 adds TOTP (otp), M3 adds webauthn/passwordless.
    second_factor: off
    local_auth: "yes"
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
EOF
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
  "${SUDO_PREFIX[@]}" env TELEPORT_ALLOW_NO_SECOND_FACTOR=yes \
    nohup "${BIN_DIR}/teleport" start -c "${CONF_FILE}" > "${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  # Wait for the auth service to come up (poll tctl status).
  local deadline=$((SECONDS + 90))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if cmd_status >/dev/null 2>&1; then
      log "teleport is up: $("${SUDO_PREFIX[@]}" "${BIN_DIR}/tctl" -c "${CONF_FILE}" status 2>/dev/null | head -1)"
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
cmd_bootstrap() {
  local tctl=("${SUDO_PREFIX[@]}" "${BIN_DIR}/tctl" -c "${CONF_FILE}")

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
  local invite_resp
  invite_resp="$(
    curl -ksS -b "${cookie_jar}" -X PUT \
      "https://${TELEPORT_HOST}:${TELEPORT_WEB_PORT}/v1/webapi/users/password/token" \
      -H "X-CSRF-Token: ${csrf}" \
      -H 'Content-Type: application/json' \
      -d "{\"token\":\"${token}\",\"password\":\"$(printf '%s' "${TELEPORT_PASSWORD}" | base64)\",\"deviceName\":\"ci\"}"
  )"
  if ! printf '%s' "${invite_resp}" | grep -q '"kind"\|"session"\|"recovery"\|^{}$'; then
    echo "error: invite completion failed:" >&2
    printf '%s\n' "${invite_resp}" >&2
    exit 1
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
  log "cert: $(head -c 40 "${cert_file}")…"

  # 4. Export the cluster TLS CA (PEM bundle) — the SSH path uses these as
  #    NWProtocolTLS trust anchors (see connectTeleportTLS).
  "${tctl[@]}" auth export --type=tls-host > "${FIXTURES_DIR}/tls-ca.pem"
  log "tls-ca: $(grep -c 'BEGIN CERTIFICATE' "${FIXTURES_DIR}/tls-ca.pem") cert(s) exported"

  # 5. Write the source-able env file for the xcodebuild test step.
  write_env_file

  # 6. Smoke: an SSH round trip through the TLS-routing proxy using the
  #    signed identity (`tsh login` refuses non-TTY password input, so the
  #    identity-file route — `tsh -i` + `--proxy` — is the CI-safe path).
  log "tsh smoke (ssh ${TELEPORT_LOGIN}@${TELEPORT_NODE} via :${TELEPORT_WEB_PORT})"
  local identity_file="${WORK_DIR}/smoke-identity"
  rm -f "${identity_file}"
  "${tctl[@]}" auth sign --user="${TELEPORT_USER}" --out="${identity_file}" >/dev/null
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
  if ! "${SUDO_PREFIX[@]}" "${BIN_DIR}/tctl" -c "${CONF_FILE}" status >/dev/null 2>&1; then
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
  "${SUDO_PREFIX[@]}" kill "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  kill -0 "${pid}" 2>/dev/null && "${SUDO_PREFIX[@]}" kill -9 "${pid}" 2>/dev/null || true
  rm -f "${PID_FILE}"
}

cmd_clean() {
  cmd_stop
  rm -rf "${DATA_DIR}"
  log "data dir removed — next start creates a fresh cluster"
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
  help|-h|--help)
    sed -n '2,40p' "$0" | grep -E '^#   ' | sed 's/^#   //' ;;
  *)
    echo "error: unknown command ${cmd}" >&2
    echo "commands: install start bootstrap env-export status stop clean" >&2
    exit 1 ;;
esac
