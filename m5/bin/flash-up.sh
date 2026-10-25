#!/usr/bin/env bash
# flash-up.sh — start LM Studio's server and load the Gemma router, bring up the Flash-Next
# workhorse, then start Open WebUI.
#   FLASH_BACKEND=mlx  (default) Flash-Next runs in mlx-serve (LaunchAgent com.$USER.mlx-serve,
#                      127.0.0.1:11234); LM Studio serves Gemma only.
#   FLASH_BACKEND=gguf Flash-Next GGUF loaded in LM Studio (rollback); the mlx-serve agent is stopped.
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
LMS="${LMS:-$HOME/.lmstudio/bin/lms}"   # LM Studio CLI
PORT="${PORT:-1234}"

FLASH_BACKEND="${FLASH_BACKEND:-mlx}"

# Model keys exactly as shown by `lms ls`
FLASH_KEY="${FLASH_KEY:-qwen3.8-flash-next-ad-4.27bpw-m64}"
ROUTER_KEY="${ROUTER_KEY:-gemma-4-26b-a4b-it-qat}"

# Stable API identifier for Flash so Open WebUI always sees the same model ID (both backends).
FLASH_ID="${FLASH_ID:-flash-next}"
# Leave ROUTER_ID empty to keep the router's current ID (so existing Open WebUI models keep working).
ROUTER_ID="${ROUTER_ID:-}"

FLASH_CTX="${FLASH_CTX:-131072}"
ROUTER_CTX="${ROUTER_CTX:-32768}"

# mlx-serve LaunchAgent (rendered by ./install.sh --apply --launchd)
MLX_LABEL="${MLX_LABEL:-com.$USER.mlx-serve}"
MLX_PLIST="${MLX_PLIST:-$HOME/Library/LaunchAgents/$MLX_LABEL.plist}"
MLX_URL="${MLX_URL:-http://127.0.0.1:11234}"
MLX_WAIT="${MLX_WAIT:-180}"   # seconds to wait for the model to load

# Open WebUI launchd daemon. Set OWUI_LABEL="" to skip starting it.
OWUI_LABEL="${OWUI_LABEL-com.openwebui.serve}"
OWUI_PLIST="${OWUI_PLIST:-/Library/LaunchDaemons/com.openwebui.serve.plist}"
OWUI_URL="${OWUI_URL:-http://localhost:8080}"   # match the port in your plist
# ----------------------------

die() { echo "error: $*" >&2; exit 1; }

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

mlx_loaded() { launchctl print "gui/$UID/$MLX_LABEL" >/dev/null 2>&1; }

[[ -x "$LMS" ]] || die "lms CLI not found at $LMS (run LM Studio once, or set LMS=)"
case "$FLASH_BACKEND" in mlx|gguf) ;; *) die "FLASH_BACKEND must be mlx or gguf (got '$FLASH_BACKEND')";; esac
echo "→ Flash backend: $FLASH_BACKEND"

# The two Flash copies must never be resident together.
if [[ "$FLASH_BACKEND" == gguf ]] && mlx_loaded; then
  echo "→ Stopping mlx-serve ($MLX_LABEL) for the GGUF backend"
  launchctl bootout "gui/$UID/$MLX_LABEL" || true
  sleep 5
fi

echo "→ Starting LM Studio server on :$PORT"
"$LMS" server start --port "$PORT"

echo "→ Clearing any loaded models"
"$LMS" unload --all || true

echo "→ Loading router: $ROUTER_KEY"
router_args=(load "$ROUTER_KEY" --gpu max --context-length "$ROUTER_CTX" -y)
[[ -n "$ROUTER_ID" ]] && router_args+=(--identifier "$ROUTER_ID")
load_retry "${router_args[@]}" || die "could not load $ROUTER_KEY"

if [[ "$FLASH_BACKEND" == gguf ]]; then
  echo "→ Loading workhorse: $FLASH_KEY as '$FLASH_ID'"
  load_retry load "$FLASH_KEY" --gpu max --context-length "$FLASH_CTX" \
    --identifier "$FLASH_ID" -y || die "could not load $FLASH_KEY"
  FLASH_API="http://localhost:$PORT"
else
  echo "→ Workhorse: mlx-serve ($MLX_LABEL)"
  if ! mlx_loaded; then
    [[ -f "$MLX_PLIST" ]] || die "$MLX_PLIST missing (run ./install.sh --apply --launchd in ~/ZuulRulez)"
    launchctl bootstrap "gui/$UID" "$MLX_PLIST"
  elif ! curl -fsS "$MLX_URL/health" >/dev/null 2>&1; then
    launchctl kickstart "gui/$UID/$MLX_LABEL" || true
  fi
  printf "→ Waiting for mlx-serve at %s " "$MLX_URL"
  ready=0
  for _ in $(seq 1 $(( MLX_WAIT / 3 ))); do
    if curl -fsS "$MLX_URL/v1/models" 2>/dev/null | grep -q "\"$FLASH_ID\""; then ready=1; break; fi
    printf "."; sleep 3
  done
  [[ $ready == 1 ]] || die "mlx-serve not serving $FLASH_ID after ${MLX_WAIT}s (log: ~/.mlx-serve/logs/mlx-serve-11234.log)"
  echo " ✓"
  # After a reboot macOS compresses the idle weights; the first request decompresses and wires them
  # (~3 s, compressor 41 GB -> 0.4 GB, wired 18 -> 88 GB on Oct 25). Pay that here, not in the first chat.
  printf "→ Warming Flash weights "
  t0=$SECONDS
  if curl -fsS -m 180 "$MLX_URL/v1/chat/completions" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$FLASH_ID\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
       >/dev/null 2>&1; then
    echo "✓ ($(( SECONDS - t0 )) s)"
  else
    echo "failed (not fatal; the first chat will be slower)"
  fi
  FLASH_API="$MLX_URL"
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
router_ids="$(curl -fsS "http://localhost:$PORT/v1/models" 2>/dev/null || true)"
grep -q "\"${ROUTER_ID:-$ROUTER_KEY}\"" <<<"$router_ids" || die "${ROUTER_ID:-$ROUTER_KEY} is not being served (check: $LMS ps)"
flash_ids="$(curl -fsS "$FLASH_API/v1/models" 2>/dev/null || true)"
grep -q "\"$FLASH_ID\"" <<<"$flash_ids" || die "$FLASH_ID is not being served at $FLASH_API"
if [[ "$FLASH_BACKEND" == mlx ]] && grep -q "\"$FLASH_ID\"" <<<"$router_ids"; then
  die "$FLASH_ID is served by LM Studio AND mlx-serve (unload it in LM Studio: $LMS unload $FLASH_ID)"
fi
echo "  ok"

echo "→ Loaded models:"
"$LMS" ps
echo "→ API model IDs:"
echo "  LM Studio ($PORT):"; grep -o '"id": *"[^"]*"' <<<"$router_ids" | sed 's/^/    /' || true
echo "  Flash ($FLASH_API):"; grep -o '"id": *"[^"]*"' <<<"$flash_ids" | sed 's/^/    /' || true
top -l 1 -s 0 | grep PhysMem || true

# Second attempt: the TB5 volume can take longer than RAID_TIMEOUT to appear after boot, and the
# models above do not depend on it. No-op if the first attempt already linked it.
echo "$(date '+%F %T') raid guard retry"
set +eu
source "$HOME/ZuulRulez/m5/scripts/raid-guard.sh"
set -eu
echo "$(date '+%F %T') raid guard retry done (rc=${RAID_GUARD_RC:-n/a})"
