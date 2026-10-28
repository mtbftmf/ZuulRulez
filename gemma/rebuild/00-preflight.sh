#!/usr/bin/env bash
# 00-preflight.sh — read-only checks before rebuilding a Mac Studio for the generic Gemma 4 build.
# Run over SSH on the Mac that is about to be upgraded and erased. Changes nothing.
#   curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/00-preflight.sh -o ~/00-preflight.sh
#   bash ~/00-preflight.sh
set -uo pipefail

ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
info() { printf '  INFO  %s\n' "$*"; }

echo "Asking for sudo (profiles, volume owners, Remote Login status)."
sudo -v || exit 1

echo "== Machine"
model=$(sysctl -n hw.model); chip=$(sysctl -n machdep.cpu.brand_string)
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
info "$model, $chip, ${mem_gb} GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
[[ "$(uname -m)" == arm64 ]] && ok "Apple Silicon (macOS Golden Gate 27 supports every M-series Mac)" || warn "not Apple Silicon: Golden Gate will not install"
(( mem_gb >= 32 )) && ok "${mem_gb} GB memory" || warn "${mem_gb} GB: below the 32 GB the Gemma build assumes"
free_gb=$(df -g / | awk 'NR==2 {print $4}')
(( free_gb >= 40 )) && ok "${free_gb} GB free (upgrade download needs ~25 GB)" || warn "only ${free_gb} GB free"

echo "== Volume owners (only these accounts can authorize the macOS upgrade and the erase)"
for u in $(dscl . list /Users UniqueID | awk '$2 >= 501 {print $1}'); do
  st=$(sysadminctl -secureTokenStatus "$u" 2>&1 | grep -o 'ENABLED\|DISABLED')
  admin=$(dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1 && echo admin || echo standard)
  info "$u ($admin): secure token ${st:-unknown}"
done
st=$(sysadminctl -secureTokenStatus "$USER" 2>&1 | grep -o 'ENABLED\|DISABLED')
[[ "$st" == ENABLED ]] && ok "$USER can authorize the upgrade (--user $USER)" || warn "$USER has no secure token: run 10-upgrade-os.sh with VOLUME_OWNER set to an account above that has ENABLED"

echo "== Profiles"
if sudo profiles list 2>/dev/null | grep -q removemacai; then
  warn "RemoveMacAI profile installed: it stalls macOS downloads. Remove it first:"
  echo "        sudo profiles remove -identifier io.github.omlahore.removemacai"
else
  ok "no RemoveMacAI profile"
fi
n=$(sudo profiles list 2>/dev/null | grep -c 'profileIdentifier' || true)
info "${n} configuration profile(s) installed"

echo "== Security and recovery"
fv=$(fdesetup status 2>/dev/null | head -1); info "FileVault: $fv"
if nvram fmm-mobileme-token-FMM >/dev/null 2>&1; then
  info "Find My is ON: Erase All Content and Settings asks for that Apple Account password"
else
  info "Find My is off"
fi

echo "== Remote access (what still works after each step)"
rl=$(sudo systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print $2}')
[[ "$rl" == On ]] && ok "Remote Login (SSH) on" || warn "Remote Login is $rl"
nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1 && ok "Screen Sharing / Remote Management listening on 5900" || warn "nothing on 5900: turn on Remote Management for the erase step"
if route -n get default >/dev/null 2>&1; then
  ifc=$(route -n get default | awk '/interface:/ {print $2}')
  hw=$(networksetup -listallhardwareports | awk -v d="$ifc" '/Hardware Port/ {p=$0} $2==d {print p}' | sed 's/Hardware Port: //')
  [[ "$hw" == *Ethernet* ]] && ok "default route on $ifc ($hw)" || warn "default route on $ifc (${hw:-unknown}): use Ethernet; FileVault unlock over SSH and Setup Assistant activation want a wired link"
fi

echo "== Available macOS updates (look for macOS Golden Gate 27.x)"
softwareupdate --list 2>&1 | grep -E 'Label|Title' | sed 's/^/        /' || true
echo
echo "Next: bash 10-upgrade-os.sh (over SSH), then Erase All Content and Settings over Screen Sharing."
