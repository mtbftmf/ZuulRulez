#!/usr/bin/env bash
# flash-down.sh — stop Open WebUI, stop both mlx-serve agents (Flash and Gemma), and unload and stop
# LM Studio if its server is up (GGUF rollback).
# Run: ~/bin/flash-down.sh            (STOP_OWUI=0 leaves Open WebUI running,
#                                      STOP_MLX=0 leaves Flash's mlx-serve running,
#                                      STOP_GEMMA=0 leaves Gemma's mlx-serve running)
set -euo pipefail

LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
PORT="${PORT:-1234}"
OWUI_LABEL="${OWUI_LABEL:-com.openwebui.serve}"
STOP_OWUI="${STOP_OWUI:-1}"
MLX_LABEL="${MLX_LABEL:-com.$USER.mlx-serve}"
STOP_MLX="${STOP_MLX:-1}"
GEMMA_LABEL="${GEMMA_LABEL:-com.$USER.mlx-serve-gemma}"
STOP_GEMMA="${STOP_GEMMA:-1}"

# Stop Open WebUI first so nothing sends requests to models as they unload.
if [[ "$STOP_OWUI" == 1 && -n "$OWUI_LABEL" ]]; then
  if sudo launchctl print "system/$OWUI_LABEL" >/dev/null 2>&1; then
    echo "→ Stopping Open WebUI ($OWUI_LABEL)"
    sudo launchctl bootout "system/$OWUI_LABEL" || true
  else
    echo "→ Open WebUI not running"
  fi
fi

# KeepAlive restarts mlx-serve if it is only killed, so take the agents out of launchd.
# flash-up.sh puts them back.
stop_agent() {
  if launchctl print "gui/$UID/$1" >/dev/null 2>&1; then
    echo "→ Stopping $2 ($1)"
    launchctl bootout "gui/$UID/$1" || true
  else
    echo "→ $2 not running"
  fi
}
[[ "$STOP_MLX" == 1 ]] && stop_agent "$MLX_LABEL" "Flash mlx-serve"
[[ "$STOP_GEMMA" == 1 ]] && stop_agent "$GEMMA_LABEL" "Gemma mlx-serve"

# Only touch LM Studio if its server is up: running lms can start LM Studio's service.
if curl -fsS -m 3 "http://localhost:$PORT/v1/models" >/dev/null 2>&1 && [[ -x "$LMS" ]]; then
  echo "→ Unloading LM Studio models"
  "$LMS" unload --all || true
  echo "→ Stopping LM Studio server"
  "$LMS" server stop || true
else
  echo "→ LM Studio server not running"
fi

echo "→ Done."
top -l 1 -s 0 | grep PhysMem || true
