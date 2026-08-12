#!/usr/bin/env bash
# Shared helpers for the cyberdeck peripheral setup scripts.
# Sourced by each <peripheral>/setup.sh — not meant to be executed directly.

set -euo pipefail

# The login user, even though this script runs as root.
#
# `sudo` exports SUDO_USER; `pkexec` does not, it exports PKEXEC_UID instead.
# Getting this wrong is not harmless: falling back to `id -un` under pkexec would
# add *root* to the dialout/video groups and leave the real user without access.
_resolve_target_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    printf '%s\n' "$SUDO_USER"
  elif [[ -n "${PKEXEC_UID:-}" ]]; then
    getent passwd "$PKEXEC_UID" | cut -d: -f1
  else
    id -un
  fi
}
# Respect an explicit override, e.g. `TARGET_USER=boris sudo -E bash setup.sh`.
TARGET_USER="${TARGET_USER:-$(_resolve_target_user)}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script needs root. Run: sudo bash $0" >&2
    exit 1
  fi
}

# apt-get update, but at most once per invocation of the top-level setup.
apt_refresh() {
  if [[ -z "${_APT_REFRESHED:-}" ]]; then
    say "Refreshing package lists"
    apt-get update
    _APT_REFRESHED=1
  fi
}

apt_install() {
  apt_refresh
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Add TARGET_USER to a group, if that group exists on this system.
add_user_to_group() {
  local grp="$1"
  if [[ "$TARGET_USER" == "root" ]]; then
    warn "refusing to add 'root' to '$grp' — could not determine the real user."
    warn "Re-run with sudo, or set TARGET_USER=<you> in the environment."
    return
  fi
  if getent group "$grp" >/dev/null; then
    usermod -aG "$grp" "$TARGET_USER"
    info "added $TARGET_USER to '$grp'"
  else
    warn "group '$grp' does not exist on this system, skipping"
  fi
}
