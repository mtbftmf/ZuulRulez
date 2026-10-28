#!/usr/bin/env bash
# 05-inventory.sh — read-only snapshot of a Mac before it is wiped or rebuilt: installed apps,
# Homebrew, launchd items, profiles, and one user's account details and home-folder files.
# Compare two snapshots with 06-inventory-diff.py. Output stays on the Mac (never commit it:
# it holds personal paths and file names).
#
#   bash 05-inventory.sh                    user with UID 503, output ~/inventory-<host>-<date>
#   INV_USER=someone bash 05-inventory.sh   another user
#   EXCLUDE_EXTRA='*/Movies/*' bash 05-inventory.sh   skip more paths in the file list
#
# Runs with sudo so it can read the whole home folder. Over SSH, folders protected by macOS privacy
# controls (Mail, Messages, Safari, some Library/Containers) are skipped unless Remote Login has
# "Allow full disk access for remote users" on; the count of unreadable folders is in errors.txt.
set -uo pipefail

UID_WANTED="${INV_UID:-503}"
if [[ -n "${INV_USER:-}" ]]; then U="$INV_USER"
else U="$(dscl . -list /Users UniqueID | awk -v id="$UID_WANTED" '$2 == id {print $1}')"; fi
[[ -n "$U" ]] || { echo "error: no user with UID $UID_WANTED (set INV_USER)" >&2; exit 1; }
H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -d "$H" ]] || { echo "error: home folder for $U not found" >&2; exit 1; }
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
OUT="${OUT:-$HOME/inventory-$HOST-$(date +%Y%m%d-%H%M)}"
mkdir -p "$OUT"
echo "Inventory of $HOST, user $U ($H) → $OUT"
echo "Asking for sudo (reads the whole home folder; changes nothing)."
sudo -v || exit 1

# ---- system
{
  printf 'host\t%s\n' "$HOST"
  printf 'model\t%s\n' "$(sysctl -n hw.model)"
  printf 'chip\t%s\n' "$(sysctl -n machdep.cpu.brand_string)"
  printf 'memory_gb\t%s\n' "$(( $(sysctl -n hw.memsize) / 1073741824 ))"
  printf 'macos\t%s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf 'filevault\t%s\n' "$(fdesetup status | head -1)"
  printf 'taken\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
  printf 'inv_user\t%s\n' "$U"
} > "$OUT/system.tsv"

# ---- account
{
  for k in RecordName RealName UniqueID PrimaryGroupID UserShell NFSHomeDirectory; do
    printf '%s\t%s\n' "$k" "$(dscl . -read "/Users/$U" "$k" 2>/dev/null | sed -e "s/^$k: *//" -e '1{/^$/d;}' | tr '\n' ' ' | sed 's/ *$//')"
  done
  printf 'groups\t%s\n' "$(id -Gn "$U" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  dseditgroup -o checkmember -m "$U" admin >/dev/null 2>&1 && printf 'admin\tyes\n' || printf 'admin\tno\n'
  printf 'secure_token\t%s\n' "$(sysadminctl -secureTokenStatus "$U" 2>&1 | grep -o 'ENABLED\|DISABLED')"
  st=$(sudo plutil -extract Accounts.0.AccountID raw "$H/Library/Preferences/MobileMeAccounts.plist" 2>/dev/null)
  printf 'apple_account\t%s\n' "${st:-none found}"
  printf 'login_items\t%s\n' "$(sudo -u "$U" osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || echo 'unavailable over SSH')"
} > "$OUT/account.tsv"
dscl . -list /Users UniqueID | awk '$2 >= 500' | sort -k2n > "$OUT/all-users.tsv"

# ---- apps: name, bundle id, version, App Store?, size KB, path
appline() {
  local a="$1" plist="$1/Contents/Info.plist" id ver mas kb
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)
  [[ -d "$a/Contents/_MASReceipt" ]] && mas=appstore || mas=direct
  kb=$(sudo du -sk "$a" 2>/dev/null | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$a" .app)" "${id:-?}" "${ver:-?}" "$mas" "${kb:-0}" "$a"
}
{
  printf 'name\tbundle_id\tversion\tsource\tsize_kb\tpath\n'
  for root in /Applications "$H/Applications"; do
    [[ -d "$root" ]] || continue
    sudo find "$root" -maxdepth 3 -name '*.app' -type d -prune 2>/dev/null | sort | while IFS= read -r a; do appline "$a"; done
  done
} > "$OUT/apps.tsv"
echo "  apps: $(( $(wc -l < "$OUT/apps.tsv") - 1 ))"

