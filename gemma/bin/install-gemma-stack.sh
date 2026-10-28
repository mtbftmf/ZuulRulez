#!/usr/bin/env bash
# install-gemma-stack.sh — generic Gemma 4 build for an Apple Silicon Mac Studio (32 GB or more):
#   LM Studio + Gemma 4 26B-A4B (QAT) + Open WebUI (Python 3.11 venv, launchd daemon on :8080).
# Generic builds run under the macOS admin account "houdini" and host Open WebUI for friends and
# family on the LAN. Nothing from the M5 Max (Flash-Next, mlx-serve, Auto Router, Caddy, RAID,
# service toggles, RemoveMacAI) is installed here.
#
# Run from the repo clone (made by gemma/rebuild/30-bootstrap.sh):
#   ~/ZuulRulez/gemma/bin/install-gemma-stack.sh
# Safe to re-run: every step checks before it changes anything.
# Host values come from ~/.config/gemma.env (created on first run from gemma/config/gemma.env.example).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ENV_FILE="$HOME/.config/gemma.env"
ENV_EXAMPLE="$REPO/gemma/config/gemma.env.example"

MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))

# Context default from installed memory (Gemma 4 26B-A4B QAT weights ~14-16 GB):
#   32 GB → 16384 (macOS lets the GPU wire roughly 21-24 GB), 48 GB and up → 32768.
default_ctx() { if (( MEM_GB >= 48 )); then echo 32768; else echo 16384; fi; }

if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  sed "s/^CTX=.*/CTX=$(default_ctx)/" "$ENV_EXAMPLE" > "$ENV_FILE"
  echo "Created $ENV_FILE (CTX=$(default_ctx) for ${MEM_GB} GB)."
fi
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

MODEL_REPO="${MODEL_REPO:-lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF}"
MODEL_QUANT="${MODEL_QUANT:-Q4_0}"
MODEL_KEY="${MODEL_KEY:-gemma-4-26b-a4b-it-qat}"
CTX="${CTX:-$(default_ctx)}"
OWUI_PORT="${OWUI_PORT:-8080}"
VENV="$HOME/open-webui-venv"
DATA_DIR="$HOME/open-webui-data"
LABEL="com.openwebui.serve"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LMS="$HOME/.lmstudio/bin/lms"
BIN="$HOME/bin"
LOG="$HOME/Library/Logs/open-webui.log"
AGENT_LABEL="com.$USER.gemma-up"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
HANDOFF="$HOME/ai-handoff"
LMS_WAIT="${LMS_WAIT:-900}"   # seconds to wait for LM Studio's first-run screens

# Scripts linked into ~/bin: the gemma/bin set plus two shared tools from m5/bin.
LINKS=(
  "$REPO/gemma/bin/gemma-up.sh"
  "$REPO/gemma/bin/gemma-down.sh"
  "$REPO/m5/bin/owui-upgrade.sh"
  "$REPO/m5/bin/llm-bench.py"
)

