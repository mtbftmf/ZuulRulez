#!/bin/zsh
# m5-report.sh - write ONE redacted, size-capped diagnostic file to attach to a chat instead of pasting terminal output.
#   m5-report.sh                         every section
#   m5-report.sh repo bin gate           only those sections: sys repo bin gate llm mem logs health drift
#   m5-report.sh --lines 80 logs         cap each command at 80 lines (default 40)
#   m5-report.sh --run 'ls -lt ~/Library/Logs | head'    add an ad-hoc read-only command (repeatable; alone it runs no sections)
# Read-only. It runs the commands in this file plus any --run you give it. It never runs refresh (that asks for a password),
# install, push or anything that writes, and writes nothing but the report in your home folder.
# Redaction: the values of M5_CLONE_VOL (from ~/.config/m5-secops.env), $HOME, your user name and this machine's host names are
# replaced as whole strings (never by word splitting), then LAN IPv4 addresses, /Users/<name> paths and *.local names by pattern.
# The report ends with a leak check that says what it scanned and what it did not. If that check finds anything the
# report is saved as *.REVIEW.txt: read it before you attach it.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
setopt pipefail

ENVF=${M5_REPORT_ENV:-$HOME/.config/m5-secops.env}
[[ -r $ENVF ]] && { set -a; source "$ENVF"; set +a }

MAXL=40; typeset -a SECT EXTRA
while (( $# )); do
  case $1 in
    --lines) [[ ${2:-} == <-> ]] || { print -u2 "--lines needs a number"; exit 2 }; MAXL=$2; shift 2 ;;
    --run)   [[ -n ${2:-} ]] || { print -u2 "--run needs a command"; exit 2 }; EXTRA+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    sys|repo|bin|gate|llm|mem|logs|health|drift) SECT+=$1; shift ;;
    *) print -u2 "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
