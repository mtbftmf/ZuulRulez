#!/bin/bash
# macos-service-toggle-reassert.sh — production fix for the Golden Gate
# early-boot revert bug (see handoff doc, gotcha #5 correction).
#
# Reads /usr/local/var/macos-service-toggle/disabled.state (written by
# macos-service-toggle.sh's `on`) and re-issues `launchctl disable` for
# every entry in it, at boot, before the OS's own early-boot reset can
# take effect for GUI/system-domain overrides.
#
# - system-domain entries: disabled immediately, no dependency on login.
# - gui/<uid> or user/<uid> entries: the ORIGINAL uid recorded in the
#   state file may not match the uid of whoever is actually logged in
#   on this boot (different user, different machine, etc.), so this
#   script waits for a REAL human console session (uid >= 500, skips
#   placeholder accounts like _windowserver) and re-targets using the
#   CURRENT console uid rather than the one baked into the state file.
#
# Install as a RunAtLoad LaunchDaemon. Does nothing if disabled.state
# doesn't exist (i.e. `on` was never run / `off` already reverted it).

set -uo pipefail

STATE_FILE="/usr/local/var/macos-service-toggle/disabled.state"
LOGFILE="/usr/local/var/macos-service-toggle/reassert.log"
mkdir -p "$(dirname "$LOGFILE")"

if [[ ! -f "$STATE_FILE" ]]; then
  {
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z')  no state file — nothing to reassert, exiting."
  } >> "$LOGFILE"
  exit 0
fi

{
  echo "===================================================================="
  echo "REASSERT run: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Boot time: $(sysctl -n kern.boottime)"
  echo "State file: $STATE_FILE"
  echo "--------------------------------------------------------------------"

  # Split state entries into system-domain (act now) and session-domain
  # (need a real console user first). bash 3.2 safe — no mapfile.
  SYSTEM_LINES=()
  SESSION_LINES=()
  while IFS='|' read -r svc domain desc || [ -n "$svc" ]; do
    [ -z "$svc" ] && continue
    if [[ "$domain" == "system" ]]; then
      SYSTEM_LINES+=("$svc|$domain|$desc")
    else
      SESSION_LINES+=("$svc|$domain|$desc")
    fi
  done < "$STATE_FILE"

  echo "-- system domain (${#SYSTEM_LINES[@]} entries, immediate) --"
  for line in "${SYSTEM_LINES[@]}"; do
    IFS='|' read -r svc domain desc <<< "$line"
    if launchctl disable "system/$svc" 2>>"$LOGFILE"; then
      echo "  [OK] $svc ($desc)"
    else
      echo "  [FAILED] $svc ($desc)"
    fi
  done

  if [ "${#SESSION_LINES[@]}" -eq 0 ]; then
    echo "-- no gui/user-domain entries to reassert --"
  else
    echo "-- waiting for a REAL console user session (up to 120s) --"
    CONSOLE_USER=""
    CONSOLE_UID=""
    for i in $(seq 1 120); do
      _cu="$(stat -f%Su /dev/console 2>/dev/null)"
      if [[ -n "$_cu" && "$_cu" != "root" ]]; then
        _uid="$(id -u "$_cu" 2>/dev/null)"
        if [[ -n "$_uid" ]] && [ "$_uid" -ge 500 ]; then
          CONSOLE_USER="$_cu"
          CONSOLE_UID="$_uid"
          echo "  real console user found after ${i}s: $CONSOLE_USER (uid $CONSOLE_UID)"
          break
        fi
      fi
      sleep 1
    done

    if [[ -n "$CONSOLE_USER" ]]; then
      echo "-- session-domain (${#SESSION_LINES[@]} entries, re-targeted to gui/$CONSOLE_UID) --"
      for line in "${SESSION_LINES[@]}"; do
        IFS='|' read -r svc domain desc <<< "$line"
        # Re-target to the CURRENT console uid, not whatever uid was
        # recorded in the state file at disable-time — they may differ.
        if [[ "$domain" == user/* ]]; then
          target_domain="user/$CONSOLE_UID"
        else
          target_domain="gui/$CONSOLE_UID"
        fi
        if sudo -u "$CONSOLE_USER" launchctl disable "$target_domain/$svc" 2>>"$LOGFILE"; then
          echo "  [OK] $svc ($desc) [$target_domain]"
        else
          echo "  [FAILED] $svc ($desc) [$target_domain]"
        fi
      done
    else
      echo "  no real console user session appeared within 120s — session-domain entries skipped"
    fi
  fi

  echo "REASSERT run finished: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "===================================================================="
  echo
} >> "$LOGFILE"
