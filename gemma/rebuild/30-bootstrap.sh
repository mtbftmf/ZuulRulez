#!/usr/bin/env bash
# 30-bootstrap.sh — first run on a freshly erased Mac, over SSH as houdini.
# Installs the Command Line Tools and Homebrew without any GUI dialog, clones the repo on MacLLM,
# sets the per-repo commit identity, keeps the Mac awake and fixes the zsh paste gotchas.
#   curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/30-bootstrap.sh -o ~/30-bootstrap.sh
#   bash ~/30-bootstrap.sh
# Optional: MAC_NAME=M1-Studio bash ~/30-bootstrap.sh   also sets the computer and Bonjour name.
# Safe to re-run.
set -euo pipefail

REPO_URL="https://github.com/mtbftmf/ZuulRulez.git"
REPO_DIR="$HOME/ZuulRulez"
BRANCH="MacLLM"
step() { printf '\n== %s ==\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || die "Apple Silicon required"
echo "macOS $(sw_vers -productVersion), user $USER. Asking for your password once."
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

step "1/7 Command Line Tools (headless)"
if xcode-select -p >/dev/null 2>&1 && [[ -x /usr/bin/git ]] && /usr/bin/git --version >/dev/null 2>&1; then
  echo "Already installed: $(xcode-select -p)"
else
  flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$flag"
  label="$(softwareupdate --list 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)"
  [[ -n "$label" ]] || { rm -f "$flag"; die "no Command Line Tools in softwareupdate --list; run xcode-select --install over Screen Sharing"; }
  echo "Installing $label"
  sudo softwareupdate --install "$label" --agree-to-license
  rm -f "$flag"
fi

step "2/7 Homebrew"
if [[ ! -x /opt/homebrew/bin/brew ]]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install git gh jq

step "3/7 Repo on $BRANCH in $REPO_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  cur="$(git -C "$REPO_DIR" branch --show-current)"
  [[ "$cur" == "$BRANCH" ]] || die "$REPO_DIR is on '$cur', not $BRANCH. Fix by hand; never git checkout in that folder"
  git -C "$REPO_DIR" pull --ff-only
else
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi
git -C "$REPO_DIR" config user.name "Pdl_Pwr"
git -C "$REPO_DIR" config user.email "mtbftmf@users.noreply.github.com"
echo "commit identity: $(git -C "$REPO_DIR" config user.name) <$(git -C "$REPO_DIR" config user.email)>"

step "4/7 Host config"
mkdir -p "$HOME/.config"
if [[ -f "$HOME/.config/gemma.env" ]]; then echo "ok ~/.config/gemma.env exists"
else echo "~/.config/gemma.env is created by install-gemma-stack.sh from gemma/config/gemma.env.example"; fi

step "5/7 Stay awake, wake for network, restart after power failure"
sudo pmset -a sleep 0 disksleep 0 displaysleep 15 womp 1 autorestart 1
pmset -g | grep -E ' sleep|disksleep|womp|autorestart'

step "6/7 zsh paste safety"
grep -q 'interactivecomments' "$HOME/.zshrc" 2>/dev/null || echo 'setopt interactivecomments' >> "$HOME/.zshrc"
echo "ok setopt interactivecomments in ~/.zshrc"

step "7/7 Computer name"
if [[ -n "${MAC_NAME:-}" ]]; then
  sudo scutil --set ComputerName "$MAC_NAME"
  sudo scutil --set LocalHostName "$MAC_NAME"
  sudo scutil --set HostName "$MAC_NAME.local"
fi
echo "$(scutil --get ComputerName) / $(scutil --get LocalHostName).local"

cat <<EOF

✓ Bootstrap done. Next:
  1. Only if this Mac should push to GitHub: gh auth login   (HTTPS, browser; open the code on the MBP)
  2. Install the stack (all over SSH, ~30 min, mostly downloads):
       exec zsh -l
       ~/ZuulRulez/gemma/bin/install-gemma-stack.sh
     ENGINE=mlx in front of the installer uses MLX instead of llama.cpp.
EOF
