#!/bin/zsh

# STALE PLIST guard (auto-inserted 2026-11-11): /tmp is cleared at boot and reaped ~3d.
if plutil -extract StandardOutPath raw /Library/LaunchDaemons/com.user.macmonitor.plist 2>/dev/null \
     | grep -q "^/tmp/"; then
  print -u2 "STALE PLIST: StandardOutPath is /tmp — pre-2026-11-07 variant, refusing to archive"; exit 1
fi
# interim-archive.sh v2 — Studio config/state -> RAID0 interim tier.
# Publishes only when every mandatory payload landed. Non-zero exit = incomplete.
set -u
setopt NULL_GLOB

vol=/Volumes/TB5KinstonRAID0
[ -d "$vol/interim" ] || { print -u2 "HOLD: $vol/interim not mounted"; exit 2 }

dst="$vol/interim/$(date +%Y-%m-%d)"
tmp="$dst.build-$$"
mkdir -p "$tmp" || exit 2
rc=0

# $1=key  $2=path ; root fallback for files the admin user cannot read.
capture_file() {
  local key=$1 src=$2
  if [[ ! -e $src ]]; then print -u2 "ABSENT    $key  ($src)"; return 1; fi
  if [[ ! -r $src ]]; then
    if sudo -n cat "$src" > "$tmp/$key" 2>/dev/null; then print "ok(root)  $key"; return 0; fi
    rm -f "$tmp/$key"; print -u2 "NO-READ   $key  ($src)"; return 1
  fi
  if cat "$src" > "$tmp/$key"; then print "ok        $key"; return 0; fi
  rm -f "$tmp/$key"; print -u2 "COPYFAIL  $key  ($src)"; return 1
}

sudo -n true 2>/dev/null && print "sudo ticket: ok" \
  || print -u2 "sudo ticket: none — root-only payloads will be skipped (run 'sudo -v' first)"

capture_file Caddyfile             /opt/homebrew/etc/Caddyfile                        || rc=1
capture_file toggle-disabled.state /usr/local/var/macos-service-toggle/disabled.state || rc=1
capture_file peaks.json            "$HOME/.local/share/macmonitor_peaks.json"         || rc=1
capture_file RemoveMacAI.zip       "$HOME/Downloads/RemoveMacAI.zip"                  || rc=1

# Daemon plist: installed copy first (the only one that reflects drift), dated backups newest-first.
plist_ok=0
capture_file macmonitor.plist /Library/LaunchDaemons/com.user.macmonitor.plist && plist_ok=1
if (( ! plist_ok )); then
  for cand in /usr/local/etc/launchd-backups/com.user.macmonitor.plist.*(N/Om); do
    capture_file macmonitor.plist "$cand" && { plist_ok=1; break }
  done
fi
(( plist_ok )) || rc=1

# fidelity only — rebuildable from sudoers.d/mac-monitor.example + visudo -c -f
capture_file sudoers-mac-monitor /etc/sudoers.d/mac-monitor \
  || print -u2 "optional: sudoers drop-in skipped (rebuildable from sudoers.d/mac-monitor.example)"

if [[ -r "$HOME/ZuulRulez/gemma/hardening" ]]; then
  ditto "$HOME/ZuulRulez/gemma/hardening" "$tmp/hardening" && print "ok        hardening" \
    || { print -u2 "COPYFAIL  hardening"; rc=1; }
else
  print -u2 "ABSENT    hardening"; rc=1
fi

( cd "$tmp" && find . -type f ! -name '.sha256' -print0 | xargs -0 shasum -a 256 > .sha256 ) || rc=1
if ! ( cd "$tmp" && shasum -a 256 -c .sha256 > "$tmp/.verify.log" 2>&1 ); then
  print -u2 "SHA VERIFY FAILED:"; cat "$tmp/.verify.log" >&2; rc=1
fi
rm -f "$tmp/.verify.log"

if (( rc )); then
  print -u2 "HOLD: incomplete generation staged at $tmp — $dst untouched"
  exit $rc
fi

rm -rf -- "$dst" && mv -- "$tmp" "$dst" || exit 1
chmod -R go-rwx "$dst"          # holds a sudoers copy and the live Caddyfile
print "published $dst"

find "$vol/interim" -maxdepth 1 -type d -name '*.build-*' -mtime +1 -exec rm -rf {} + 2>/dev/null
gens=("$vol"/interim/2*(N/Om))  # dirs only, newest first
gens=(${gens:#*.build-*})
for g in ${gens[9,-1]}; do rm -rf -- "$g"; done      # retain 8
exit 0
