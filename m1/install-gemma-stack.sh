#!/usr/bin/env bash
# install-gemma-stack.sh — one-time setup on a fresh Apple Silicon Mac:
#   LM Studio + Gemma 4 26B-A4B (QAT) + Open WebUI (Python 3.11 venv, launchd daemon on :8080).
# Safe to re-run: every step checks before it changes anything.
# Prereqs: Homebrew installed, admin account. Put this script's sibling files in ~/Downloads first
# (gemma-up.sh, gemma-down.sh, owui-upgrade.sh, llm-bench.py) and they are installed into ~/bin.
set -euo pipefail

MODEL_REPO="${MODEL_REPO:-lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF}"
MODEL_KEY="${MODEL_KEY:-gemma-4-26b-a4b-it-qat}"
VENV="$HOME/open-webui-venv"
DATA_DIR="$HOME/open-webui-data"
LABEL="com.openwebui.serve"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
PORT=8080
LMS="$HOME/.lmstudio/bin/lms"
BIN="$HOME/bin"
SRC="${SRC:-$HOME/Downloads}"
LOG="$HOME/Library/Logs/open-webui.log"
AGENT_LABEL="com.$USER.gemma-up"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
HANDOFF="$HOME/ai-handoff"

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
    <string>--port</string><string>$PORT</string>
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

# Allow `source install-gemma-stack.sh` for testing write_plist without running the install.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required"
command -v brew >/dev/null || die "Homebrew not found — install it first (see handoff doc, Prerequisites)"
echo "Asking for your password once (launchd setup needs sudo)."
sudo -v

step "1/9 Homebrew packages (Python 3.11, jq, LM Studio)"
brew install python@3.11 jq
brew list --cask lm-studio >/dev/null 2>&1 || brew install --cask lm-studio

step "2/9 LM Studio first launch"
if [[ ! -x "$LMS" ]]; then
  open -a "LM Studio"
  echo "Click through LM Studio's first-run screens (skip any model download), then press Return here."
  read -r
fi
[[ -x "$LMS" ]] || die "LM Studio's CLI is still missing at $LMS — open LM Studio once more, then re-run"

step "3/9 Gemma 4 26B-A4B QAT (~15.6 GB)"
if "$LMS" ls 2>/dev/null | grep -q "$MODEL_KEY"; then
  echo "Already downloaded."
else
  echo "If asked to choose a file, pick the Q4_0 GGUF (~15.6 GB)."
  "$LMS" get "$MODEL_REPO"
fi
"$LMS" ls | grep -q "$MODEL_KEY" || die "model key $MODEL_KEY not found in 'lms ls' — set MODEL_KEY=<key> and re-run"

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
fi
sudo install -m 644 -o root -g wheel "$TMP" "$PLIST"
rm -f "$TMP"
sudo launchctl bootstrap system "$PLIST"
printf "Waiting for Open WebUI (first start downloads helper models; up to 10 min) "
ok=0
for _ in $(seq 1 200); do
  if curl -fs "http://localhost:$PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  printf "."; sleep 3
done
echo
[[ $ok == 1 ]] || die "Open WebUI did not answer on :$PORT — check $LOG"

step "7/9 Helper scripts into $BIN"
mkdir -p "$BIN"
for f in gemma-up.sh gemma-down.sh owui-upgrade.sh llm-bench.py; do
  if [[ -f "$SRC/$f" ]]; then
    install -m 755 "$SRC/$f" "$BIN/$f"
    xattr -d com.apple.quarantine "$BIN/$f" 2>/dev/null || true
    echo "  installed $f"
  else
    echo "  skipped $f (not in $SRC)"
  fi
done
grep -q 'HOME/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zprofile"

step "8/9 Auto-load Gemma at login ($AGENT_LABEL)"
if [[ -x "$BIN/gemma-up.sh" ]]; then
  mkdir -p "$(dirname "$AGENT")"
  write_agent > "$AGENT"
  plutil -lint "$AGENT" >/dev/null || die "generated LaunchAgent is invalid: $AGENT"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  sleep 2
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "  installed; log: ~/Library/Logs/gemma-up.log"
else
  echo "  skipped (gemma-up.sh not installed)"
fi

step "9/9 Offline copy of the handoff in $HANDOFF"
mkdir -p "$HANDOFF"
for f in install-gemma-stack.sh gemma-up.sh gemma-down.sh owui-upgrade.sh llm-bench.py README.md; do
  [[ -f "$SRC/$f" ]] && cp -p "$SRC/$f" "$HANDOFF/" && echo "  copied $f"
done
[[ -f "$HANDOFF/README.md" ]] || echo "  note: save the handoff doc as $SRC/README.md (Export → Markdown) and re-run to copy it"

cat <<EOF

✓ Done. Next:
  1. In LM Studio: Developer → Server Settings → turn OFF "Just-in-Time Model Loading",
     and turn off any option that auto-loads the last-used model at startup.
     My Models → $MODEL_KEY → gear: GPU offload max, context 16384, Try mmap() ON.
  2. Run:  ~/bin/gemma-up.sh   (after this, Gemma loads by itself at every login)
  3. Open http://localhost:$PORT — the FIRST account you create becomes the admin.
  4. Follow "Open WebUI configuration" and "Your setup" in the handoff doc.
EOF
