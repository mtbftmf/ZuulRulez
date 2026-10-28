#!/usr/bin/env bash
# 40-verify.sh — check a finished generic Gemma 4 build. Read-only; run over SSH as houdini.
#   ~/ZuulRulez/gemma/rebuild/40-verify.sh
# Exit code = number of FAILs.
set -uo pipefail

REPO="$HOME/ZuulRulez"
# shellcheck source=../bin/gemma-env.sh
source "$REPO/gemma/bin/gemma-env.sh" || exit 1
fails=0
ok()   { printf '  OK    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  INFO  %s\n' "$*"; }
listen() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u | tr '\n' ' '; }

echo "== System"
v=$(sw_vers -productVersion)
[[ "$v" == 27.* ]] && ok "macOS $v ($(sw_vers -buildVersion))" || fail "macOS $v (expected Golden Gate 27.x)"
info "$(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, user $USER"
[[ "$USER" == houdini ]] && ok "running as houdini" || info "running as $USER (generic builds use houdini)"
st=$(sysadminctl -secureTokenStatus "$USER" 2>&1 | grep -o 'ENABLED\|DISABLED')
[[ "$st" == ENABLED ]] && ok "$USER is a volume owner (can authorize updates)" || fail "$USER has no secure token"
info "FileVault: $(fdesetup status | head -1)"
pm=$(pmset -g)
for k in "sleep 0" "womp 1" "autorestart 1"; do
  echo "$pm" | grep -Eq "^ *${k% *} +${k#* }( |$)" && ok "pmset $k" || fail "pmset $k (run 30-bootstrap.sh step 5)"
done
nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 && ok "Remote Login (SSH) on :22" || fail "Remote Login off"
nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1 && ok "Screen Sharing / Remote Management on :5900" || fail "Remote Management off"
info "swap: $(sysctl -n vm.swapusage)"

echo "== Repo"
b=$(git -C "$REPO" branch --show-current 2>/dev/null)
[[ "$b" == MacLLM ]] && ok "$REPO on MacLLM" || fail "$REPO on '${b:-missing}' (must stay on MacLLM)"
[[ "$(git -C "$REPO" config user.email 2>/dev/null)" == mtbftmf@users.noreply.github.com ]] && ok "commit identity Pdl_Pwr" || fail "repo commit identity not set"
for f in gemma-up.sh gemma-down.sh owui-upgrade.sh llm-bench.py; do
  t=$(readlink "$HOME/bin/$f" 2>/dev/null)
  [[ "$t" == "$REPO/"* ]] && ok "~/bin/$f → ${t#"$HOME"/}" || fail "~/bin/$f is not a link into the repo"
done

echo "== Model server ($ENGINE)"
sudo -n true 2>/dev/null && pl="sudo launchctl" || pl="launchctl"
$pl print "system/$LLM_LABEL" >/dev/null 2>&1 && ok "daemon $LLM_LABEL loaded (starts at boot)" || fail "daemon $LLM_LABEL not loaded (run ~/bin/gemma-up.sh)"
l=$(listen "$PORT")
if [[ -z "$l" ]]; then fail "nothing listening on :$PORT (tail -50 $LLM_LOG)"
else
  wide=0; for a in $l; do [[ "$a" == 127.* || "$a" == "[::1]:"* ]] || wide=1; done
  (( wide == 0 )) && ok "server on localhost only ($l)" || fail "server reachable beyond localhost: $l"
fi
models=$(curl -fs "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)
echo "$models" | grep -qF "\"$MODEL_ID\"" && ok "serving $MODEL_ID" || fail "$MODEL_ID not served"
n=$(printf '%s' "$models" | jq -r '.data | length' 2>/dev/null || echo "?")
[[ "$n" == 1 ]] && ok "exactly one model listed" || info "$n models listed"
case "$ENGINE" in
  llamacpp) info "llama.cpp $(llama-server --version 2>&1 | grep -m1 -o 'version: [0-9]*' || echo '?'), cache $LLAMA_CACHE" ;;
  mlx)      info "mlx-vlm $("$MLX_VENV/bin/pip" show mlx-vlm 2>/dev/null | awk '/^Version:/ {print $2}')" ;;
esac
r=$(curl -fs -m 120 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word ready.\"}],\"max_tokens\":200}" 2>/dev/null \
  | jq -r '.choices[0].message.content // empty' 2>/dev/null)
[[ "$r" == *[Rr]eady* ]] && ok "chat completion answered" || fail "chat completion: '${r:0:60}'"
[[ -f "$HOME/Library/LaunchAgents/com.$USER.gemma-up.plist" ]] && fail "old LM Studio login item still present (re-run the installer)"

echo "== Open WebUI"
curl -fs "http://localhost:$OWUI_PORT/health" >/dev/null 2>&1 && ok "healthy on :$OWUI_PORT" || fail "no answer on :$OWUI_PORT"
l=$(listen "$OWUI_PORT")
[[ "$l" == *"*:$OWUI_PORT"* || "$l" == *"0.0.0.0:$OWUI_PORT"* ]] && ok "reachable on the LAN ($l)" || fail "not on the LAN: ${l:-nothing}"
p=/Library/LaunchDaemons/com.openwebui.serve.plist
dd=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:DATA_DIR" "$p" 2>/dev/null)
[[ "$dd" == "$HOME/open-webui-data" ]] && ok "DATA_DIR ~/open-webui-data" || fail "DATA_DIR is '${dd:-unset}'"
k1=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:WEBUI_SECRET_KEY" "$p" 2>/dev/null)
[[ -n "$k1" && "$k1" == "$(cat "$HOME/open-webui-data/.webui_secret_key" 2>/dev/null)" ]] && ok "secret key matches (logins survive restarts)" || fail "secret key mismatch"
info "Open WebUI $("$HOME/open-webui-venv/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/ {print $2}')"

echo "== Hardening (RemoveMacAI, service toggles)"
if sudo -n true 2>/dev/null; then
  sudo profiles list 2>/dev/null | grep -q io.github.omlahore.removemacai && ok "RemoveMacAI profile installed" || info "RemoveMacAI profile not installed"
else
  info "profile check needs sudo: run 'sudo -v' first"
fi
[[ -f "$HOME/.config/removemacai-reinstall" ]] && fail "RemoveMacAI was removed for a macOS update on $(cat "$HOME/.config/removemacai-reinstall"): reinstall with 50-harden.sh profile"
[[ -x /usr/local/bin/macos-service-toggle.sh ]] && info "service toggles installed (check: sudo /usr/local/bin/macos-service-toggle.sh status)" || info "service toggles not installed"

echo
(( fails == 0 )) && echo "All checks passed." || echo "$fails check(s) failed."
echo "Speed (record in CHANGELOG): python3 ~/bin/llm-bench.py --model $MODEL_ID --label $ENGINE"
exit "$fails"