step() { printf '\n== %s ==\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

write_plist() {  # $1 = secret key; prints the plist to stdout
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$USER</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV/bin/open-webui</string>
    <string>serve</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>$OWUI_PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$VENV/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>DATA_DIR</key><string>$DATA_DIR</string>
    <key>WEBUI_SECRET_KEY</key><string>$1</string>
    <key>ENABLE_OLLAMA_API</key><string>false</string>
    <key>OPENAI_API_BASE_URL</key><string>http://localhost:1234/v1</string>
    <key>OPENAI_API_KEY</key><string>lm-studio</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
}

write_agent() {  # LaunchAgent: load Gemma at every login (Open WebUI already starts at boot)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-c</string>
    <string>for i in {1..30}; do $LMS ps >/dev/null 2>&amp;1 &amp;&amp; break; sleep 5; done; OWUI_LABEL= $BIN/gemma-up.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gemma-up.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gemma-up.log</string>
</dict>
</plist>
EOF
}

# Allow `source install-gemma-stack.sh` for testing the plist writers without running the install.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required"
(( MEM_GB >= 32 )) || [[ "${FORCE:-0}" == 1 ]] || die "${MEM_GB} GB is below the 32 GB this build assumes (FORCE=1 to override)"
command -v brew >/dev/null || die "Homebrew not found — run gemma/rebuild/30-bootstrap.sh first"
echo "Host: ${MEM_GB} GB, model $MODEL_KEY, context $CTX, Open WebUI port $OWUI_PORT"
echo "Asking for your password once (launchd setup needs sudo)."
sudo -v

step "1/9 Homebrew packages (Python 3.11, jq, LM Studio)"
brew install python@3.11 jq
brew list --cask lm-studio >/dev/null 2>&1 || brew install --cask lm-studio

step "2/9 LM Studio first launch"
if [[ ! -x "$LMS" ]]; then
  open -a "LM Studio" || die "could not open LM Studio — is $USER logged in on the desktop (Screen Sharing)?"
  echo "Click through LM Studio's first-run screens over Screen Sharing (skip any model download)."
  printf "Waiting up to %ss for %s " "$LMS_WAIT" "$LMS"
  for _ in $(seq 1 $((LMS_WAIT / 5))); do [[ -x "$LMS" ]] && break; printf "."; sleep 5; done
  echo
fi
[[ -x "$LMS" ]] || die "LM Studio's CLI is still missing at $LMS — finish its first-run screens, then re-run"

step "3/9 Gemma 4 26B-A4B QAT ($MODEL_QUANT)"
if "$LMS" ls 2>/dev/null | grep -q "$MODEL_KEY"; then
  echo "Already downloaded."
else
  "$LMS" get "https://huggingface.co/$MODEL_REPO@$MODEL_QUANT"
fi
"$LMS" ls | grep -q "$MODEL_KEY" || die "model key $MODEL_KEY not in 'lms ls' — set MODEL_KEY in $ENV_FILE and re-run"

step "4/9 Open WebUI in $VENV"
PY="$(brew --prefix python@3.11)/bin/python3.11"
[[ -x "$VENV/bin/python" ]] || "$PY" -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install --upgrade open-webui
"$VENV/bin/pip" show open-webui | grep -i '^version'

step "5/9 Data folder and secret key"
mkdir -p "$DATA_DIR" "$(dirname "$LOG")"
KEYFILE="$DATA_DIR/.webui_secret_key"
[[ -s "$KEYFILE" ]] || { openssl rand -hex 32 > "$KEYFILE"; chmod 600 "$KEYFILE"; }
SECRET="$(cat "$KEYFILE")"

step "6/9 launchd daemon ($PLIST)"
TMP="$(mktemp)"
write_plist "$SECRET" > "$TMP"
plutil -lint "$TMP" >/dev/null || die "generated plist is invalid: $TMP"
if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo launchctl bootout "system/$LABEL" || true
  for _ in $(seq 1 30); do sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 1; done
  sleep 5
fi
sudo install -m 644 -o root -g wheel "$TMP" "$PLIST"
rm -f "$TMP"
sudo launchctl bootstrap system "$PLIST"
printf "Waiting for Open WebUI (first start downloads helper models; up to 10 min) "
ok=0
for _ in $(seq 1 200); do
  if curl -fs "http://localhost:$OWUI_PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  printf "."; sleep 3
done
echo
[[ $ok == 1 ]] || die "Open WebUI did not answer on :$OWUI_PORT — check $LOG"

step "7/9 Link helper scripts into $BIN"
mkdir -p "$BIN"
stamp=$(date +%Y%m%d)
for f in "${LINKS[@]}"; do
  dest="$BIN/$(basename "$f")"
  [[ -f "$f" ]] || { echo "  missing $f"; continue; }
  chmod +x "$f"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$f" ]]; then echo "  ok      $(basename "$f")"; continue; fi
  [[ -e "$dest" || -L "$dest" ]] && mv "$dest" "$dest.bak-$stamp"
  ln -s "$f" "$dest"
  echo "  linked  $(basename "$f")"
done
grep -q 'HOME/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zprofile"

step "8/9 Auto-load Gemma at login ($AGENT_LABEL)"
mkdir -p "$(dirname "$AGENT")"
write_agent > "$AGENT"
plutil -lint "$AGENT" >/dev/null || die "generated LaunchAgent is invalid: $AGENT"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null && sleep 5 || true
if launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null; then
  echo "  installed; log: ~/Library/Logs/gemma-up.log"
else
  echo "  written to $AGENT; it loads at the next desktop login (no GUI session over SSH)"
fi

step "9/9 Offline copy of the docs and scripts in $HANDOFF"
mkdir -p "$HANDOFF"
for f in "$REPO/gemma/README.md" "$REPO/gemma/docs/"*.md "$REPO/gemma/bin/"* "$REPO/m5/bin/owui-upgrade.sh" "$REPO/m5/bin/llm-bench.py"; do
  [[ -f "$f" ]] && cp -p "$f" "$HANDOFF/"
done
echo "  copied $(ls "$HANDOFF" | wc -l | tr -d ' ') files"

cat <<EOF

✓ Done. Next (over Screen Sharing for the LM Studio steps):
  1. LM Studio → Developer → Server Settings: turn OFF Just-in-Time Model Loading and any
     option that auto-loads the last-used model at startup.
     My Models → $MODEL_KEY → gear: GPU offload max, context $CTX, Try mmap() ON.
  2. Run:  ~/bin/gemma-up.sh   (after this, Gemma loads by itself at every login)
  3. From another device open http://$(scutil --get LocalHostName 2>/dev/null || hostname).local:$OWUI_PORT
     The FIRST account you create becomes the admin: make it houdini.
  4. Check everything: ~/ZuulRulez/gemma/rebuild/40-verify.sh
EOF
