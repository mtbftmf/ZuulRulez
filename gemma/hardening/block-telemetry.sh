#!/bin/bash
# block-telemetry.sh — stop a generic Gemma host from reporting to Apple's feedback/diagnostics
# servers. Two parts:
#   1. /etc/hosts entries (0.0.0.0 and ::) for the hosts in BLOCK_HOSTS, kept between marker lines so
#      they can be checked and removed cleanly. Works whichever process makes the call.
#   2. "Share Mac Analytics" and "Share with app developers" forced off (AutoSubmit,
#      ThirdPartyDataSubmit in /Library/Application Support/CrashReporter/DiagnosticMessagesHistory).
#
#   sudo bash block-telemetry.sh on       add/refresh the block, turn analytics off, flush DNS
#   sudo bash block-telemetry.sh status   show what resolves where; exit 1 if anything isn't blocked
#   sudo bash block-telemetry.sh off      remove the block (analytics settings are left as they are)
#
# macOS updates can rewrite /etc/hosts: 40-verify.sh reports it, and `on` puts it back.
# Found on the M1 (Nov 2026): traffic to radarsubmissions.apple.com with analytics already off;
# SubmitDiagInfo's log showed it honours the opt-out (0 jobs), so another component (Feedback
# Assistant's background service) was the caller. To add a host, append it to BLOCK_HOSTS and run `on`.
set -u

BLOCK_HOSTS=(
  radarsubmissions.apple.com
)
HOSTS="${HOSTS_FILE:-/etc/hosts}"
BEGIN="# >>> gemma block-telemetry (gemma/hardening/block-telemetry.sh)"
END="# <<< gemma block-telemetry"
DIAG="/Library/Application Support/CrashReporter/DiagnosticMessagesHistory"

need_root() { [[ $EUID -eq 0 ]] || { echo "run with sudo: sudo bash $0 $*" >&2; exit 1; }; }

flush_dns() { dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; true; }

strip_block() {  # remove our marked block and any stray lines for our hosts (e.g. added by hand)
  local tmp; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" -v hosts="${BLOCK_HOSTS[*]}" '
    BEGIN { n = split(hosts, h, " "); for (i = 1; i <= n; i++) want[h[i]] = 1 }
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip { next }
    ($1 == "0.0.0.0" || $1 == "::" || $1 == "127.0.0.1") && ($2 in want) { next }
    { print }' "$HOSTS" > "$tmp"
  cat "$tmp" > "$HOSTS"     # keep the file's owner, mode and flags
  rm -f "$tmp"
}

resolves_blocked() {  # $1 host → 0 if every address it resolves to is 0.0.0.0 or ::
  local addrs
  addrs="$(dscacheutil -q host -a name "$1" 2>/dev/null | awk '/_address:/ {print $2}')"
  [[ -n "$addrs" ]] || return 1
  ! grep -qvE '^(0\.0\.0\.0|::)$' <<<"$addrs"
}

case "${1:-status}" in
  on)
    need_root "$@"
    cp -p "$HOSTS" "$HOSTS.bak-gemma-$(date +%Y%m%d%H%M%S)"
    strip_block
    {
      echo "$BEGIN"
      for h in "${BLOCK_HOSTS[@]}"; do printf '0.0.0.0 %s\n:: %s\n' "$h" "$h"; done
      echo "$END"
    } >> "$HOSTS"
    defaults write "$DIAG" AutoSubmit -bool false
    defaults write "$DIAG" ThirdPartyDataSubmit -bool false
    flush_dns
    echo "Blocked: ${BLOCK_HOSTS[*]}; analytics sharing off."
    bash "$0" status
    ;;
  off)
    need_root "$@"
    cp -p "$HOSTS" "$HOSTS.bak-gemma-$(date +%Y%m%d%H%M%S)"
    strip_block
    flush_dns
    echo "Removed the block from $HOSTS (analytics settings unchanged)."
    ;;
  status)
    bad=0
    grep -qxF "$BEGIN" "$HOSTS" && echo "hosts block: present in $HOSTS" || { echo "hosts block: missing from $HOSTS"; bad=1; }
    for h in "${BLOCK_HOSTS[@]}"; do
      if resolves_blocked "$h"; then echo "  [blocked]     $h"; else echo "  [NOT blocked] $h"; bad=1; fi
    done
    a=$(defaults read "$DIAG" AutoSubmit 2>/dev/null || echo unset)
    t=$(defaults read "$DIAG" ThirdPartyDataSubmit 2>/dev/null || echo unset)
    echo "analytics: AutoSubmit=$a ThirdPartyDataSubmit=$t (0 = off)"
    [[ "$a" == 0 && "$t" == 0 ]] || bad=1
    exit "$bad"
    ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
