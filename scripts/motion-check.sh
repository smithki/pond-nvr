#!/bin/sh
# Watches a move frame by frame (docs/motion.md): runs one of the demo's snapshot steps (Snapshots.swift) and captures
# a burst of its window's pictures, ten or so a second, while it drives the app, then lays them out on one sheet.
# The pictures are the window as it really draws (layers, glass), not the app's own snapshots. Needs the demo app
# (make app APP="dist/demo/Pond NVR.app") and screen-recording permission for the terminal.
#
#   scripts/motion-check.sh STEP [--delay SECONDS] [--frames N] [--scenario NAME] [--out DIR] [--env NAME=VALUE]...
#
#   --delay     seconds from the window's showing to the first picture (default 6: steps usually wait 5 first)
#   --frames    how many pictures (default 40)
#   --scenario  the demo's scenario (default home)
#   --out       where the pictures, the sheet and the step's reports go (default dist/checks/STEP)
#   --env       more for the app's environment (POND_TIMELINE_LOOP=seek, say); repeatable
#
# The first launch after a build runs slower: judge timings from a later one (scripts/timing-compare.sh does).
set -eu
cd "$(dirname "$0")/.."

step=${1:?usage: scripts/motion-check.sh STEP [--delay S] [--frames N] [--scenario NAME] [--out DIR] [--env NAME=VALUE]...}
shift
delay=6 frames=40 scenario=home out="dist/checks/$step" envs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --delay) delay=$2; shift 2 ;;
        --frames) frames=$2; shift 2 ;;
        --scenario) scenario=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --env) envs="$envs --env $2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

app="dist/demo/Pond NVR.app"
[ -d "$app" ] || { echo "no demo app: make app APP=\"$app\"" >&2; exit 1; }
# (Only the demo's: the bracket keeps the pattern from matching this shell's own command line.)
quit() { pkill -f "^$PWD/dist/demo/Pond NVR.app/Contents/MacOS/PondAp[p]" || true; }
mkdir -p "$out" dist/tools
rm -f "$out"/frame-*.jpg
[ dist/tools/window-id -nt scripts/window-id.swift ] || swiftc -O -o dist/tools/window-id scripts/window-id.swift

quit
sleep 2
# shellcheck disable=SC2086
open -n -W --env POND_SNAPSHOTS="$PWD/$out" --env POND_SNAPSHOTS_ONLY="$step" $envs "$app" --args --demo "$scenario" &
opened=$!

pid="" window=""
tries=0
while [ -z "$window" ] && [ $tries -lt 300 ]; do
    sleep 0.1
    tries=$((tries + 1))
    pid=$(pgrep -f "^$PWD/dist/demo/Pond NVR.app/Contents/MacOS/PondAp[p]" | head -1 || true)
    [ -n "$pid" ] && window=$(dist/tools/window-id "$pid" || true)
done
[ -n "$window" ] || { echo "the demo's window didn't show" >&2; quit; exit 1; }

sleep "$delay"
i=1
while [ $i -le "$frames" ]; do
    screencapture -x -o -t jpg -l"$window" "$(printf '%s/frame-%03d.jpg' "$out" $i)" 2>/dev/null || break
    i=$((i + 1))
done
wait $opened || true

if command -v ffmpeg >/dev/null; then
    columns=5
    rows=$(( (frames + columns - 1) / columns ))
    ffmpeg -v error -y -framerate 10 -pattern_type glob -i "$out/frame-*.jpg" \
        -vf "scale=520:-1,tile=${columns}x${rows}" -frames:v 1 "$out/sheet.jpg"
    echo "sheet: $out/sheet.jpg"
fi
echo "pictures: $out/frame-*.jpg"
for report in "$out"/*.txt; do [ -f "$report" ] && { echo "== $report"; cat "$report"; }; done
