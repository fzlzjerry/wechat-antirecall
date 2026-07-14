#!/bin/bash
# Writes patches.json.sha256 next to patches.json. Commit BOTH so the GUI's
# "拉取最新补丁数据" can verify integrity (it fetches patches.json.sha256 from main and
# rejects a mismatch). Run this whenever patches.json changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HASH="$(shasum -a 256 "$ROOT/patches.json" | awk '{print $1}')"
printf '%s  patches.json\n' "$HASH" > "$ROOT/patches.json.sha256"
echo ">> wrote patches.json.sha256: $HASH"
