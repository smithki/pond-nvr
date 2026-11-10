#!/bin/sh
# A release's notes: CHANGELOG.md's section for VERSION, from its heading to the next, without the heading.
# Used by the release workflow and by make publish, so a release's notes are the same however it's made.
#
#   scripts/release-notes.sh 0.1.0
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release-notes.sh VERSION}
awk -v v="$VERSION" '$0 ~ "^## " { if (on) exit; on = ($2 == v); next } on' CHANGELOG.md
