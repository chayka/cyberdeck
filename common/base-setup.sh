#!/usr/bin/env bash
# Shared prerequisites — Python environment tooling used by every peripheral.
#
# Run via the orchestrator: sudo bash setup.sh
#
# Ubuntu's python3.14 ships WITHOUT ensurepip, so `python3 -m venv` fails with
# "ensurepip is not available" until python3.14-venv is installed. pip itself is
# also absent by default.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

say "Base: Python virtualenv tooling"
# python3-venv is a metapackage pointing at the current interpreter's -venv.
# python3-dev supplies the headers needed to compile native extensions against
# this interpreter — required for HailoRT's pybind11 bindings.
apt_install python3-venv python3.14-venv python3-pip python3-dev

say "Base: done"
info "Create the per-project environments with:  bash make-venvs.sh   (no sudo)"
