#!/usr/bin/env bash
# Dev helper (run inside WSL): mirror the Windows working copy into the Linux
# filesystem, where the venv, benchmark checkout and data live.
set -euo pipefail
SRC="${SRC:-/mnt/c/Users/Saumya Bisht/Desktop/Samsung/}"
DST="${DST:-$HOME/samsung/}"
rsync -a --exclude .venv --exclude third_party --exclude 'eval/results/*/' "$SRC" "$DST"
echo "synced -> $DST"
