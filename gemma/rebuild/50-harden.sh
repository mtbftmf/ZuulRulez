#!/usr/bin/env bash
# 50-harden.sh — helpers for the hardening step (runbook phase H): the RemoveMacAI profile and the
# macOS service toggles, applied only after 40-verify.sh passes and a benchmark is recorded.
#
#   bash 50-harden.sh snapshot before   memory, swap and process counts → ~/hardening/before.txt
#   bash 50-harden.sh profile           install RemoveMacAI (approve it over Screen Sharing), wait for it
#   bash 50-harden.sh snapshot after    same snapshot after the toggles and a reboot
#   bash 50-harden.sh compare           before vs after, for the CHANGELOG line
#   bash 50-harden.sh status            profile installed? toggle tool and its status
#
# The toggle tool itself (macos-service-toggle.sh + its reassert LaunchDaemon) is installed the same
# way as on the MBP, from the MBP's fixed copy (com.apple.watchdogd protected, rapportd never disabled).
# Before every macOS update the profile must come off: 10-upgrade-os.sh offers to remove it and
# leaves a reminder that 40-verify.sh reports until the profile is back.
set -uo pipefail

PROFILE_ID="io.github.omlahore.removemacai"
PROFILE_FILE="${PROFILE_FILE:-$HOME/Downloads/RemoveMacAI.mobileconfig}"
TOGGLE="${TOGGLE:-/usr/local/bin/macos-service-toggle.sh}"
DIR="$HOME/hardening"
MARKER="$HOME/.config/removemacai-reinstall"
mkdir -p "$DIR"

has_profile() { sudo profiles list 2>/dev/null | grep -q "$PROFILE_ID"; }

snapshot() {  # $1 label
  local f="$DIR/$1.txt"
  {
    printf 'taken\t%s\n' "$(date '+%F %T')"
    printf 'macos\t%s\n' "$(sw_vers -productVersion)"
    printf 'uptime\t%s\n' "$(uptime | sed 's/.*up \([^,]*\),.*/\1/')"
    printf 'physmem\t%s\n' "$(top -l 1 -s 0 | grep PhysMem | sed 's/^PhysMem: //')"
    printf 'swap\t%s\n' "$(sysctl -n vm.swapusage)"
    printf 'pressure_free\t%s\n' "$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2}')"
    printf 'processes\t%s\n' "$(ps -A | tail -n +2 | wc -l | tr -d ' ')"
    printf 'launchd_running\t%s\n' "$(launchctl list | awk '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')"
    printf 'rss_total_mb\t%s\n' "$(ps -A -o rss= | awk '{s+=$1} END {printf "%.0f", s/1024}')"
    printf 'profile\t%s\n' "$(has_profile && echo installed || echo absent)"
  } > "$f"
  echo "→ $f"; cat "$f"
  echo "Tip: take both snapshots a few minutes after a reboot, with the model loaded, so they compare."
}

case "${1:-status}" in
  snapshot)
    [[ -n "${2:-}" ]] || { echo "usage: $0 snapshot before|after" >&2; exit 1; }
    sudo -v; snapshot "$2" ;;
  profile)
    sudo -v
    if has_profile; then echo "RemoveMacAI already installed."; rm -f "$MARKER"; exit 0; fi
    [[ -f "$PROFILE_FILE" ]] || { echo "error: $PROFILE_FILE missing — download the latest release from https://omlahore.github.io/RemoveMacAI/ first" >&2; exit 1; }
    open "$PROFILE_FILE" 2>/dev/null || echo "Could not open it from SSH: double-click $PROFILE_FILE in Finder over Screen Sharing."
    echo "Approve it over Screen Sharing: System Settings → General → Device Management → RemoveMacAI → Install."
    printf "Waiting up to 10 min for the profile "
    for _ in $(seq 1 120); do has_profile && break; printf "."; sleep 5; done; echo
    if has_profile; then rm -f "$MARKER"; echo "✓ RemoveMacAI installed"; else echo "not installed yet — rerun when approved"; exit 1; fi ;;
  compare)
    [[ -f "$DIR/before.txt" && -f "$DIR/after.txt" ]] || { echo "error: need $DIR/before.txt and after.txt" >&2; exit 1; }
    paste "$DIR/before.txt" "$DIR/after.txt" | awk -F'\t' '{printf "%-16s %-50s %s\n", $1, $2, $4}' ;;
  status)
    sudo -v
    has_profile && echo "RemoveMacAI: installed" || echo "RemoveMacAI: absent"
    [[ -f "$MARKER" ]] && echo "Reminder: profile was removed for a macOS update on $(cat "$MARKER") — reinstall: bash $0 profile"
    if [[ -x "$TOGGLE" ]]; then sudo "$TOGGLE" status; else echo "service toggles: $TOGGLE not installed"; fi
    sudo launchctl print-disabled system | grep -E 'watchdogd' || echo "watchdogd: not disabled (good)"
    sudo launchctl print-disabled "gui/$(id -u)" 2>/dev/null | grep -E 'rapportd' && echo "WARNING: rapportd is disabled — it breaks AirDrop and Universal Control" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
