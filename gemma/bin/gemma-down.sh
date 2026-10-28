#!/usr/bin/env bash
# gemma-down.sh — stop Open WebUI and the model server (frees the model's memory).
# They stay stopped until gemma-up.sh or the next boot.
#   STOP_OWUI=0 ~/bin/gemma-down.sh   stop only the model server
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=gemma-env.sh
source "$HERE/gemma-env.sh"
OWUI_LABEL="${OWUI_LABEL:-$OWUI_LABEL_DEFAULT}"
STOP_OWUI="${STOP_OWUI:-1}"

stop() {
  if sudo launchctl print "system/$1" >/dev/null 2>&1; then
    echo "→ Stopping $1"
    sudo launchctl bootout "system/$1" || true
    for _ in $(seq 1 30); do sudo launchctl print "system/$1" >/dev/null 2>&1 || break; sleep 1; done
  fi
}

sudo -v
[[ "$STOP_OWUI" == 1 ]] && stop "$OWUI_LABEL"
stop "$LLM_LABEL"
top -l 1 -s 0 | grep PhysMem || true
