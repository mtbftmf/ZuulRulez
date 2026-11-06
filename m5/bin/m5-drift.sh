#!/bin/zsh
# m5-drift.sh - find launchd jobs whose program is gone, a stale Caddy root, and changes since a saved baseline.
#   m5-drift.sh            check: prints DRIFT: / WARN: lines, nothing at all when clean (exit 0 either way)
#   m5-drift.sh snapshot   save the current state as the baseline; run it after every INTENDED change
#   m5-drift.sh show       print the facts a baseline is made of
# The baseline holds listener kinds and ports, a hash of every launchd plist and the Caddy root hashes. It lives
# in ~/.local/state/m5-drift/baseline and is never committed (plist paths name your user). The orphan and Caddy
# checks need no baseline. Meant to be run by m5-health-watch.sh; settings (all optional) go in ~/.config/macllm.env:
#   DRIFT_PLIST_DIRS (space separated), DRIFT_BASELINE, CADDY_ROOT, DRIFT_KEYCHAIN, DRIFT_HASH_SKIP (plist name
#   patterns left out of the baseline hashes; default com.google.* com.microsoft.*; the orphan check still covers them).
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C   # comm needs the same sort order in a terminal and under launchd
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"

BASE="${DRIFT_BASELINE:-$HOME/.local/state/m5-drift/baseline}"
PLIST_DIRS=(${=DRIFT_PLIST_DIRS:-/Library/LaunchDaemons /Library/LaunchAgents $HOME/Library/LaunchAgents})
CADDY_ROOT="${CADDY_ROOT:-/opt/homebrew/var/lib/caddy/pki/authorities/local/root.crt}"
KEYCHAIN="${DRIFT_KEYCHAIN:-/Library/Keychains/System.keychain}"
OWUI_ERR_LOG="${OWUI_ERR_LOG:-/usr/local/var/open-webui/serve.stderr.log}"
OWUI_PLIST="${OWUI_PLIST:-/Library/LaunchDaemons/com.openwebui.serve.plist}"
REJ_STATE="${DRIFT_REJ_STATE:-$HOME/.local/state/m5-drift/rejections}"

