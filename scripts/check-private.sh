#!/bin/sh
# Keeps footage, pictures and databases out of the repository: no one's recordings, events, snapshots or Pond
# database (camera names, times, what was seen) ever reach contributors or other users. Refuses any such file
# that's tracked (or, with --staged, about to be committed) unless scripts/private-allowlist.txt names it: only
# made-up media belongs here (test patterns, the demo's own drawings).
#
#   scripts/check-private.sh            every tracked file (make check; CI)
#   scripts/check-private.sh --staged   what's staged (the pre-commit hook: make hooks)
set -eu
cd "$(dirname "$0")/.."

media='\.(mp4|m4v|mov|mkv|avi|ts|h264|264|h265|265|hevc|jpg|jpeg|png|heic|heif|gif|webp|tif|tiff|bmp|aac|m4a|wav|mp3|caf|sqlite|sqlite3|sqlite-wal|sqlite-shm|db|db-wal|db-shm)$'
allow=scripts/private-allowlist.txt

if [ "${1:-}" = --staged ]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
else
  files=$(git ls-files)
fi

found=$(printf '%s\n' "$files" | grep -iE "$media" | grep -vxF -f "$allow" || true)
if [ -n "$found" ]; then
  echo "✗ Recordings, pictures or databases aren't kept in the repository (no one's footage leaves their Mac):"
  printf '  %s\n' $found
  echo "  Made-up media only (a test pattern, a demo drawing): name it in $allow, with why."
  exit 1
fi
echo "✓ no footage, pictures or databases in the repository"
