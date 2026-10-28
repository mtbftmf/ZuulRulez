#!/usr/bin/env bash
# gemma-up.sh — make sure the model server (com.gemma.llm) and Open WebUI (com.openwebui.serve)
# are running and answering. Both are LaunchDaemons that start at boot, so this is only needed
# after gemma-down.sh, after changing ~/.config/gemma.env (RESTART=1), or to check.
#   ~/bin/gemma-up.sh               start whatever is stopped, wait until both answer
#   RESTART=1 ~/bin/gemma-up.sh     restart the model server (picks up gemma.env changes)
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=gemma-env.sh
source "$HERE/gemma-env.sh"
OWUI_LABEL="${OWUI_LABEL-$OWUI_LABEL_DEFAULT}"
OWUI_PLIST="${OWUI_PLIST:-$OWUI_PLIST_DEFAULT}"
OWUI_URL="${OWUI_URL:-http://localhost:$OWUI_PORT}"
LLM_WAIT="${LLM_WAIT:-300}"

loaded() { sudo launchctl print "system/$1" >/dev/null 2>&1; }
start()  {  # $1 label, $2 plist
  if loaded "$1"; then return 0; fi
  [[ -f "$2" ]] || { echo "error: $2 missing — run install-gemma-stack.sh" >&2; exit 1; }
  sudo launchctl bootstrap system "$2"
}

echo "$(date '+%F %T') gemma-up: engine $ENGINE, model $MODEL_ID"
sudo -v
if [[ "${RESTART:-0}" == 1 ]] && loaded "$LLM_LABEL"; then
  echo "→ Restarting model server"
  sudo launchctl kickstart -k "system/$LLM_LABEL"
else
  start "$LLM_LABEL" "$LLM_PLIST"
fi

printf "→ Waiting for %s on localhost:%s (up to %ss) " "$MODEL_ID" "$PORT" "$LLM_WAIT"
ok=0
for _ in $(seq 1 $((LLM_WAIT / 3))); do
  if curl -fs "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -qF "\"$MODEL_ID\""; then ok=1; break; fi
  printf "."; sleep 3
done
echo
[[ $ok == 1 ]] || { echo "error: model server not ready — tail -50 $LLM_LOG" >&2; exit 1; }

if [[ "$ENGINE" == mlx ]]; then
  printf "→ Warming %s " "$MODEL_ID"   # mlx-vlm loads weights on the first request
  t0=$(date +%s)
  curl -fs -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" >/dev/null \
    && echo "✓ ($(( $(date +%s) - t0 )) s)" || echo "failed (first chat will be slow)"
fi
echo "→ Model server ready ✓"

if [[ -n "$OWUI_LABEL" ]]; then
  start "$OWUI_LABEL" "$OWUI_PLIST"
  printf "→ Waiting for %s " "$OWUI_URL"
  ok=0
  for _ in $(seq 1 60); do
    if curl -fs "$OWUI_URL/health" >/dev/null 2>&1; then ok=1; break; fi
    printf "."; sleep 2
  done
  [[ $ok == 1 ]] && echo " ✓" || echo " not responding after 2 min (check ~/Library/Logs/open-webui.log)"
fi

top -l 1 -s 0 | grep PhysMem || true