# A job is an orphan when the program it runs, or the script an interpreter runs, no longer exists. LM Studio's
# autoload daemon was one: RunAtLoad, failing at every boot, and invisible to any listener check.
orphans() {
  setopt local_options null_glob
  local p label prog exe a i
  local -a pa rest
  for p in $^PLIST_DIRS/*.plist; do
    if [[ ! -r "$p" ]]; then print "WARN: cannot read $p (drift check skipped it)"; continue; fi
    label=$(plutil -extract Label raw -o - "$p" 2>/dev/null); : ${label:=${p:t:r}}
    prog=$(plutil -extract Program raw -o - "$p" 2>/dev/null)
    pa=(); i=0
    while a=$(plutil -extract ProgramArguments.$i raw -o - "$p" 2>/dev/null); do pa+=("$a"); (( i++ )); done
    exe="${prog:-${pa[1]}}"
    if [[ -z "$exe" ]]; then
      plutil -lint "$p" >/dev/null 2>&1 || print "WARN: cannot parse $p (drift check skipped it)"
      continue      # a valid plist with no program runs nothing, so it cannot be an orphan
    fi
    if [[ "$exe" == /* && ! -x "$exe" ]]; then
      print "DRIFT: orphan job $label: $exe is missing or not executable ($p)"; continue
    fi
    case "${exe:t}" in
      sh|bash|zsh|dash|python|python3|perl|ruby|node|osascript)
        rest=("${(@)pa[2,-1]}")
        for a in "${rest[@]}"; do
          [[ "$a" == -c ]] && break           # inline command string: nothing to test
          [[ "$a" == -* ]] && continue
          if [[ "$a" == /* && ! -e "$a" ]]; then print "DRIFT: orphan job $label: script $a is missing ($p)"; fi
          break
        done ;;
    esac
  done
}

# One fact per line, sorted. Listener lines say wildcard/specific + port (never an address), so a baseline holds no LAN IP.
facts() {
  setopt local_options null_glob
  local p pat sk; local -a skip
  sk="${DRIFT_HASH_SKIP:-com.google.* com.microsoft.*}"; skip=(${=sk})   # vendor updaters rewrite their own plists
  netstat -an -p tcp -W 2>/dev/null | awk '$6 == "LISTEN" {
      a = $4; n = split(a, x, "."); port = x[n]; sub(/\.[^.]*$/, "", a)
      if (a ~ /^127\./ || a == "::1" || port + 0 >= 49152) next
      print "listen " (a == "*" ? "wildcard" : "specific") " " port }'
  for p in $^PLIST_DIRS/*.plist; do
    for pat in $skip; do [[ "${p:t}" == ${~pat} ]] && continue 2; done
    [[ -r "$p" ]] && print "plist $p $(shasum -a 256 < "$p" | cut -d' ' -f1)"
  done
  [[ -r "$CADDY_ROOT" ]] && print "caddy-root $(caddy_root_hash)"
  caddy_keychain_hashes | sed 's/^/keychain-caddy /'
}

caddy_root_hash() {
  openssl x509 -in "$CADDY_ROOT" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
}
caddy_keychain_hashes() {
  command -v security >/dev/null 2>&1 || return 0
  security find-certificate -a -c "Caddy Local Authority" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-256 hash:/ {print toupper($3)}'
}

# A Caddy root the keychain trusts that is not the one Caddy serves from (two roots sharing a name look identical).
caddy_check() {
  [[ -r "$CADDY_ROOT" ]] || return 0
  local live h; local -a kc
  live=$(caddy_root_hash); [[ -n "$live" ]] || { print "WARN: cannot hash $CADDY_ROOT"; return 0; }
  kc=(${(f)"$(caddy_keychain_hashes)"})
  (( ${kc[(Ie)$live]} )) || print "DRIFT: the live Caddy root ${live[1,8]} is not in $KEYCHAIN"
  for h in $kc; do
    [[ "$h" == "$live" ]] || print "DRIFT: stale Caddy root ${h[1,8]} is trusted in $KEYCHAIN (live root is ${live[1,8]})"
  done
}

# Origins Open WebUI refused since the last check. The handshake in m5-health.sh only tries the origins in
# OWUI_ORIGINS; a browser using an origin nobody listed shows up only here. The health script's own control origin
# (example.invalid) is refused on purpose every run, so it is not counted. A shorter log (rotated) resets the count.
rejections() {
  [[ -r "$OWUI_ERR_LOG" ]] || { print "WARN: cannot read $OWUI_ERR_LOG (rejection check skipped)"; return 0 }
  local all cur prev=0 had=0 new
  all=$(grep 'is not an accepted origin' "$OWUI_ERR_LOG" | grep -v 'example\.invalid')
  cur=0; [[ -n "$all" ]] && cur=$(print -r -- "$all" | wc -l | tr -d ' ')
  [[ -f "$REJ_STATE" ]] && { prev=$(<"$REJ_STATE"); had=1 }
  [[ "$prev" == <-> ]] || had=0
  mkdir -p "${REJ_STATE:h}"; print -r -- "$cur" > "$REJ_STATE"
  (( had )) || return 0      # first run only records the count: old lines are not news
  (( cur > prev )) || return 0
  new=$(print -r -- "$all" | tail -n +$(( prev + 1 )) | sed 's/ is not an accepted origin.*//; s/.* //' | sort -u | tr '\n' ' ')
  print "DRIFT: Open WebUI refused $(( cur - prev )) request(s) from unlisted origin(s): ${new% } (add to the plist CORS_ALLOW_ORIGIN and OWUI_ORIGINS, then bootout, wait, bootstrap)"
}

# Origins the plist accepts that m5-health.sh never probes. The two lists stay independent on purpose; this only
# makes the gap visible.
origin_coverage() {
  [[ -n "${OWUI_ORIGINS:-}" ]] || return 0
  local cors o; local -a list
  cors=$(plutil -extract EnvironmentVariables.CORS_ALLOW_ORIGIN raw -o - "$OWUI_PLIST" 2>/dev/null) || return 0
  list=(${(s:;:)cors})
  for o in $list; do
    (( ${${=OWUI_ORIGINS}[(Ie)$o]} )) || print "WARN: $OWUI_PLIST accepts $o but OWUI_ORIGINS does not probe it"
  done
}

case "${1:-check}" in
  show) facts | sort -u ;;
  snapshot)
    mkdir -p "${BASE:h}" && facts | sort -u > "$BASE" && print "baseline saved: $(wc -l < "$BASE" | tr -d ' ') facts in $BASE" ;;
  check)
    orphans
    caddy_check
    rejections
    origin_coverage
    if [[ -f "$BASE" ]]; then
      cur=$(facts | sort -u)
      comm -23 "$BASE" <(print -r -- "$cur") | sed 's/^/DRIFT: gone since baseline: /'
      comm -13 "$BASE" <(print -r -- "$cur") | sed 's/^/DRIFT: new since baseline: /'
    else
      print "WARN: no drift baseline yet: review 'm5-drift.sh show', then run 'm5-drift.sh snapshot'"
    fi ;;
  *) print "usage: m5-drift.sh [check|snapshot|show]" >&2 ;;
esac
exit 0
