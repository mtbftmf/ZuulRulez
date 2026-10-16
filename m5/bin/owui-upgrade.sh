#!/usr/bin/env bash
# owui-upgrade.sh — back up, upgrade (or roll back) and restart Open WebUI running under launchd.
#
# Usage:
#   ~/bin/owui-upgrade.sh              upgrade to the latest release (skips if already current)
#   ~/bin/owui-upgrade.sh 0.11.4       install a specific version (use this to roll back)
#   FORCE=1 ~/bin/owui-upgrade.sh      reinstall even if already on the latest
#
# Restore data from a backup (only if the database itself is damaged):
#   tar -xzf ~/owui-backups/<file>.tgz -C ~
set -euo pipefail

# ---------- CONFIG ----------
VENV="${VENV:-$HOME/open-webui-venv}"
DATA_DIR="${DATA_DIR:-$HOME/open-webui-data}"
LABEL="${LABEL:-com.openwebui.serve}"
PLIST="${PLIST:-/Library/LaunchDaemons/com.openwebui.serve.plist}"
URL="${URL:-http://localhost:8080}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/owui-backups}"
KEEP="${KEEP:-5}"                 # number of backups to keep
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"   # seconds; first start after an upgrade migrates the DB
# ----------------------------

PIP="$VENV/bin/pip"
TARGET="${1:-}"
die() { echo "error: $*" >&2; exit 1; }
ver() { "$PIP" show open-webui 2>/dev/null | awk '/^Version:/ {print $2}'; }

[[ -x "$PIP" ]] || die "pip not found at $PIP"
[[ -f "$DATA_DIR/webui.db" ]] || die "no webui.db in $DATA_DIR (check DATA_DIR)"
if ! /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:DATA_DIR" "$PLIST" 2>/dev/null | grep -qx "$DATA_DIR"; then
  echo "warning: $PLIST does not set DATA_DIR=$DATA_DIR — the service may be using a different data folder."
  read -r -p "Continue anyway? [y/N] " ans; [[ "$ans" == [yY]* ]] || exit 1
fi

CURRENT="$(ver)"
if [[ -z "$TARGET" ]]; then
  LATEST="$("$PIP" index versions open-webui 2>/dev/null | sed -n 's/^open-webui (\(.*\))$/\1/p')"
  [[ -n "$LATEST" ]] || die "could not look up the latest version (network?)"
  echo "→ Installed: $CURRENT   Latest: $LATEST"
  if [[ "$CURRENT" == "$LATEST" && "${FORCE:-0}" != 1 ]]; then
    echo "Already current. Nothing to do (FORCE=1 to reinstall)."; exit 0
  fi
  SPEC="open-webui==$LATEST"
else
  echo "→ Installed: $CURRENT   Requested: $TARGET"
  SPEC="open-webui==$TARGET"
fi

echo "→ Asking for sudo up front (launchctl)"
sudo -v

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/owui-$(date +%Y%m%d-%H%M%S)-v$CURRENT.tgz"

echo "→ Stopping Open WebUI ($LABEL)"
if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo launchctl bootout "system/$LABEL" || true
  for _ in $(seq 1 30); do
    sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done
  sudo launchctl print "system/$LABEL" >/dev/null 2>&1 && die "service did not stop within 30 s"
else
  echo "  (was not running)"
fi

echo "→ Backing up $DATA_DIR → $BACKUP"
tar -czf "$BACKUP" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
tar -tzf "$BACKUP" | grep -q 'webui.db$' || die "backup verification failed — webui.db missing from $BACKUP"
echo "  $(du -h "$BACKUP" | cut -f1) verified"

echo "→ Installing $SPEC"
if ! "$PIP" install --upgrade "$SPEC"; then
  echo "pip failed — restarting the previous version untouched."
  sudo launchctl bootstrap system "$PLIST"
  die "upgrade aborted"
fi
NEW="$(ver)"
echo "  now on $NEW"

echo "→ Starting Open WebUI"
sudo launchctl bootstrap system "$PLIST"
printf "→ Waiting for %s/health (up to %ss) " "$URL" "$HEALTH_TIMEOUT"
ok=0
for _ in $(seq 1 $((HEALTH_TIMEOUT / 3))); do
  if curl -fs "$URL/health" >/dev/null 2>&1; then ok=1; break; fi
  printf "."; sleep 3
done
echo
if [[ $ok != 1 ]]; then
  echo "Open WebUI did not come up on $NEW."
  echo "Roll back with:   $0 $CURRENT"
  echo "Data backup:      $BACKUP"
  exit 1
fi

echo "→ Pruning backups (keeping newest $KEEP)"
ls -1t "$BACKUP_DIR"/owui-*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r f; do rm -f "$f"; echo "  removed $(basename "$f")"; done

echo "✓ Open WebUI $CURRENT → $NEW is up. Backup: $BACKUP"
echo "  Hard-reload the browser (⌘⇧R) and spot-check personas, Auto Router and connections."
