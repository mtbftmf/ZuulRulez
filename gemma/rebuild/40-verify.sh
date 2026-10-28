#!/usr/bin/env bash
# 40-verify.sh — check a finished generic Gemma 4 build. Read-only; run over SSH as houdini.
#   ~/ZuulRulez/gemma/rebuild/40-verify.sh
# Exit code = number of FAILs.
set -uo pipefail

# shellcheck disable=SC1091
[[ -f "$HOME/.config/gemma.env" ]] && source "$HOME/.config/gemma.env"
MODEL_KEY="${MODEL_KEY:-gemma-4-26b-a4b-it-qat}"
PORT="${PORT:-1234}"
OWUI_PORT="${OWUI_PORT:-8080}"
REPO="$HOME/ZuulRulez"
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

echo "== LM Studio"
l=$(listen "$PORT")
if [[ -z "$l" ]]; then fail "nothing listening on :$PORT (run ~/bin/gemma-up.sh)"
else
  wide=0; for a in $l; do [[ "$a" == 127.* || "$a" == "[::1]:"* ]] || wide=1; done
  (( wide == 0 )) && ok "server on localhost only ($l)" || fail "server reachable beyond localhost: $l"
fi
models=$(curl -fs "http://localhost:$PORT/v1/models" 2>/dev/null)
echo "$models" | grep -q "\"$MODEL_KEY\"" && ok "$MODEL_KEY loaded" || fail "$MODEL_KEY not served (JIT off: run ~/bin/gemma-up.sh)"
n=$(printf '%s' "$models" | jq -r '.data | length' 2>/dev/null || echo "?")
[[ "$n" == 1 ]] && ok "exactly one model listed" || info "$n models listed (JIT may still be on)"
launchctl print "gui/$(id -u)/com.$USER.gemma-up" >/dev/null 2>&1 && ok "login item com.$USER.gemma-up loaded" || fail "login item com.$USER.gemma-up not loaded"

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

echo
(( fails == 0 )) && echo "All checks passed." || echo "$fails check(s) failed."
echo "Speed (record in CHANGELOG): python3 ~/bin/llm-bench.py --model $MODEL_KEY --label $(scutil --get LocalHostName 2>/dev/null)"
exit "$fails"