# ---- Homebrew (run as whoever owns it)
if [[ -x /opt/homebrew/bin/brew ]]; then
  bo=$(stat -f %Su /opt/homebrew)
  sudo -u "$bo" /opt/homebrew/bin/brew list --formula --versions 2>/dev/null | sort > "$OUT/brew-formulae.txt"
  sudo -u "$bo" /opt/homebrew/bin/brew list --cask --versions 2>/dev/null | sort > "$OUT/brew-casks.txt"
  sudo -u "$bo" /opt/homebrew/bin/brew services list 2>/dev/null > "$OUT/brew-services.txt"
  printf 'brew_owner\t%s\n' "$bo" >> "$OUT/system.tsv"
fi

# ---- launchd items, profiles, crontab
{
  for d in /Library/LaunchDaemons /Library/LaunchAgents "$H/Library/LaunchAgents"; do
    sudo find "$d" -maxdepth 1 -name '*.plist' 2>/dev/null | sed "s|^$H|~|"
  done
} | sort > "$OUT/launchd.txt"
sudo profiles list 2>/dev/null | sed -n 's/.*profileIdentifier: *//p' | sort > "$OUT/profiles.txt"
sudo crontab -l -u "$U" > "$OUT/crontab.txt" 2>/dev/null || true

# ---- home folder: size per top-level entry and per Library subfolder (KB)
{
  sudo find "$H" -mindepth 1 -maxdepth 1 2>/dev/null
  sudo find "$H/Library" -mindepth 1 -maxdepth 1 2>/dev/null
} | sort | while IFS= read -r p; do
  printf '%s\t%s\n' "$(sudo du -sk "$p" 2>/dev/null | awk '{print $1}')" "${p#"$H"/}"
done > "$OUT/home-sizes.tsv"

# ---- home folder: every file (size bytes, mtime epoch, path relative to home).
# Skipped: caches and things that rebuild themselves. Listed in home-files-excluded.txt.
EXCL=( '*/Library/Caches/*' '*/.cache/*' '*/.Trash/*' '*/node_modules/*' '*/site-packages/*'
       '*/.git/objects/*' '*/__pycache__/*' '*/Library/Containers/*/Data/Library/Caches/*'
       '*/Library/Logs/DiagnosticReports/*' )
[[ -n "${EXCLUDE_EXTRA:-}" ]] && EXCL+=( "$EXCLUDE_EXTRA" )
printf '%s\n' "${EXCL[@]}" > "$OUT/home-files-excluded.txt"
TAB=$'\t'
args=(); for e in "${EXCL[@]}"; do args+=( -not -path "$e" ); done
echo "  listing files in $H (can take a few minutes)"
sudo find "$H" -type f "${args[@]}" -print0 2>"$OUT/find-errors.txt" \
  | sudo xargs -0 stat -f '%z%t%m%t%N' 2>>"$OUT/find-errors.txt" \
  | sed "s|${TAB}$H/|${TAB}|" | sort -t "$TAB" -k3 | gzip -c > "$OUT/home-files.tsv.gz"
n=$(gzip -dc "$OUT/home-files.tsv.gz" | wc -l | tr -d ' ')
denied=$(grep -c 'Operation not permitted\|Permission denied' "$OUT/find-errors.txt" || true)
{
  printf 'files_listed\t%s\n' "$n"
  printf 'unreadable_paths\t%s\n' "$denied"
  [[ "$denied" -gt 0 ]] && printf 'note\tturn on "Allow full disk access for remote users" (Sharing > Remote Login > i), or run in Terminal on the Mac, to include them\n'
} > "$OUT/errors.txt"
sudo chown -R "$(id -un)" "$OUT"
echo "  files: $n listed, $denied unreadable paths (see errors.txt)"
echo "✓ Done: $OUT"
echo "  Copy it to the MBP, then: python3 06-inventory-diff.py <M1 folder> <M5 folder>"
