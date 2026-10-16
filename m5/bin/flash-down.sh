#!/usr/bin/env bash
# flash-down.sh — stop Open WebUI, unload all models, stop LM Studio's server.
# Run: ~/bin/flash-down.sh            (STOP_OWUI=0 to leave Open WebUI running)
set -euo pipefail

LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
OWUI_LABEL="${OWUI_LABEL:-com.openwebui.serve}"
STOP_OWUI="${STOP_OWUI:-1}"

# Stop Open WebUI first so nothing sends requests to models as they unload.
if [[ "$STOP_OWUI" == 1 && -n "$OWUI_LABEL" ]]; then
  if sudo launchctl print "system/$OWUI_LABEL" >/dev/null 2>&1; then
    echo "→ Stopping Open WebUI ($OWUI_LABEL)"
    sudo launchctl bootout "system/$OWUI_LABEL" || true
  else
    echo "→ Open WebUI not running"
  fi
fi

echo "→ Unloading all models"
"$LMS" unload --all || true

echo "→ Stopping LM Studio server"
"$LMS" server stop || true

echo "→ Done."
top -l 1 -s 0 | grep PhysMem || true
