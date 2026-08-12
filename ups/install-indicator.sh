#!/usr/bin/env bash
# Install the UPS indicator as a systemd --user service so it starts at login.
#
# Run as your normal user, NOT with sudo:
#   bash install-indicator.sh
#
# Waveshare's version instead dropped a .desktop file into ~/.config/autostart
# with DISPLAY=':0.0' baked in. systemd --user is a better fit here: it restarts
# the indicator if it crashes, inherits the Wayland session environment properly,
# and gives us `journalctl --user -u cyberdeck-ups` for debugging.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, without sudo." >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/cyberdeck-ups.service" <<EOF
[Unit]
Description=Cyberdeck UPS HAT (E) top-bar indicator
# graphical-session.target is what actually signals "the desktop is up" for a
# user unit; ordering against it avoids racing the GNOME Shell panel.
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$HERE
ExecStart=/usr/bin/python3 $HERE/indicator.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now cyberdeck-ups.service

echo
echo "Installed and started. Useful commands:"
echo "  systemctl --user status cyberdeck-ups"
echo "  journalctl --user -u cyberdeck-ups -f"
echo "  systemctl --user restart cyberdeck-ups"
