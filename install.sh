#!/usr/bin/env zsh
# install.sh — link this repo's M5 scripts into ~/bin and (optionally) install the login LaunchAgent.
# Default is a dry run: it only prints what it would do.
#   ./install.sh            dry run
#   ./install.sh --apply    link scripts into ~/bin (existing files are moved to *.bak-YYYYMMDD)
#   ./install.sh --apply --launchd   also render and load ~/Library/LaunchAgents/com.$USER.flash-up.plist
set -euo pipefail
REPO="${0:A:h}"
APPLY=0; LAUNCHD=0
for a in "$@"; do
  case "$a" in --apply) APPLY=1;; --launchd) LAUNCHD=1;; *) echo "unknown option $a" >&2; exit 1;; esac
done
run() { if (( APPLY )); then "$@"; else print -r -- "would run: $*"; fi }
stamp=$(date +%Y%m%d)

mkdir -p "$HOME/bin"
for f in "$REPO"/m5/bin/*; do
  dest="$HOME/bin/${f:t}"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$f" ]]; then print "ok      ${f:t}"; continue; fi
  [[ -e "$dest" || -L "$dest" ]] && run mv "$dest" "$dest.bak-$stamp"
  run ln -s "$f" "$dest"
  run chmod +x "$f"
done

if (( LAUNCHD )); then
  label="com.$USER.flash-up"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  tmp=$(mktemp)
  sed -e "s|__USER__|$USER|g" -e "s|__HOME__|$HOME|g" "$REPO/m5/launchd/flash-up.plist.template" > "$tmp"
  if [[ -f "$plist" ]] && cmp -s "$tmp" "$plist"; then
    print "ok      $label (unchanged)"
  else
    [[ -f "$plist" ]] && { print "diff vs installed:"; diff "$plist" "$tmp" || true; }
    run launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    run sleep 5
    [[ -f "$plist" ]] && run cp "$plist" "$plist.bak-$stamp"
    run cp "$tmp" "$plist"
    run launchctl bootstrap "gui/$UID" "$plist"
  fi
  rm -f "$tmp"
fi
(( APPLY )) || print "\nDry run only. Re-run with --apply."
