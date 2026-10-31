#!/usr/bin/env bash
# install-gemma-stack.sh — generic Gemma 4 build for an Apple Silicon Mac Studio (32 GB or more).
# Everything runs over SSH; there is no GUI app. Two LaunchDaemons start at boot, before anyone
# logs in, and run as this account (houdini on generic builds):
#   com.gemma.llm        model server on 127.0.0.1:1234 (gemma/bin/gemma-serve.sh)
#   com.openwebui.serve  Open WebUI on 0.0.0.0:8080, data in ~/open-webui-data
# Engine (ENGINE in ~/.config/gemma.env):
#   llamacpp (default)  Homebrew llama.cpp, GGUF Q4_0 + vision projector
#   mlx                 mlx-vlm in ~/mlx-venv, MLX 4-bit QAT build
# Nothing from the M5 Max (Flash-Next, mlx-serve, Auto Router, Caddy, RAID, service toggles,
# RemoveMacAI) is installed here.
#
#   ~/ZuulRulez/gemma/bin/install-gemma-stack.sh            install, or re-check (safe to re-run)
#   ENGINE=mlx ~/ZuulRulez/gemma/bin/install-gemma-stack.sh  add the other engine and switch to it
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ENV_FILE="$HOME/.config/gemma.env"
ENV_EXAMPLE="$REPO/gemma/config/gemma.env.example"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
# Context from installed memory (weights ~15.6 GB): 32 GB → 16384, 48 GB and up → 32768.
default_ctx() { if (( MEM_GB >= 48 )); then echo 32768; else echo 16384; fi; }

CLI_ENGINE="${ENGINE:-}"
if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  sed "s/^CTX=.*/CTX=$(default_ctx)/" "$ENV_EXAMPLE" > "$ENV_FILE"
  echo "Created $ENV_FILE (CTX=$(default_ctx) for ${MEM_GB} GB)."
fi
# shellcheck source=gemma-env.sh
source "$HERE/gemma-env.sh"

VENV="$HOME/open-webui-venv"
DATA_DIR="$HOME/open-webui-data"
OWUI_LABEL="$OWUI_LABEL_DEFAULT"
OWUI_PLIST="$OWUI_PLIST_DEFAULT"
OWUI_LOG="$HOME/Library/Logs/open-webui.log"
BIN="$HOME/bin"
HANDOFF="$HOME/ai-handoff"
PY311="/opt/homebrew/opt/python@3.11/bin/python3.11"

LINKS=(
  "$REPO/gemma/bin/gemma-up.sh"
  "$REPO/gemma/bin/gemma-down.sh"
  "$REPO/m5/bin/owui-upgrade.sh"
  "$REPO/m5/bin/llm-bench.py"
)

