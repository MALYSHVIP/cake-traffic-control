#!/bin/bash
set -Eeuo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_INSTALLER="${SCRIPT_DIR}/.codex_panel_refactor/scripts/install_panel.sh"

# Default public GitHub repository for curl|bash installs.
INSTALLER_DEFAULT_REPO="${INSTALLER_DEFAULT_REPO:-MALYSHVIP/cake-traffic-control}"
INSTALLER_DEFAULT_REF="${INSTALLER_DEFAULT_REF:-main}"

INPUT_GITHUB_REPO="${GITHUB_REPO-}"
INPUT_GITHUB_REF="${GITHUB_REF-}"
INPUT_INSTALLER_SHA256="${INSTALLER_SHA256-}"

GITHUB_REPO="${INPUT_GITHUB_REPO:-}"
GITHUB_REF="${INPUT_GITHUB_REF:-$INSTALLER_DEFAULT_REF}"
INSTALLER_SHA256="${INPUT_INSTALLER_SHA256:-}"
FORWARD_ARGS=()
TMP_DIR=""
FORCE_REMOTE=0

if [ -n "$INPUT_GITHUB_REPO" ] || [ -n "$INPUT_GITHUB_REF" ] || [ -n "$INPUT_INSTALLER_SHA256" ]; then
  FORCE_REMOTE=1
fi

usage() {
  cat <<'EOF'
Usage:
  install.sh [bootstrap options] [-- installer options]
  install.sh [installer options]

Bootstrap options:
  --repo <owner/repo>      Download installer from a specific GitHub repository
  --ref <git-ref>          Git ref, branch or tag to download (default: main)
  --sha256 <sha256>        Verify downloaded archive checksum before install
  --                       Explicitly separate bootstrap args from installer args

Package installer options:
  --mode observer|full
  --port <port>
  --bind <addr>
  --iface <iface>
  --ifb <ifb>
  --vpn-ports "<ports>"
  --panel-path <path>
  --panel-user <user>
  -h, --help

Environment overrides:
  GITHUB_REPO, GITHUB_REF, INSTALLER_SHA256,
  PANEL_PORT, PANEL_BIND, CAKE_IFACE, CAKE_IFB, CAKE_VPN_PORTS

Behavior:
  If the script is run from a local checkout and no GitHub override is passed,
  it executes ./.codex_panel_refactor/scripts/install_panel.sh directly.
  If --repo, --ref, --sha256 or the matching env vars are provided,
  it downloads the repository archive from GitHub and runs the installer from it.

Security note:
  For Internet-facing hosts, prefer --bind 127.0.0.1 and place the panel
  behind a reverse proxy, VPN access, or an IP allowlist.

Examples:
  sudo bash ./install.sh
  curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | \
    sudo bash -s -- --mode full --iface eth0 --vpn-ports "443"
  curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | \
    sudo GITHUB_REPO=<owner>/<repo> GITHUB_REF=<branch-or-tag> bash -s -- --mode observer
EOF
}

log() {
  echo "[install] $*"
}

die() {
  echo "[install] $*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root"
  fi
}

check_supported_os() {
  [ -r /etc/os-release ] || die "missing /etc/os-release"
  case "$(uname -s)" in
    Linux) ;;
    *) die "unsupported kernel: $(uname -s)" ;;
  esac
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

validate_repo() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "invalid GitHub repo format: $1"
}

validate_sha256() {
  [ -z "$1" ] && return 0
  [[ "$1" =~ ^[A-Fa-f0-9]{64}$ ]] || die "invalid sha256: expected 64 hex chars"
}

is_commit_ref() {
  [[ "$1" =~ ^[A-Fa-f0-9]{7,40}$ ]]
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || die "missing value for --repo"
        GITHUB_REPO="$2"
        FORCE_REMOTE=1
        shift 2
        ;;
      --ref)
        [ "$#" -ge 2 ] || die "missing value for --ref"
        GITHUB_REF="$2"
        FORCE_REMOTE=1
        shift 2
        ;;
      --sha256)
        [ "$#" -ge 2 ] || die "missing value for --sha256"
        INSTALLER_SHA256="$2"
        FORCE_REMOTE=1
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          FORWARD_ARGS+=("$1")
          shift
        done
        break
        ;;
      *)
        FORWARD_ARGS+=("$1")
        case "$1" in
          --mode|--port|--bind|--iface|--ifb|--vpn-ports|--panel-path|--panel-user)
            [ "$#" -ge 2 ] || die "missing value for $1"
            FORWARD_ARGS+=("$2")
            shift
            ;;
        esac
        shift
        ;;
    esac
  done

  validate_sha256 "$INSTALLER_SHA256"
}

run_local_installer() {
  [ -x "$LOCAL_INSTALLER" ] || return 1
  log "source=local-checkout installer=${LOCAL_INSTALLER}"
  bash "$LOCAL_INSTALLER" "${FORWARD_ARGS[@]}"
}

resolve_repo() {
  if [ -n "$GITHUB_REPO" ]; then
    validate_repo "$GITHUB_REPO"
    return 0
  fi

  if [ -n "$INSTALLER_DEFAULT_REPO" ]; then
    GITHUB_REPO="$INSTALLER_DEFAULT_REPO"
    validate_repo "$GITHUB_REPO"
    return 0
  fi

  die "missing GitHub repo; pass --repo <owner/repo>, set GITHUB_REPO, or set INSTALLER_DEFAULT_REPO before publishing install.sh"
}

verify_archive_checksum() {
  [ -n "$INSTALLER_SHA256" ] || return 0
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$1" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  else
    die "neither sha256sum nor shasum is available for checksum verification"
  fi

  if [ "${actual,,}" != "${INSTALLER_SHA256,,}" ]; then
    die "archive sha256 mismatch: expected ${INSTALLER_SHA256}, got ${actual}"
  fi
}

verify_pinned_commit_dir() {
  local topdir base suffix repo_name
  is_commit_ref "$GITHUB_REF" || return 0

  repo_name="${GITHUB_REPO##*/}"
  topdir="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$topdir" ] || die "downloaded archive is missing a top-level directory"

  base="$(basename "$topdir")"
  suffix="${base#${repo_name}-}"
  case "${suffix,,}" in
    ${GITHUB_REF,,}*)
      log "pinned commit ref detected: ${GITHUB_REF}"
      ;;
    *)
      die "downloaded archive root (${base}) does not match pinned commit ref ${GITHUB_REF}"
      ;;
  esac
}

download_and_run() {
  local archive installer
  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT
  archive="${TMP_DIR}/src.tar.gz"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"

  log "source=github-archive repo=${GITHUB_REPO} ref=${GITHUB_REF}"
  curl --retry 3 --retry-delay 1 --connect-timeout 10 -fsSL "https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}" -o "$archive" || \
    die "failed to download https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}"
  verify_archive_checksum "$archive"
  tar -xzf "$archive" -C "$TMP_DIR" || die "failed to unpack repository archive"
  verify_pinned_commit_dir

  installer="$(find "$TMP_DIR" -path '*/.codex_panel_refactor/scripts/install_panel.sh' -type f | head -n 1)"
  [ -n "$installer" ] || die "install_panel.sh not found in downloaded archive"
  chmod +x "$installer"
  bash "$installer" "${FORWARD_ARGS[@]}"
}

main() {
  parse_args "$@"
  need_root
  check_supported_os

  if [ "$FORCE_REMOTE" -eq 0 ] && [ -x "$LOCAL_INSTALLER" ]; then
    run_local_installer
    return 0
  fi

  resolve_repo
  download_and_run
}

main "$@"
