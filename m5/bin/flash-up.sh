#!/usr/bin/env bash
# flash-up.sh — start LM Studio's server, load the router + Flash-Next workhorse, then start Open WebUI.
# Run: ~/bin/flash-up.sh   (prompts for your password once, for launchctl)
set -euo pipefail
echo "$(date '+%F %T') flash-up start"
set +eu
source "$HOME/ZuulRulez/m5/scripts/raid-guard.sh"
set -eu
echo "$(date '+%F %T') raid guard done (rc=${RAID_GUARD_RC:-n/a})"

# ---------- CONFIG ----------
LMS="${LMS:-$HOME/.lmstudio/bin/lms}"   # LM Studio CLI
PORT="${PORT:-1234}"

# Model keys exactly as shown by `lms ls`
FLASH_KEY="${FLASH_KEY:-qwen3.8-flash-next-ad-4.27bpw-m64}"
ROUTER_KEY="${ROUTER_KEY:-gemma-4-26b-a4b-it-qat}"

# Stable API identifier for Flash so Open WebUI always sees the same model ID.
FLASH_ID="${FLASH_ID:-flash-next}"
# Leave ROUTER_ID empty to keep the router's current ID (so existing Open WebUI models keep working).
ROUTER_ID="${ROUTER_ID:-}"

FLASH_CTX="${FLASH_CTX:-32768}"
ROUTER_CTX="${ROUTER_CTX:-32768}"

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
[[ -x "$LMS" ]] || die "lms CLI not found at $LMS (run LM Studio once, or set LMS=)"

echo "→ Starting LM Studio server on :$PORT"
"$LMS" server start --port "$PORT"

echo "→ Clearing any loaded models"
"$LMS" unload --all || true

echo "→ Loading router: $ROUTER_KEY"
router_args=(load "$ROUTER_KEY" --gpu max --context-length "$ROUTER_CTX" -y)
[[ -n "$ROUTER_ID" ]] && router_args+=(--identifier "$ROUTER_ID")
load_retry "${router_args[@]}" || die "could not load $ROUTER_KEY"

echo "→ Loading workhorse: $FLASH_KEY as '$FLASH_ID'"
load_retry load "$FLASH_KEY" --gpu max --context-length "$FLASH_CTX" \
  --identifier "$FLASH_ID" -y || die "could not load $FLASH_KEY"

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
ids="$(curl -fsS "http://localhost:$PORT/v1/models" 2>/dev/null || true)"
for want in "$FLASH_ID" "${ROUTER_ID:-$ROUTER_KEY}"; do
  grep -q "\"$want\"" <<<"$ids" || die "$want is not being served after load (check: $LMS ps)"
done
echo "  ok"

echo "→ Loaded models:"
"$LMS" ps
echo "→ API model IDs:"
curl -fsS "http://localhost:$PORT/v1/models" | grep -o '"id": *"[^"]*"' || true
top -l 1 -s 0 | grep PhysMem || true