step() { printf '\n== %s ==\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

plist_head() {  # $1 label
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>UserName</key><string>$USER</string>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
EOF
}

write_owui_plist() {  # $1 = secret key
  plist_head "$OWUI_LABEL"
  cat <<EOF
  <key>ProgramArguments</key>
  <array>
    <string>$VENV/bin/open-webui</string>
    <string>serve</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>$OWUI_PORT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$VENV/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>DATA_DIR</key><string>$DATA_DIR</string>
    <key>WEBUI_SECRET_KEY</key><string>$1</string>
    <key>ENABLE_OLLAMA_API</key><string>false</string>
    <key>OPENAI_API_BASE_URL</key><string>http://127.0.0.1:$PORT/v1</string>
    <key>OPENAI_API_KEY</key><string>local</string>
    <key>BYPASS_MODEL_ACCESS_CONTROL</key><string>true</string>
  </dict>
  <key>StandardOutPath</key><string>$OWUI_LOG</string>
  <key>StandardErrorPath</key><string>$OWUI_LOG</string>
</dict>
</plist>
EOF
}

write_llm_plist() {
  plist_head "$LLM_LABEL"
  cat <<EOF
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO/gemma/bin/gemma-serve.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>StandardOutPath</key><string>$LLM_LOG</string>
  <key>StandardErrorPath</key><string>$LLM_LOG</string>
</dict>
</plist>
EOF
}

install_daemon() {  # $1 label, $2 plist path, $3 generated file; reload only when it changed
  plutil -lint "$3" >/dev/null || die "generated plist is invalid: $3"
  if [[ -f "$2" ]] && sudo cmp -s "$3" "$2" && sudo launchctl print "system/$1" >/dev/null 2>&1; then
    echo "  ok $1 (unchanged, running)"; rm -f "$3"; return 0
  fi
  if sudo launchctl print "system/$1" >/dev/null 2>&1; then
    sudo launchctl bootout "system/$1" || true
    for _ in $(seq 1 30); do sudo launchctl print "system/$1" >/dev/null 2>&1 || break; sleep 1; done
    sleep 5
  fi
  sudo install -m 644 -o root -g wheel "$3" "$2"
  rm -f "$3"
  sudo launchctl bootstrap system "$2"
  echo "  loaded $1"
}

set_env() {  # $1 key, $2 value: replace or append in ~/.config/gemma.env
  if grep -q "^$1=" "$ENV_FILE"; then sed -i '' "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

# Allow `source install-gemma-stack.sh` for testing the plist writers without running the install.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required"
(( MEM_GB >= 32 )) || [[ "${FORCE:-0}" == 1 ]] || die "${MEM_GB} GB is below the 32 GB this build assumes (FORCE=1 to override)"
command -v brew >/dev/null || die "Homebrew not found — run gemma/rebuild/30-bootstrap.sh first"
echo "Host: ${MEM_GB} GB · engine $ENGINE · model $MODEL_ID · context $CTX · parallel $NP · Open WebUI :$OWUI_PORT"
echo "Asking for your password once (LaunchDaemons need sudo)."
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

if [[ -n "${HF_TOKEN:-}" ]]; then
  export HF_TOKEN; chmod 600 "$ENV_FILE" 2>/dev/null || true
  echo "Using HF_TOKEN from $ENV_FILE for model downloads."
else
  echo "No HF_TOKEN set: downloads work, but Hugging Face rate-limits them (see gemma.env.example)."
fi

step "1/8 Homebrew packages"
brew install python@3.11 jq
[[ "$ENGINE" == llamacpp ]] && brew install llama.cpp
[[ -x "$PY311" ]] || die "python3.11 missing at $PY311"

step "2/8 Model download ($ENGINE, ~16 GB the first time)"
case "$ENGINE" in
  llamacpp)
    # llama-server downloads the GGUF and its vision projector into $LLAMA_CACHE, then serves.
    # Run it once on a spare port, stop it when it reports healthy; the daemon then runs --offline.
    mkdir -p "$LLAMA_CACHE"
    have() { find -L "$LLAMA_CACHE" -iname "$1" -name '*.gguf' -size +1M 2>/dev/null | grep -q .; }
    if have "*${GGUF_QUANT}*" && have "*mmproj*"; then
      echo "Already downloaded."
    else
      llama-server -hf "$GGUF_REPO:$GGUF_QUANT" --host 127.0.0.1 --port 18999 -c 512 --no-webui &
      pid=$!
      for _ in $(seq 1 1200); do
        curl -fs http://127.0.0.1:18999/health >/dev/null 2>&1 && break
        kill -0 "$pid" 2>/dev/null || die "llama-server exited during download"
        sleep 3
      done
      kill "$pid"; wait "$pid" 2>/dev/null || true
      have "*${GGUF_QUANT}*" || die "no *${GGUF_QUANT}*.gguf in $LLAMA_CACHE after download"
    fi
    find -L "$LLAMA_CACHE" -name '*.gguf' -size +1M -exec ls -lhL {} + | awk '{print "  " $5 "  " $NF}'
    ;;
  mlx)
    [[ -x "$MLX_VENV/bin/python" ]] || "$PY311" -m venv "$MLX_VENV"
    "$MLX_VENV/bin/pip" show mlx-vlm >/dev/null 2>&1 || { "$MLX_VENV/bin/pip" install --upgrade pip; "$MLX_VENV/bin/pip" install mlx-vlm; }
    "$MLX_VENV/bin/pip" show mlx-vlm | grep -i '^version'
    "$MLX_VENV/bin/hf" download "$MLX_REPO"
    ;;
