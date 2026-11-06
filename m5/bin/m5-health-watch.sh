#!/bin/zsh
# m5-health-watch.sh - run m5-health.sh and record only its problem lines, and only when they change.
# Also runs m5-drift.sh (when linked into ~/bin) and treats its DRIFT: lines as problems.
# Meant for the LaunchAgent in m5/launchd/m5-health-watch.plist.template. Quiet while healthy: the log
# gets an entry when a problem appears, changes, or clears. Settings (all optional) go in
# ~/.config/macllm.env: HEALTH_NOTIFY=1 shows a macOS notification when a problem appears or changes.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"

HEALTH="${HEALTH_SCRIPT:-$HOME/bin/m5-health.sh}"
LOG="${HEALTH_WATCH_LOG:-$HOME/Library/Logs/m5-health-watch.log}"
STATE="${HEALTH_WATCH_STATE:-$HOME/.local/state/m5-health-watch/last}"
mkdir -p "${LOG:h}" "${STATE:h}"

DRIFT="${DRIFT_SCRIPT:-$HOME/bin/m5-drift.sh}"

out=$("$HEALTH" 2>&1); rc=$?
if [[ -z "$out" ]]; then
  problems="m5-health.sh produced no output (exit $rc)"
else
  problems=$(print -r -- "$out" | grep -E 'DOWN|CHECK|REGRESSION|REJECTED|no response|allowlist is open|WARN:|not loaded' | sed 's/^ *//')
fi
if [[ -x "$DRIFT" ]]; then
  dout=$("$DRIFT" 2>&1 | grep -E 'DRIFT:|WARN:' | sed 's/^ *//')
  [[ -n "$dout" ]] && problems="${problems:+$problems$'\n'}$dout"
fi

prev=""; [[ -f "$STATE" ]] && prev=$(<"$STATE")
[[ "$problems" == "$prev" ]] && exit 0

{
  if [[ -n "$problems" ]]; then
    print "$(date '+%F %T') PROBLEM"
    print -r -- "$problems" | sed 's/^/  /'
  else
    print "$(date '+%F %T') OK (recovered)"
  fi
} >> "$LOG"
print -r -- "$problems" > "$STATE"

if [[ -n "$problems" && "${HEALTH_NOTIFY:-0}" == 1 ]]; then
  osascript -e 'display notification "See ~/Library/Logs/m5-health-watch.log" with title "M5 health: problem"'
fi
exit 0
