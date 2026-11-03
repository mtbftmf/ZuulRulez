#!/usr/bin/env bash
# flash-up.sh — bring up both model servers, warm them, then start Open WebUI.
#   Gemma 4 (router, vision, task model) always runs in mlx-serve: LaunchAgent
#                      com.$USER.mlx-serve-gemma, 127.0.0.1:11235.
#   FLASH_BACKEND=mlx  (default) Flash-Next in mlx-serve (LaunchAgent com.$USER.mlx-serve,
#                      127.0.0.1:11234). LM Studio is not used; if its server is up, its models are
#                      unloaded and the server stopped.
#   FLASH_BACKEND=gguf Flash-Next GGUF loaded in LM Studio on :1234 (rollback); the Flash mlx-serve
#                      agent is stopped. Gemma stays in mlx-serve.
# Set FLASH_BACKEND in ~/.config/macllm.env.
# Run: ~/bin/flash-up.sh   (prompts for your password once, for launchctl)
set -euo pipefail
echo "$(date '+%F %T') flash-up start"
set +eu
source "$HOME/ZuulRulez/m5/scripts/raid-guard.sh"
_cli_backend="${FLASH_BACKEND:-}"   # a value given on the command line beats the file
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"
[[ -n "$_cli_backend" ]] && FLASH_BACKEND="$_cli_backend"
set -eu
echo "$(date '+%F %T') raid guard done (rc=${RAID_GUARD_RC:-n/a})"

# ---------- CONFIG ----------
FLASH_BACKEND="${FLASH_BACKEND:-mlx}"

# Stable API identifier for Flash so Open WebUI always sees the same model ID (both backends).
FLASH_ID="${FLASH_ID:-flash-next}"
# Gemma's ID is the name of its link in ~/.mlx-serve/models (same ID LM Studio used).
GEMMA_ID="${GEMMA_ID:-gemma-4-26b-a4b-it-qat}"

# mlx-serve LaunchAgents (rendered by ./install.sh --apply --launchd)
MLX_LABEL="${MLX_LABEL:-com.$USER.mlx-serve}"
MLX_PLIST="${MLX_PLIST:-$HOME/Library/LaunchAgents/$MLX_LABEL.plist}"
MLX_URL="${MLX_URL:-http://127.0.0.1:11234}"
MLX_WAIT="${MLX_WAIT:-180}"     # seconds to wait for Flash to load
GEMMA_LABEL="${GEMMA_LABEL:-com.$USER.mlx-serve-gemma}"
GEMMA_PLIST="${GEMMA_PLIST:-$HOME/Library/LaunchAgents/$GEMMA_LABEL.plist}"
GEMMA_URL="${GEMMA_URL:-http://127.0.0.1:11235}"
GEMMA_WAIT="${GEMMA_WAIT:-120}" # seconds to wait for Gemma to load

# LM Studio: GGUF rollback only
LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
PORT="${PORT:-1234}"
FLASH_KEY="${FLASH_KEY:-qwen3.8-flash-next-ad-4.27bpw-m64}"   # as shown by `lms ls`
FLASH_CTX="${FLASH_CTX:-131072}"
LMS_WAIT="${LMS_WAIT:-150}"     # seconds to wait for LM Studio after login

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

lms_serving() { curl -fsS -m 3 "http://localhost:$PORT/v1/models" >/dev/null 2>&1; }

# Retry a load: LM Studio can abort a load while its app is still finishing startup.
load_retry() {
  local attempt
  for attempt in 1 2 3; do
    "$LMS" "$@" && return 0
    echo "  load failed (attempt $attempt of 3); retrying in 15 s"
    sleep 15
  done
  return 1
}

case "$FLASH_BACKEND" in mlx|gguf) ;; *) die "FLASH_BACKEND must be mlx or gguf (got '$FLASH_BACKEND')";; esac
echo "→ Flash backend: $FLASH_BACKEND"

# The two Flash copies must never be resident together.
if [[ "$FLASH_BACKEND" == gguf ]] && agent_loaded "$MLX_LABEL"; then
  echo "→ Stopping Flash mlx-serve ($MLX_LABEL) for the GGUF backend"
  launchctl bootout "gui/$UID/$MLX_LABEL" || true
  sleep 5
fi

echo "→ Gemma: mlx-serve ($GEMMA_LABEL)"
start_agent "$GEMMA_LABEL" "$GEMMA_PLIST" "$GEMMA_URL"

if [[ "$FLASH_BACKEND" == gguf ]]; then
  [[ -x "$LMS" ]] || die "lms CLI not found at $LMS (run LM Studio once, or set LMS=)"
  printf "→ Waiting for LM Studio "
  for _ in $(seq 1 $(( LMS_WAIT / 5 ))); do "$LMS" ps >/dev/null 2>&1 && break; printf "."; sleep 5; done
  echo
  echo "→ Starting LM Studio server on :$PORT"
  "$LMS" server start --port "$PORT"
  echo "→ Clearing any loaded LM Studio models"
  "$LMS" unload --all || true
  echo "→ Loading workhorse: $FLASH_KEY as '$FLASH_ID'"
  load_retry load "$FLASH_KEY" --gpu max --context-length "$FLASH_CTX" \
    --identifier "$FLASH_ID" -y || die "could not load $FLASH_KEY"
  FLASH_API="http://localhost:$PORT"
else
  # Only touch LM Studio if its server is already up: running lms can start LM Studio's service.
  if lms_serving && [[ -x "$LMS" ]]; then
    echo "→ LM Studio server is up: unloading its models and stopping it (not used with mlx)"
    "$LMS" unload --all || true
    "$LMS" server stop || true
  fi
  echo "→ Flash: mlx-serve ($MLX_LABEL)"
  start_agent "$MLX_LABEL" "$MLX_PLIST" "$MLX_URL"
  FLASH_API="$MLX_URL"
fi

wait_model "$GEMMA_URL" "$GEMMA_ID" "$GEMMA_WAIT"
warm "$GEMMA_URL" "$GEMMA_ID"
if [[ "$FLASH_BACKEND" == mlx ]]; then
  wait_model "$MLX_URL" "$FLASH_ID" "$MLX_WAIT"
  warm "$MLX_URL" "$FLASH_ID"
fi

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
flash_ids="$(curl -fsS "$FLASH_API/v1/models" 2>/dev/null || true)"
grep -q "\"$FLASH_ID\"" <<<"$flash_ids" || die "$FLASH_ID is not being served at $FLASH_API"
if [[ "$FLASH_BACKEND" == mlx ]] && lms_serving; then
  die "LM Studio's server is still up on :$PORT (stop it: $LMS server stop)"
fi
echo "  ok"

echo "→ API model IDs:"
echo "  Gemma ($GEMMA_URL):"; grep -o '"id": *"[^"]*"' <<<"$gemma_ids" | sed 's/^/    /' || true
echo "  Flash ($FLASH_API):"; grep -o '"id": *"[^"]*"' <<<"$flash_ids" | sed 's/^/    /' || true
[[ "$FLASH_BACKEND" == gguf ]] && { echo "→ LM Studio:"; "$LMS" ps; }
top -l 1 -s 0 | grep PhysMem || true

# Second attempt: the TB5 volume can take longer than RAID_TIMEOUT to appear after boot, and the
# models above do not depend on it. No-op if the first attempt already linked it.
echo "$(date '+%F %T') raid guard retry"
set +eu
source "$HOME/ZuulRulez/m5/scripts/raid-guard.sh"
set -eu
echo "$(date '+%F %T') raid guard retry done (rc=${RAID_GUARD_RC:-n/a})"
