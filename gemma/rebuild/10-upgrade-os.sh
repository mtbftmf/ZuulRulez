#!/usr/bin/env bash
# 10-upgrade-os.sh — upgrade the Mac to the newest macOS Golden Gate 27.x release over SSH.
# Upgrading BEFORE Erase All Content and Settings means the erased Mac comes back on Golden Gate,
# so the whole rebuild needs one trip to the machine (Setup Assistant) instead of a Recovery install.
#   bash ~/10-upgrade-os.sh                 lists the update, asks, installs and restarts
#   VOLUME_OWNER=someone bash ~/10-upgrade-os.sh   when $USER has no secure token (see 00-preflight.sh)
# The SSH session drops at the restart. With FileVault on, unlock it afterwards over SSH (Ethernet).
set -euo pipefail

OWNER="${VOLUME_OWNER:-$USER}"
die() { echo "error: $*" >&2; exit 1; }

sudo profiles list 2>/dev/null | grep -q removemacai && \
  die "remove the RemoveMacAI profile first: sudo profiles remove -identifier io.github.omlahore.removemacai"

echo "→ Checking for updates (can take a minute)"
list="$(softwareupdate --list 2>&1 || true)"
# Major upgrade from Tahoe is labelled "macOS Golden Gate 27.x-…"; point updates on 27 are "macOS 27.x-…".
label="$(printf '%s\n' "$list" | sed -nE 's/^\* Label: (macOS (Golden Gate )?27.*)$/\1/p' | tail -1)"
if [[ -z "$label" ]]; then
  printf '%s\n' "$list"
  [[ "$(sw_vers -productVersion)" == 27.* ]] && { echo "Already on macOS $(sw_vers -productVersion). Nothing to do."; exit 0; }
  die "no 'macOS Golden Gate' label in the list. Fallback: softwareupdate --fetch-full-installer, then the installer app"
fi

echo "→ Found: $label"
echo "  Installs as volume owner '$OWNER' and restarts the Mac when ready (~30-60 min)."
read -r -p "  Install now? [y/N] " ans
[[ "$ans" == [yY]* ]] || exit 0
sudo -v
read -r -s -p "  Password for $OWNER (authorizes the update): " pw; echo
printf '%s' "$pw" | sudo softwareupdate --install "$label" --agree-to-license --restart --user "$OWNER" --stdinpass
unset pw