done
(( ${#SECT} + ${#EXTRA} )) || SECT=(sys repo bin gate llm mem logs health drift)

# ---------------------------------------------------------------- redaction ----
typeset -a SECRETS
add(){ (( ${#2} >= 3 )) && SECRETS+=("$1|$2"); return 0 }
add '<VOLUME>' "${M5_CLONE_VOL:-}"
add '<HOME>'   "$HOME"
add '<USER>'   "$(id -un)"
add '<HOST>'   "$(scutil --get LocalHostName 2>/dev/null || true)"
add '<HOST>'   "$(hostname -s 2>/dev/null || true)"
add '<HOST>'   "$(hostname 2>/dev/null || true)"

mask(){
  local line pair tok val
  while IFS= read -r line; do
    for pair in $SECRETS; do tok=${pair%%|*}; val=${pair#*|}; line=${line//"$val"/$tok}; done
    print -r -- "$line"
  done | sed -E \
    -e 's#/Users/[^/[:space:]<]+#/Users/<USER>#g' \
    -e 's#(^|[^0-9.])192\.168\.[0-9]+\.[0-9]+#\1<LAN-IP>#g' \
    -e 's#(^|[^0-9.])10\.[0-9]+\.[0-9]+\.[0-9]+#\1<LAN-IP>#g' \
    -e 's#(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+#\1<LAN-IP>#g' \
    -e 's#[A-Za-z0-9-]+\.local#<HOST-LOCAL>#g'
}

# ------------------------------------------------------------------ helpers ----
section(){ print -r -- ""; print -r -- "=== $1" }
run(){
  local label=$1 out rc n; shift
  print -r -- "--- $label"
  out=$("$@" 2>&1); rc=$?
  if [[ -z $out ]]; then print -r -- "(no output)"
  else
    n=$(print -r -- "$out" | wc -l | tr -d ' ')
    print -r -- "$out" | head -n $MAXL
    (( n > MAXL )) && print -r -- "(truncated: $n lines, showing $MAXL)"
  fi
  (( rc )) && print -r -- "(exit $rc)"
  return 0
}

sys_report(){ sw_vers -productVersion; uname -m; uptime }
repo_head(){ git -C "$HOME/ZuulRulez" --no-pager log --oneline --decorate -3 }
repo_status(){ git -C "$HOME/ZuulRulez" status --porcelain }
repo_ahead(){ git -C "$HOME/ZuulRulez" rev-list --count origin/MacLLM..HEAD }
bin_report(){
  local f b r; local -a files links dirs diff norepo; local m=0
  files=($HOME/bin/*(N.)); links=($HOME/bin/*(N@)); dirs=($HOME/bin/*(N/))
  for f in $files; do
    b=${f:t}; r=$HOME/ZuulRulez/m5/bin/$b
    if   [[ ! -e $r ]]; then norepo+=$b
    elif cmp -s "$f" "$r"; then (( m++ ))
    else diff+=$b; fi
  done
  print "real=${#files} links=${#links} dirs=${#dirs}"
  print "MATCH=$m DIFFER=${#diff} NO-REPO=${#norepo}"
  print "DIFFER: ${(j:, :)diff}"
  print "NO-REPO: ${(j:, :)norepo}"
}
gate_report(){ "$HOME/bin/m5-secops.sh" gate }
llm_one(){
  local port=$1
  curl -fsS --max-time 5 "http://127.0.0.1:$port/health"; print
  curl -fsS --max-time 5 "http://127.0.0.1:$port/metrics.json" | python3 -c "import sys,json; g=json.load(sys.stdin)['gauges']; print({k: g.get(k) for k in ('memory_mb','mlx_active_bytes','ngram_warm_bytes','gpu_utilization_pct','requests_running')})"
}
llm_args(){ ps -axo command | grep '[m]lx-serve' | grep -o -e '--port [0-9]*' -e '--ctx-size [0-9]*' }
mem_report(){ sysctl vm.swapusage iogpu.wired_limit_mb; memory_pressure | tail -1 }
log_tail(){ tail -n $MAXL "$HOME/Library/Logs/mlx-serve.log" }
log_list(){ ls -lt "$HOME/Library/Logs" | head -15 }
health_report(){ "$HOME/bin/m5-health.sh" }
drift_report(){ "$HOME/bin/m5-drift.sh"; print "m5-drift.sh exit $?" }

body(){
  print -r -- "m5-report $(date '+%Y-%m-%d %H:%M:%S %Z')   sections: ${SECT[*]:-none}   per-command cap: $MAXL lines"
  print -r -- "redaction active: ${(j: :)${(@)SECRETS%%|*}} plus LAN IPv4, user-path and host-name patterns"
  local s c
  for s in $SECT; do
    case $s in
      sys)    section "system";           run "macOS, arch, uptime" sys_report ;;
      repo)   section "repo";             run "head" repo_head; run "status --porcelain" repo_status; run "commits ahead of origin/MacLLM (no fetch)" repo_ahead ;;
      bin)    section "~/bin vs repo m5/bin"; run "classification" bin_report ;;
      gate)   section "security gate";    run "m5-secops.sh gate (does not run refresh)" gate_report ;;
      llm)    section "models";           run "Flash :11234" llm_one 11234; run "Gemma :11235" llm_one 11235; run "serve args" llm_args ;;
      mem)    section "memory";           run "swap, wired limit, pressure" mem_report ;;
      logs)   section "logs";             run "mlx-serve.log tail" log_tail; run "newest files in ~/Library/Logs" log_list ;;
      health) section "m5-health.sh";     run "m5-health.sh" health_report ;;
      drift)  section "drift";            run "m5-drift.sh (silent means no drift)" drift_report ;;
    esac
  done
  if (( ${#EXTRA} )); then
    section "ad-hoc"
    for c in $EXTRA; do run "run: $c" zsh -c "$c"; done
  fi
}

# ------------------------------------------------------------------- write ----
OUT=$HOME/m5-report-$(date +%Y%m%d-%H%M%S).txt
tmp=$(mktemp "$HOME/.m5-report.XXXXXX") || { print -u2 "cannot create a temp file in \$HOME"; exit 1 }
body | mask > "$tmp"

c_users=$(grep -E '/Users/' "$tmp" | grep -cvE '/Users/(<USER>|Shared)')
c_ip=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$tmp" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255' | grep -cvxE '127\.0\.0\.1|0\.0\.0\.0')
c_local=$(grep -cE '\.local' "$tmp")
c_mac=$(grep -ciE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$tmp")
c_lit=0; for pair in $SECRETS; do (( c_lit += $(grep -cF -- "${pair#*|}" "$tmp") )); done
bad=$(( c_users + c_ip + c_local + c_mac + c_lit ))
{ print -r -- ""
  print -r -- "leak_check: /Users paths not <USER> or Shared=$c_users, IPv4 other than 127.0.0.1/0.0.0.0=$c_ip, .local names=$c_local, MAC addresses=$c_mac, literal redaction values=$c_lit."
  print -r -- "leak_check does NOT cover: serial numbers, UUIDs, tokens, or anything that is not in the redaction list." } >> "$tmp"

if (( bad )); then OUT=${OUT%.txt}.REVIEW.txt; fi
chmod 600 "$tmp" && mv "$tmp" "$OUT" || { print -u2 "could not write $OUT"; exit 1 }
print -r -- "wrote ${OUT/#$HOME/~} ($(wc -l < "$OUT" | tr -d ' ') lines)"
(( bad )) && print -r -- "REVIEW: the leak check found $bad item(s); read the file before attaching it."
exit 0
