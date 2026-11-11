#!/bin/zsh
# flash-set-ctx.sh - change Flash's --ctx-size in its LaunchAgent and reload it safely.
#   flash-set-ctx.sh 196608            plan only: current vs new, memory estimate, readings; changes nothing
#   flash-set-ctx.sh 196608 --apply    back up the plist, edit it, bootout, wait, bootstrap, wait for /health, verify
#   flash-set-ctx.sh 131072 --apply    rollback: the same script with the old value
# Refuses while Flash has a request running (FORCE=1 overrides). The new value must be a multiple of 1024 between
# 32768 and 262144 (the model's native maximum). Reload follows m5-operations.md: kickstart -k does not reload a
# plist, so this does bootout, waits until launchctl print fails, then bootstrap. Open WebUI needs no change: it
# has no Flash context setting, and the router's FAST_CTX (32768) describes Gemma, not Flash.
# Settings (all optional): FLASH_LABEL, FLASH_PLIST, FLASH_PORT, FLASH_BACKUP_DIR, PLISTBUDDY, HEALTH_WAIT (seconds).
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
setopt pipefail nounset

LABEL=${FLASH_LABEL:-com.$(id -un).mlx-serve}
DOM=gui/$(id -u)
PLIST=${FLASH_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}
PORT=${FLASH_PORT:-11234}
BACKUP_DIR=${FLASH_BACKUP_DIR:-$HOME/launchd-backups}
PB=${PLISTBUDDY:-/usr/libexec/PlistBuddy}
HEALTH_WAIT=${HEALTH_WAIT:-300}
BASE_CTX=131072          # context the 5.2 GB hot-cache figure was measured at (one session)
KV_GB_AT_BASE=5.2

die() { print -u2 -r -- "ERROR: $*"; exit 1 }

N=""; APPLY=0
for a in "$@"; do
  case $a in
    --apply) APPLY=1 ;;
    <->) N=$a ;;
    *) die "usage: ${0:t} <ctx-size> [--apply]" ;;
  esac
done
[[ -n $N ]] || die "usage: ${0:t} <ctx-size> [--apply]"
(( N >= 32768 && N <= 262144 && N % 1024 == 0 )) || die "ctx-size must be a multiple of 1024 between 32768 and 262144"
[[ -f $PLIST ]] || die "plist not found: $PLIST (set FLASH_PLIST)"

# --- locate the value in ProgramArguments
idx=-1
for (( i = 0; i < 60; i++ )); do
  v=$($PB -c "Print :ProgramArguments:$i" "$PLIST" 2>&1) || break
  [[ $v == --ctx-size ]] && { idx=$(( i + 1 )); break }
done
(( idx > 0 )) || die "no --ctx-size in ProgramArguments of $PLIST"
cur=$($PB -c "Print :ProgramArguments:$idx" "$PLIST") || die "cannot read the current value"
[[ $cur == <-> ]] || die "current --ctx-size is not a number: $cur"

running_ctx() {
  ps -axo command | awk -v p="--port $PORT" 'index($0,"mlx-serve") && index($0,p) { for (i=1;i<=NF;i++) if ($i=="--ctx-size") print $(i+1) }' | head -1
}
gauge() {
  curl -fsS --max-time 5 "http://127.0.0.1:$PORT/metrics.json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['gauges'].get('$1'))"
}
readings() {
  print "  swap:     $(sysctl -n vm.swapusage)"
  print "  pressure: $(memory_pressure | tail -1)"
  print "  Flash memory_mb=$(gauge memory_mb 2>&1) mlx_active_bytes=$(gauge mlx_active_bytes 2>&1) requests_running=$(gauge requests_running 2>&1)"
}

delta=$(awk -v n=$N -v c=$cur -v b=$BASE_CTX -v k=$KV_GB_AT_BASE 'BEGIN { printf "%.1f", (n-c)/b*k }')
print "== plan ($(date '+%Y-%m-%d %H:%M:%S'))"
print "  label:    $DOM/$LABEL"
print "  plist:    $PLIST"
print "  file:     --ctx-size $cur   running: --ctx-size $(running_ctx)"
print "  change:   $cur -> $N   (KV per full session changes by about ${delta} GB; an estimate from ${KV_GB_AT_BASE} GB at ${BASE_CTX}, not a measurement)"
readings
(( cur == N )) && { print "Nothing to change: the plist already says $N."; exit 0 }
if (( ! APPLY )); then
  print "Plan only. Run again with --apply to make the change."
  exit 0
fi

# --- preconditions
rr=$(gauge requests_running 2>&1)
if [[ $rr != 0 && ${FORCE:-0} != 1 ]]; then
  die "requests_running=$rr (not 0). Wait until Flash is idle, or FORCE=1."
fi

# --- backup and edit
mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
bak="$BACKUP_DIR/$LABEL.plist.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$PLIST" "$bak" || die "backup failed"
print "== backup: $bak"
$PB -c "Set :ProgramArguments:$idx $N" "$PLIST" || die "plist edit failed (backup: $bak)"
chk=$($PB -c "Print :ProgramArguments:$idx" "$PLIST")
[[ $chk == $N ]] || die "plist now says $chk, expected $N (backup: $bak)"
plutil -lint "$PLIST" || die "plist does not lint (restore: cp $bak $PLIST)"
print "== plist edited: --ctx-size $N"

# --- reload: bootout, wait until gone, bootstrap
print "== bootout (the model unloads; this can take up to a minute)"
launchctl bootout "$DOM/$LABEL" || print "  bootout returned $? (the job may not have been loaded)"
for (( i = 0; i < 150; i++ )); do
  launchctl print "$DOM/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl print "$DOM/$LABEL" >/dev/null 2>&1 && die "job still loaded after 75 s. Backup: $bak"
launchctl bootstrap "$DOM" "$PLIST" || die "bootstrap failed. Restore: cp $bak $PLIST, then re-run with the old value"
print "== bootstrapped; waiting up to ${HEALTH_WAIT}s for /health (the weights load from disk)"
ok=0
for (( t = 0; t < HEALTH_WAIT; t += 5 )); do
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break }
  sleep 5
done
(( ok )) || die "no /health after ${HEALTH_WAIT}s. See ~/Library/Logs/mlx-serve.log. Rollback: ${0:t} $cur --apply"

# --- verify what is actually running, not what the plist says
got=$(running_ctx)
print "== verify"
print "  running --ctx-size: $got"
readings
tail -5 "$HOME/Library/Logs/mlx-serve.log"
[[ $got == $N ]] || die "running ctx is '$got', expected $N. Rollback: ${0:t} $cur --apply"
print "OK: Flash runs with --ctx-size $N. Backup: $bak"
print "Next: the first request after a reload is slow while the weights page back in."
print "      python3 ~/bin/llm-bench.py --model flash-next --sweep 100000,130000,185000 --mem"
print "      ~/bin/m5-drift.sh   (the plist hash changed: read what it says, then ~/bin/m5-drift.sh snapshot)"
