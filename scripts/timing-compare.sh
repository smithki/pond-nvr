#!/bin/sh
# Times a change against the way before, fairly (docs/smoothness.md): runs one of the demo's timed snapshot steps
# (live, transitions, panels, timeline, timeline-loop) with a setting of the demo's off, then on, then off and on again,
# each in a launch of its own, after a launch to warm up (the first after a build runs slower), and prints each run's
# report. The demo's day fills as it goes, so runs side by side say more than runs an hour apart. The setting is put
# back as it was. Needs the demo app (make app APP="dist/demo/Pond NVR.app").
#
#   scripts/timing-compare.sh STEP SETTING [--rounds N] [--scenario NAME] [--env NAME=VALUE]...
#
#   scripts/timing-compare.sh timeline timelineSurface
#   scripts/timing-compare.sh timeline-loop timelineSurface --env POND_TIMELINE_LOOP=zoom
set -eu
cd "$(dirname "$0")/.."

step=${1:?usage: scripts/timing-compare.sh STEP SETTING [--rounds N] [--scenario NAME] [--env NAME=VALUE]...}
setting=${2:?usage: scripts/timing-compare.sh STEP SETTING [--rounds N] [--scenario NAME] [--env NAME=VALUE]...}
shift 2
rounds=2 scenario=home envs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) rounds=$2; shift 2 ;;
        --scenario) scenario=$2; shift 2 ;;
        --env) envs="$envs --env $2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

app="dist/demo/Pond NVR.app"
domain=camera.pond.demo
[ -d "$app" ] || { echo "no demo app: make app APP=\"$app\"" >&2; exit 1; }
quit() { pkill -f "^$PWD/dist/demo/Pond NVR.app/Contents/MacOS/PondAp[p]" || true; }
was=$(defaults read "$domain" "$setting" 2>/dev/null || echo unset)
restore() {
    if [ "$was" = unset ]; then defaults delete "$domain" "$setting" 2>/dev/null || true
    else defaults write "$domain" "$setting" -bool "$([ "$was" = 1 ] && echo true || echo false)"; fi
}
trap restore EXIT

run() {
    out="dist/checks/compare-$step-$1"
    rm -rf "$out"
    mkdir -p "$out"
    quit
    sleep 2
    # shellcheck disable=SC2086
    open -n -W --env POND_SNAPSHOTS="$PWD/$out" --env POND_SNAPSHOTS_ONLY="$step" $envs "$app" --args --demo "$scenario"
    report=$(ls "$out"/*.txt 2>/dev/null | head -1)
    echo "== $2"
    [ -n "$report" ] && cat "$report" || echo "(no report)"
}

defaults write "$domain" "$setting" -bool true
run warm "warming up (not counted)" >/dev/null
r=1
while [ "$r" -le "$rounds" ]; do
    defaults write "$domain" "$setting" -bool false
    run "off-$r" "$setting off, round $r"
    defaults write "$domain" "$setting" -bool true
    run "on-$r" "$setting on, round $r"
    r=$((r + 1))
done