esac

step "3/8 Engine setting in $ENV_FILE"
[[ -n "$CLI_ENGINE" ]] && set_env ENGINE "$ENGINE"
grep -E '^(ENGINE|CTX|NP|PORT)=' "$ENV_FILE" | sed 's/^/  /'

step "4/8 Model server daemon ($LLM_PLIST)"
chmod +x "$REPO/gemma/bin/"*.sh
mkdir -p "$(dirname "$LLM_LOG")"
TMP="$(mktemp)"; write_llm_plist > "$TMP"
install_daemon "$LLM_LABEL" "$LLM_PLIST" "$TMP"
if [[ -n "$CLI_ENGINE" ]] && sudo launchctl print "system/$LLM_LABEL" >/dev/null 2>&1; then
  sudo launchctl kickstart -k "system/$LLM_LABEL"   # engine may have changed; plist did not
fi

step "5/8 Open WebUI in $VENV"
[[ -x "$VENV/bin/python" ]] || "$PY311" -m venv "$VENV"
if ! "$VENV/bin/pip" show open-webui >/dev/null 2>&1; then   # upgrades: ~/bin/owui-upgrade.sh
  "$VENV/bin/pip" install --upgrade pip
  "$VENV/bin/pip" install open-webui
fi
"$VENV/bin/pip" show open-webui | grep -i '^version'
mkdir -p "$DATA_DIR"
KEYFILE="$DATA_DIR/.webui_secret_key"
[[ -s "$KEYFILE" ]] || { openssl rand -hex 32 > "$KEYFILE"; chmod 600 "$KEYFILE"; }

step "6/8 Open WebUI daemon ($OWUI_PLIST)"
TMP="$(mktemp)"; write_owui_plist "$(cat "$KEYFILE")" > "$TMP"
install_daemon "$OWUI_LABEL" "$OWUI_PLIST" "$TMP"

step "7/8 Links in $BIN, offline copy in $HANDOFF"
mkdir -p "$BIN" "$HANDOFF"
stamp=$(date +%Y%m%d)
for f in "${LINKS[@]}"; do
  dest="$BIN/$(basename "$f")"
  [[ -f "$f" ]] || { echo "  missing $f"; continue; }
  chmod +x "$f"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$f" ]]; then echo "  ok      $(basename "$f")"; continue; fi
  [[ -e "$dest" || -L "$dest" ]] && mv "$dest" "$dest.bak-$stamp"
  ln -s "$f" "$dest"; echo "  linked  $(basename "$f")"
done
grep -q 'HOME/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zprofile"
# Retire the LM Studio-era login item if an earlier version of this script made one.
old="$HOME/Library/LaunchAgents/com.$USER.gemma-up.plist"
if [[ -f "$old" ]]; then launchctl bootout "gui/$(id -u)/com.$USER.gemma-up" 2>/dev/null || true; mv "$old" "$old.retired-$stamp"; echo "  retired old login item"; fi
for f in "$REPO/gemma/README.md" "$REPO/gemma/docs/"*.md "$REPO/gemma/bin/"* "$REPO/m5/bin/owui-upgrade.sh" "$REPO/m5/bin/llm-bench.py"; do
  [[ -f "$f" ]] && cp -p "$f" "$HANDOFF/"
done
echo "  $(ls "$HANDOFF" | wc -l | tr -d ' ') files in $HANDOFF"

step "8/8 Start and check"
"$BIN/gemma-up.sh"

cat <<EOF

✓ Done. Model server and Open WebUI start at boot; no desktop login needed.
  1. From another device open http://$(scutil --get LocalHostName 2>/dev/null || hostname).local:$OWUI_PORT
     The FIRST account you create becomes the admin: make it houdini.
     Model id in Open WebUI: $MODEL_ID
  2. Check everything: ~/ZuulRulez/gemma/rebuild/40-verify.sh
  3. Benchmark: python3 ~/bin/llm-bench.py --model $MODEL_ID --label $ENGINE
EOF
