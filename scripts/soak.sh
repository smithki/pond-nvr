#!/bin/bash
# The soak: Pond's video decoding with many made-up cameras (4K by default) for minutes at a time, to check the
# memory macOS's video decoder holds for it stays flat (src/Tests/SoakTests). Not part of the usual tests: run it
# after changing anything that decodes video (detection, the closer looks, HomeKit's re-encoding).
#
#   scripts/soak.sh [--quick] [--cameras N] [--size WxH] [--fps N] [--minutes M] [--recording N] [--taps N]
#                   [--capacity PX] [--max-decoder MB] [--max-wired GB] [--stop-pond]
#
# With Pond's own service running, its decoding and its language model count in the readings, so wired memory is
# reported but not judged; --stop-pond stops the service for a clean reading and starts it again afterwards
# (always, ^C included).
#
# What it can't do to the Mac: a watchdog outside the test stops it the moment the decoder service passes
# --max-decoder (default: an eighth of the Mac's memory) or wired memory grows by --max-wired GB (default 4); it is
# stopped too if it runs well past its time, and whatever happens (^C included) nothing it started is left running.
# Its output is kept in a log (the path is printed). Exit status: 0 passed, 1 failed, 2 stopped by the watchdog or
# the time limit, 64 a usage mistake.
set -u

cameras=8 size=3840x2160 fps=15 minutes=3 recording=2 taps="" capacity="" max_decoder="" max_wired=4 stop_pond=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) cameras=2 minutes=0.5 ;;
    --cameras) cameras="$2"; shift ;;
    --size) size="$2"; shift ;;
    --fps) fps="$2"; shift ;;
    --minutes) minutes="$2"; shift ;;
    --recording) recording="$2"; shift ;;
    --taps) taps="$2"; shift ;;
    --capacity) capacity="$2"; shift ;;   # the media engine's budget, pixels a second (POND_MEDIA_CAPACITY)
    --max-decoder) max_decoder="$2"; shift ;;
    --max-wired) max_wired="$2"; shift ;;
    --stop-pond) stop_pond=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done
[ "$(uname)" = Darwin ] || { echo "✗ the soak needs macOS (VideoToolbox)" >&2; exit 64; }

cd "$(dirname "$0")/../src" || exit 64
memory_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
max_decoder=${max_decoder:-$(( memory_mb / 8 ))}
seconds=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')
log=$(mktemp -t pond-soak).log

# The memory measured: wired (GB) and what every decoder service holds (MB).
wired_gb() { vm_stat | awk '/Pages wired down/ { gsub("\\.", "", $4); printf "%.2f", $4 * 16384 / 1073741824 }'; }
decoder_mb() {
  local total=0 p mb
  for p in $(pgrep -x VTDecoderXPCService); do
    mb=$(footprint "$p" 2>/dev/null | awk '/phys_footprint:/ { v = $2; if ($3 == "GB") v *= 1024; if ($3 == "KB") v /= 1024; printf "%d", v; exit }')
    total=$(( total + ${mb:-0} ))
  done
  echo "$total"
}

agent="$HOME/Library/LaunchAgents/camera.pond.recorder.plist"
service="gui/$(id -u)/camera.pond.recorder"
judge_wired=1 restart_pond=0
if launchctl print "$service" >/dev/null 2>&1; then
  if [ "$stop_pond" = 1 ]; then
    echo "Stopping Pond's service for the soak (it starts again afterwards)."
    launchctl bootout "$service" 2>/dev/null
    restart_pond=1
    sleep 3
  else
    echo "! Pond's service is running: its decoding and language model count in the readings, so wired memory is"
    echo "  reported, not judged (--stop-pond for a clean reading)."
    judge_wired=0
  fi
fi
# Pond's service started again, if the soak stopped it: whatever happens.
restore() {
  if [ "$restart_pond" = 1 ]; then
    launchctl bootstrap "gui/$(id -u)" "$agent" 2>/dev/null && echo "Pond's service started again."
    restart_pond=0
  fi
}
trap restore EXIT
echo "Building…"
swift build --build-tests >>"$log" 2>&1 || { echo "✗ the build failed: $log" >&2; exit 1; }

baseline_wired=$(wired_gb)
echo "Soaking: $cameras cameras at $size, $fps fps, $recording recording to HomeKit, for $minutes min."
echo "Stopped at a decoder service of $max_decoder MB, or wired memory $max_wired GB over $baseline_wired GB. Log: $log"

# The test in a process group of its own, so all of it can be stopped at once.
set -m
POND_SOAK=1 POND_SOAK_CAMERAS="$cameras" POND_SOAK_SIZE="$size" POND_SOAK_FPS="$fps" POND_SOAK_SECONDS="$seconds" \
  POND_SOAK_RECORDING="$recording" POND_SOAK_WIRED="$judge_wired" ${taps:+POND_SOAK_TAPS="$taps"} ${capacity:+POND_MEDIA_CAPACITY="$capacity"} \
  swift test --skip-build --filter SoakTests >>"$log" 2>&1 &
test_pid=$!
set +m

stopped=""
finish() {
  kill -TERM -- "-$test_pid" 2>/dev/null
  sleep 1
  kill -KILL -- "-$test_pid" 2>/dev/null
}
trap 'stopped="interrupted"; finish; echo; echo "✗ interrupted: stopped"; exit 2' INT TERM

deadline=$(( $(date +%s) + seconds + 180 ))
peak_decoder=0 peak_wired=$baseline_wired
while kill -0 "$test_pid" 2>/dev/null; do
  d=$(decoder_mb) w=$(wired_gb)
  [ "$d" -gt "$peak_decoder" ] && peak_decoder=$d
  awk -v a="$w" -v b="$peak_wired" 'BEGIN { exit !(a > b) }' && peak_wired=$w
  if [ "$d" -gt "$max_decoder" ]; then stopped="the decoder service reached $d MB"; break; fi
  if awk -v w="$w" -v b="$baseline_wired" -v m="$max_wired" 'BEGIN { exit !(w - b > m) }'; then
    stopped="wired memory reached $w GB"; break
  fi
  if [ "$(date +%s)" -gt "$deadline" ]; then stopped="it ran past its time"; break; fi
  line=$(grep -a "^soak: " "$log" | tail -1)
  if [ -n "$line" ] && [ "$line" != "${shown:-}" ]; then
    # On a terminal, one line kept up to date; else (a log, CI) a line now and then.
    if [ -t 1 ]; then printf '\r\033[K%s' "${line#soak: }"; elif [ $(( $(date +%s) % 30 )) -lt 2 ]; then echo "${line#soak: }"; fi
    shown=$line
  fi
  sleep 2
done
[ -t 1 ] && echo
if [ -n "$stopped" ]; then
  finish
  echo "✗ stopped by the watchdog: $stopped (peak: decoder service $peak_decoder MB, wired $peak_wired GB). Log: $log"
  exit 2
fi
wait "$test_pid"; status=$?
grep -a -E "^soak: (before|after|the decoder service at most|wired memory typically)" "$log"
echo "Peak: decoder service $peak_decoder MB, wired $peak_wired GB (from $baseline_wired GB)."
if [ "$status" -eq 0 ] && grep -aq "passed after" "$log" && ! grep -aq "Expectation failed" "$log"; then
  echo "✓ passed"
  exit 0
fi
grep -a -E "Expectation failed|error:" "$log" | head -5
echo "✗ failed. Log: $log"
exit 1
