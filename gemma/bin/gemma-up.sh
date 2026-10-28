#!/usr/bin/env bash
# gemma-up.sh — start LM Studio's server (localhost only), load Gemma 4, start Open WebUI.
# Host values (MODEL_KEY, CTX, PORT) come from ~/.config/gemma.env; a value on the command line wins.
set -euo pipefail

_cli_ctx="${CTX:-}"; _cli_key="${MODEL_KEY:-}"
# shellcheck disable=SC1091
[[ -f "$HOME/.config/gemma.env" ]] && source "$HOME/.config/gemma.env"
[[ -n "$_cli_ctx" ]] && CTX="$_cli_ctx"
[[ -n "$_cli_key" ]] && MODEL_KEY="$_cli_key"
echo "$(date '+%F %T') gemma-up start"

LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
PORT="${PORT:-1234}"
MODEL_KEY="${MODEL_KEY:-gemma-4-26b-a4b-it-qat}"
CTX="${CTX:-16384}"
OWUI_LABEL="${OWUI_LABEL-com.openwebui.serve}"
OWUI_PLIST="${OWUI_PLIST:-/Library/LaunchDaemons/com.openwebui.serve.plist}"
OWUI_URL="${OWUI_URL:-http://localhost:${OWUI_PORT:-8080}}"

die() { echo "error: $*" >&2; exit 1; }
[[ -x "$LMS" ]] || die "lms CLI not found at $LMS (open LM Studio once)"

echo "→ Starting LM Studio server on localhost:$PORT"
"$LMS" server start --port "$PORT"

echo "→ Loading $MODEL_KEY (context $CTX)"
"$LMS" unload --all || true
"$LMS" load "$MODEL_KEY" --gpu max --context-length "$CTX" -y

if [[ -n "$OWUI_LABEL" ]]; then
  if sudo launchctl print "system/$OWUI_LABEL" >/dev/null 2>&1; then
    echo "→ Open WebUI already running"
  else
    echo "→ Starting Open WebUI"
    sudo launchctl bootstrap system "$OWUI_PLIST"
  fi
  printf "→ Waiting for %s " "$OWUI_URL"
  ok=0
  for _ in $(seq 1 60); do
    if curl -fs "$OWUI_URL/health" >/dev/null 2>&1; then ok=1; break; fi
    printf "."; sleep 2
  done
  [[ $ok == 1 ]] && echo " ✓" || echo " not responding after 2 min (check ~/Library/Logs/open-webui.log)"
fi

"$LMS" ps
top -l 1 -s 0 | grep PhysMem || true
