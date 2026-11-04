#!/usr/bin/env bash
# Install a model HEF you downloaded yourself into hailo-ollama's cache.
#
#   bash import-model.sh ~/Downloads/Qwen2.5-1.5B-Instruct.hef ~/Downloads/Qwen2.5-1.5B-Instruct.sha256
#
# Why this exists: dev-public.hailo.ai, where `/api/pull` fetches models from, sits
# behind a Cloudflare bot challenge (`cf-mitigated: challenge`), which answers
# every non-browser client -- hailo-ollama included -- with a 403 "Just a moment"
# page. hailo-ollama reports that as
#   no complete blob pair (HEF + .sha256 companion) for ... at v5.5.0 or fallback v5.4.0
# which reads like the model is missing; it isn't. A browser passes the challenge,
# so download both files from
#   https://dev-public.hailo.ai/v5.5.0/blob/<Name>.hef
#   https://dev-public.hailo.ai/v5.5.0/blob/<Name>.sha256
# (the names are each manifest's hef_filename, under
# /usr/local/share/hailo-ollama/models/manifests/) and hand them to this script.
#
# hailo-ollama checks its cache before the network: a HEF in the blob directory
# plus a <Name>.hef.version file holding the version counts as pulled, so the
# next `/api/pull` reports a cache hit without going online.

set -euo pipefail

VERSION="5.5.0"
BLOB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/hailo-ollama/models/blob"

hef="${1:?usage: import-model.sh <file.hef> <file.sha256>}"
companion="${2:?usage: import-model.sh <file.hef> <file.sha256>}"
name="$(basename "$hef")"

[[ "$name" == *.hef ]] || { echo "$hef: not a .hef" >&2; exit 1; }

# The companion is sha256sum output, "<64 hex>  <filename>". Checking it here is
# what hailo-ollama itself would have done after downloading.
expected="$(awk '{print tolower($1)}' "$companion")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
  echo "$companion: no sha256 in it -- if it's an HTML page, the browser hit the challenge too" >&2
  exit 1
}
echo "Checking $name"
actual="$(sha256sum "$hef" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi

if ! grep -rlqE "\"hef_filename\": *\"$name\"" /usr/local/share/hailo-ollama/models/manifests/ 2>/dev/null; then
  echo "warning: no installed manifest names $name, so no model will use it" >&2
fi

mkdir -p "$BLOB_DIR"
install -m 0644 "$hef" "$BLOB_DIR/$name"
printf '%s\n' "$VERSION" > "$BLOB_DIR/$name.version"
echo "Installed $BLOB_DIR/$name (v$VERSION)"
echo "Now pull it as usual; it should report a cache hit."
