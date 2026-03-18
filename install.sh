#!/bin/bash
set -Eeuo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_INSTALLER="${SCRIPT_DIR}/cake_soft_panel/install_soft_cake_panel.sh"

# Set INSTALLER_DEFAULT_REPO before publishing the repo if you want
# the raw GitHub one-liner to work without passing GITHUB_REPO/--repo.
INSTALLER_DEFAULT_REPO="${INSTALLER_DEFAULT_REPO:-}"
INSTALLER_DEFAULT_REF="${INSTALLER_DEFAULT_REF:-main}"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_REF="${GITHUB_REF:-$INSTALLER_DEFAULT_REF}"
FORWARD_ARGS=()
TMP_DIR=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Bootstrap options:
  --repo <owner/repo>      GitHub repository to download from
  --ref <git-ref>          Git ref, branch or tag to download (default: main)

Installer options forwarded to cake_soft_panel/install_soft_cake_panel.sh:
  --mode observer|full
  --enable-dns-cache
  --port <port>
  --bind <addr>
  --iface <iface>
  --ifb <ifb>
  --vpn-ports "<ports>"
  --panel-path <path>
  --panel-user <user>
  -h, --help

Environment overrides:
  GITHUB_REPO, GITHUB_REF, PANEL_PORT, PANEL_BIND, CAKE_IFACE, CAKE_IFB, CAKE_VPN_PORTS
EOF
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
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    ubuntu)
      case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *)
          die "unsupported Ubuntu version: ${VERSION_ID:-unknown}; expected 22.04 or 24.04"
          ;;
      esac
      ;;
    debian)
      ;;
    *)
      if [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
        :
      else
        die "unsupported OS: ${PRETTY_NAME:-${ID:-unknown}}"
      fi
      ;;
  esac
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || die "missing value for --repo"
        GITHUB_REPO="$2"
        shift 2
        ;;
      --ref)
        [ "$#" -ge 2 ] || die "missing value for --ref"
        GITHUB_REF="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        FORWARD_ARGS+=("$1")
        if [ "$1" != "--enable-dns-cache" ]; then
          case "$1" in
            --mode|--port|--bind|--iface|--ifb|--vpn-ports|--panel-path|--panel-user)
              [ "$#" -ge 2 ] || die "missing value for $1"
              FORWARD_ARGS+=("$2")
              shift
              ;;
          esac
        fi
        shift
        ;;
    esac
  done
}

run_local_installer() {
  [ -x "$LOCAL_INSTALLER" ] || return 1
  exec bash "$LOCAL_INSTALLER" "${FORWARD_ARGS[@]}"
}

resolve_repo() {
  if [ -n "$GITHUB_REPO" ]; then
    return 0
  fi

  if [ -n "$INSTALLER_DEFAULT_REPO" ]; then
    GITHUB_REPO="$INSTALLER_DEFAULT_REPO"
    return 0
  fi

  die "missing GitHub repo; pass --repo <owner/repo> or set GITHUB_REPO, or bake INSTALLER_DEFAULT_REPO into install.sh before publishing"
}

download_and_run() {
  local archive installer
  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT
  archive="${TMP_DIR}/src.tar.gz"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"

  curl -fsSL "https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}" -o "$archive" || \
    die "failed to download https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}"
  tar -xzf "$archive" -C "$TMP_DIR" || die "failed to unpack repository archive"

  installer="$(find "$TMP_DIR" -path '*/cake_soft_panel/install_soft_cake_panel.sh' -type f | head -n 1)"
  [ -n "$installer" ] || die "install_soft_cake_panel.sh not found in downloaded archive"
  chmod +x "$installer"
  exec bash "$installer" "${FORWARD_ARGS[@]}"
}

main() {
  parse_args "$@"
  need_root
  check_supported_os

  if [ -x "$LOCAL_INSTALLER" ]; then
    run_local_installer
  fi

  resolve_repo
  download_and_run
}

main "$@"
