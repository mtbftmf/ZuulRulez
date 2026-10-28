#!/usr/bin/env bash
# gemma-down.sh — stop Open WebUI, unload models, stop LM Studio's server.
# STOP_OWUI=0 ~/bin/gemma-down.sh   leaves Open WebUI running.
set -euo pipefail

LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
OWUI_LABEL="${OWUI_LABEL:-com.openwebui.serve}"
STOP_OWUI="${STOP_OWUI:-1}"

if [[ "$STOP_OWUI" == 1 ]] && sudo launchctl print "system/$OWUI_LABEL" >/dev/null 2>&1; then
  echo "→ Stopping Open WebUI"
  sudo launchctl bootout "system/$OWUI_LABEL" || true
fi

echo "→ Unloading models"
"$LMS" unload --all || true
echo "→ Stopping LM Studio server"
"$LMS" server stop || true

top -l 1 -s 0 | grep PhysMem || true
