#!/usr/bin/env bash
# raid-guard.sh - SOURCE this from flash-up.sh (bash or zsh); do not execute it.
#   source "$HOME/ZuulRulez/m5/scripts/raid-guard.sh" || true
# Mounts the external RAID0 volume (if enabled) and exposes it to LM Studio as an
# extra model folder: ~/.lmstudio/models/<RAID_LINK_NAME> -> /Volumes/<RAID_VOL>/models
# Flash, Gemma, the LM Studio config and the Open WebUI DB stay on internal storage;
# this script never touches them. If the volume is missing, the link is removed so
# LM Studio never sees a dangling path.
# After sourcing, RAID_GUARD_RC holds the result; sourcing itself always succeeds.
# Settings come from ~/.config/lmstudio-raid.env (not committed). Default: disabled.

_raid_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _raid_sourced=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then _raid_sourced=1; fi
fi
if [ "$_raid_sourced" != 1 ]; then
  echo "raid-guard.sh must be sourced, not executed" >&2
  exit 1
fi
unset _raid_sourced

raid_guard() {
  local env_file="${RAID_ENV_FILE:-$HOME/.config/lmstudio-raid.env}"
  if [ -f "$env_file" ]; then . "$env_file"; fi

  local enabled="${RAID_ENABLED:-0}"
  local vol="${RAID_VOL:-TB5KinstonRAID0}"
  local uuid="${RAID_UUID:-}"
  local timeout="${RAID_TIMEOUT:-60}"
  local lm_dir="${LM_DIR:-$HOME/.lmstudio}"
  local link="$lm_dir/models/${RAID_LINK_NAME:-raid-archive}"
  local mnt="${RAID_MOUNT_ROOT:-/Volumes}/$vol"
  local waited=0 dev=""

  _raid_drop_link() { if [ -L "$link" ]; then rm -f "$link"; fi; return 0; }
  _raid_notify() {
    /usr/bin/osascript -e "display notification \"$1\" with title \"LM Studio\"" >/dev/null 2>&1 || true
  }
  _raid_mounted() { local m; m="$(mount)"; [[ "$m" == *" on ${mnt} ("* ]]; }
  _raid_device() {
    # Prefer a stable UUID; otherwise find the volume by name (identifiers like disk5 change).
    if [ -n "$uuid" ]; then printf '%s\n' "$uuid"; return 0; fi
    diskutil list 2>/dev/null | awk -v v="$vol" '!d && index($0, v) { print $NF; d=1 }'
  }

  if [ "$enabled" != "1" ]; then
    _raid_drop_link
    return 0
  fi

  until _raid_mounted; do
    if [ "$waited" -ge "$timeout" ]; then break; fi
    dev="$(_raid_device || true)"
    if [ -n "$dev" ]; then diskutil mount "$dev" >/dev/null 2>&1 || true; fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  if _raid_mounted && touch "$mnt/.probe" 2>/dev/null; then
    rm -f "$mnt/.probe"
    mkdir -p "$mnt/models" "$mnt/scratch" "$mnt/tmp"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "WARN: $link exists and is not a symlink; leaving it alone" >&2
      return 1
    fi
    ln -sfn "$mnt/models" "$link"
    export RAID_SCRATCH="$mnt/scratch"
    return 0
  fi

  _raid_drop_link
  unset RAID_SCRATCH
  _raid_notify "Array unavailable - extra models offline; Flash and Gemma unaffected"
  echo "WARN: $vol unavailable after ${timeout}s; extra models offline" >&2
  return 1
}

# Always return 0 when sourced; the outcome is in RAID_GUARD_RC (0 = volume up or disabled, 1 = unavailable).
raid_guard
RAID_GUARD_RC=$?
