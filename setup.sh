#!/usr/bin/env bash
# Cyberdeck bring-up — top-level orchestrator.
#
# Each peripheral owns its own directory and its own setup.sh so the pieces stay
# independently useful (and independently readable) once this is published.
#
#   sudo bash setup.sh            # set up everything
#   sudo bash setup.sh ups        # set up one peripheral
#   sudo bash setup.sh ups camera # ...or several
#
# All parts are idempotent and safe to re-run.

source "$(dirname "${BASH_SOURCE[0]}")/common/lib.sh"
require_root

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_PARTS=(ups camera hailo)

parts=("$@")
if [[ ${#parts[@]} -eq 0 ]]; then
  parts=("${ALL_PARTS[@]}")
fi

for part in "${parts[@]}"; do
  script="$ROOT/$part/setup.sh"
  if [[ ! -f "$script" ]]; then
    echo "Unknown peripheral '$part'. Available: ${ALL_PARTS[*]}" >&2
    exit 1
  fi
done

for part in "${parts[@]}"; do
  printf '\n\033[1;35m######## %s ########\033[0m\n' "$part"
  # Sourced rather than executed so apt_refresh runs once across all parts.
  source "$ROOT/$part/setup.sh"
done

say "All requested peripherals configured"
cat <<'EOF'

Group membership changes do not affect already-running sessions.
Log out and back in, then verify:

  i2cdetect -y 1               # UPS HAT on the I2C bus
  rpicam-hello --list-cameras  # Camera Module 3
  hailortcli fw-control identify   # Hailo-8 (after a reboot)
EOF
