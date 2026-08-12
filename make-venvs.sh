#!/usr/bin/env bash
# Create one virtualenv per peripheral. Run as your normal user (no sudo):
#
#   bash make-venvs.sh            # all peripherals that declare requirements
#   bash make-venvs.sh camera     # just one
#
# ---------------------------------------------------------------------------
# Why these venvs are built with --system-site-packages, and why pyenv/uv-managed
# Pythons are the wrong tool for this particular machine:
#
# The camera and indicator stacks depend on modules that CANNOT be pip-installed:
#
#   python3-libcamera   /usr/lib/python3/dist-packages/libcamera/
#   python3-picamera2   (depends on the above)
#   python3-gi          GObject-introspection bindings + typelibs
#
# These are compiled against Ubuntu's own python3.14 and its system libcamera,
# and are shipped only as .deb. There is no working PyPI equivalent.
#
# A pyenv (or uv-managed, or conda) Python is a SEPARATE interpreter built from
# source. It has its own site-packages, it is not on the same sys.path, and
# --system-site-packages is a venv flag that does not apply to it. Point a pyenv
# Python at this project and `import picamera2` fails, no matter what you pip
# install -- there is nothing to install.
#
# So: derive every venv from /usr/bin/python3 and let it see dist-packages.
# pip-installed extras (numpy builds, ML libraries, etc.) still land in the
# per-project venv, which is the isolation that actually matters here.
#
# The one case for a separate interpreter is Hailo's model-compilation toolchain
# (Dataflow Compiler / Model Zoo), which pins Python 3.10/3.11 and old TensorFlow.
# That does NOT need the camera bindings, so it belongs in a container instead.
# ---------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SYSTEM_PYTHON=/usr/bin/python3
ALL_PARTS=(ups camera hailo)

parts=("$@")
if [[ ${#parts[@]} -eq 0 ]]; then
  parts=("${ALL_PARTS[@]}")
fi

if ! "$SYSTEM_PYTHON" -m venv --help >/dev/null 2>&1; then
  echo "python3-venv is missing. Run first:  sudo bash setup.sh" >&2
  exit 1
fi

for part in "${parts[@]}"; do
  [[ -d "$part" ]] || { echo "Unknown peripheral '$part'" >&2; exit 1; }

  venv="$part/.venv"
  printf '\n\033[1;36m==> %s\033[0m\n' "$part"

  if [[ -d "$venv" ]]; then
    echo "    reusing $venv"
  else
    "$SYSTEM_PYTHON" -m venv --system-site-packages "$venv"
    echo "    created $venv (system-site-packages)"
  fi

  if [[ -f "$part/requirements.txt" ]]; then
    "$venv/bin/pip" install --quiet --upgrade pip
    "$venv/bin/pip" install --quiet -r "$part/requirements.txt"
    echo "    installed $part/requirements.txt"
  else
    echo "    no requirements.txt — distro packages only"
  fi

  # Prove the distro bindings are actually reachable from inside the venv;
  # a venv that silently can't see libcamera is worse than no venv.
  "$venv/bin/python" - <<'EOF' || true
import importlib, sys
for mod in ("libcamera", "picamera2", "gi", "smbus2"):
    try:
        importlib.import_module(mod)
        print(f"    [ok]      {mod}")
    except ImportError:
        print(f"    [absent]  {mod}")
EOF
done

cat <<'EOF'

Activate one with:
  source camera/.venv/bin/activate

Or call it directly without activating:
  camera/.venv/bin/python camera/preview.py --list
EOF
