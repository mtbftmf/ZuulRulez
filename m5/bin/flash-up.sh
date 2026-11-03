#!/usr/bin/env bash
# flash-up.sh — bring up both model servers, warm them, then start Open WebUI.
#   Flash-Next (workhorse): mlx-serve, LaunchAgent com.$USER.mlx-serve, 127.0.0.1:11234
#   Gemma 4 (router, vision, task model): mlx-serve, LaunchAgent com.$USER.mlx-serve-gemma, 127.0.0.1:11235
# Both agents have RunAtLoad and KeepAlive; this script (re)loads them if needed, waits until each
# serves its model, warms it, and checks the result. Overrides go in ~/.config/macllm.env.
# Run: ~/bin/flash-up.sh   (prompts for your password once, for launchctl)
set -euo pipefail
echo "$(date '+%F %T') flash-up start"
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"

# ---------- CONFIG ----------
FLASH_ID="${FLASH_ID:-flash-next}"
GEMMA_ID="${GEMMA_ID:-gemma-4-26b-a4b-it-qat}"   # name of its link in ~/.mlx-serve/models

# mlx-serve LaunchAgents (rendered by ./install.sh --apply --launchd)
MLX_LABEL="${MLX_LABEL:-com.$USER.mlx-serve}"
MLX_PLIST="${MLX_PLIST:-$HOME/Library/LaunchAgents/$MLX_LABEL.plist}"
MLX_URL="${MLX_URL:-http://127.0.0.1:11234}"
MLX_WAIT="${MLX_WAIT:-180}"     # seconds to wait for Flash to load
GEMMA_LABEL="${GEMMA_LABEL:-com.$USER.mlx-serve-gemma}"
GEMMA_PLIST="${GEMMA_PLIST:-$HOME/Library/LaunchAgents/$GEMMA_LABEL.plist}"
GEMMA_URL="${GEMMA_URL:-http://127.0.0.1:11235}"
GEMMA_WAIT="${GEMMA_WAIT:-120}" # seconds to wait for Gemma to load

# Open WebUI launchd daemon. Set OWUI_LABEL="" to skip starting it.
OWUI_LABEL="${OWUI_LABEL-com.openwebui.serve}"
OWUI_PLIST="${OWUI_PLIST:-/Library/LaunchDaemons/com.openwebui.serve.plist}"
OWUI_URL="${OWUI_URL:-http://localhost:8080}"   # match the port in your plist
# ----------------------------

die() { echo "error: $*" >&2; exit 1; }

agent_loaded() { launchctl print "gui/$UID/$1" >/dev/null 2>&1; }

# start_agent LABEL PLIST URL: load the agent, or restart it if it is loaded but not answering.
start_agent() {
  if ! agent_loaded "$1"; then
    [[ -f "$2" ]] || die "$2 missing (run ./install.sh --apply --launchd in ~/ZuulRulez)"
    launchctl bootstrap "gui/$UID" "$2"
  elif ! curl -fsS -m 5 "$3/health" >/dev/null 2>&1; then
    launchctl kickstart "gui/$UID/$1" || true
  fi
}

# wait_model URL ID SECONDS
wait_model() {
  printf "→ Waiting for %s at %s " "$2" "$1"
  for _ in $(seq 1 $(( $3 / 3 ))); do
    if curl -fsS -m 5 "$1/v1/models" 2>/dev/null | grep -q "\"$2\""; then echo " ✓"; return 0; fi
    printf "."; sleep 3
  done
  echo
  die "$2 not served at $1 after ${3}s (log: ~/.mlx-serve/logs/mlx-serve-${1##*:}.log)"
}

# warm URL ID: after a reboot macOS compresses idle weights; the first request decompresses and
# wires them (Flash ~3-4 s on Oct 25). Pay that here, not in the first chat.
warm() {
  printf "→ Warming %s " "$2"
  local t0=$SECONDS
  if curl -fsS -m 180 "$1/v1/chat/completions" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$2\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
       >/dev/null 2>&1; then
    echo "✓ ($(( SECONDS - t0 )) s)"
  else
    echo "failed (not fatal; the first chat will be slower)"
  fi
}

echo "→ Gemma: mlx-serve ($GEMMA_LABEL)"
start_agent "$GEMMA_LABEL" "$GEMMA_PLIST" "$GEMMA_URL"
echo "→ Flash: mlx-serve ($MLX_LABEL)"
start_agent "$MLX_LABEL" "$MLX_PLIST" "$MLX_URL"

wait_model "$GEMMA_URL" "$GEMMA_ID" "$GEMMA_WAIT"
warm "$GEMMA_URL" "$GEMMA_ID"
wait_model "$MLX_URL" "$FLASH_ID" "$MLX_WAIT"
warm "$MLX_URL" "$FLASH_ID"

# Start Open WebUI after the models are up, so it sees them on first model refresh.
if [[ -n "$OWUI_LABEL" ]]; then
  # Without a terminal (LaunchAgent at login) sudo cannot prompt; the daemon starts itself at boot (RunAtLoad).
  if [[ ! -t 0 ]] || sudo launchctl print "system/$OWUI_LABEL" >/dev/null 2>&1; then
    echo "→ Open WebUI already running ($OWUI_LABEL)"
  else
    echo "→ Starting Open WebUI ($OWUI_LABEL)"
    sudo launchctl bootstrap system "$OWUI_PLIST"
  fi
  printf "→ Waiting for Open WebUI at %s " "$OWUI_URL"
  ready=0
  for _ in $(seq 1 60); do
    if curl -fsS "$OWUI_URL/health" >/dev/null 2>&1; then ready=1; break; fi
    printf "."; sleep 2
  done
  if [[ $ready == 1 ]]; then echo " ✓"; else echo " not responding after 2 min (check OWUI_URL / port in plist)"; fi
fi

echo "→ Verifying both models are served"
gemma_ids="$(curl -fsS "$GEMMA_URL/v1/models" 2>/dev/null || true)"
grep -q "\"$GEMMA_ID\"" <<<"$gemma_ids" || die "$GEMMA_ID is not being served at $GEMMA_URL"
flash_ids="$(curl -fsS "$MLX_URL/v1/models" 2>/dev/null || true)"
grep -q "\"$FLASH_ID\"" <<<"$flash_ids" || die "$FLASH_ID is not being served at $MLX_URL"
echo "  ok"

echo "→ API model IDs:"
echo "  Gemma ($GEMMA_URL):"; grep -o '"id": *"[^"]*"' <<<"$gemma_ids" | sed 's/^/    /' || true
echo "  Flash ($MLX_URL):"; grep -o '"id": *"[^"]*"' <<<"$flash_ids" | sed 's/^/    /' || true
top -l 1 -s 0 | grep PhysMem || true
echo "$(date '+%F %T') flash-up done"
