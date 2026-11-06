#!/bin/zsh
# m5-airplay-log.sh - record who connects to the AirPlay Receiver ports (TCP 5000 and 7000), so that days from
# now you can decide from evidence whether anything uses it.
#   m5-airplay-log.sh            take one sample (the LaunchAgent runs this every 60 s)
#   m5-airplay-log.sh summary    print since when it has been sampling, the counts, and the log
# The log gets a line when a connection from another machine appears (CONNECTED) or disappears (ENDED), never one
# per sample. Limits: TCP only, and a connection shorter than the 60 s interval can fall between two samples, so
# "no connection logged" means none lasted long enough to be seen, not that none ever happened.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
DIR="${AIRPLAY_STATE:-$HOME/.local/state/m5-airplay}"
LOG="${AIRPLAY_LOG:-$HOME/Library/Logs/m5-airplay.log}"
mkdir -p "$DIR" "${LOG:h}"

case "${1:-sample}" in
  summary)
    if [[ ! -f "$DIR/since" ]]; then print "no samples yet"; exit 0; fi
    print "sampling since:            $(<"$DIR/since")"
    print "samples taken:             $(<"$DIR/samples")"
    print "samples with a connection: $(<"$DIR/hits")"
    print "log ($LOG):"; [[ -s "$LOG" ]] && sed 's/^/  /' "$LOG" || print "  (empty: no connection seen)" ;;
  sample)
    [[ -f "$DIR/since" ]] || print "$(date '+%F %T')" > "$DIR/since"
    local cur prev="" l n=0 h=0
    local -a ca pa
    cur=$(netstat -an -p tcp -W 2>/dev/null | awk '$6 == "ESTABLISHED" && $4 ~ /\.(5000|7000)$/ && $5 !~ /^127\./ && $5 !~ /^::1\./ {print $5 " -> " $4}' | sort -u)
    [[ -f "$DIR/last" ]] && prev=$(<"$DIR/last")
    [[ -f "$DIR/samples" ]] && n=$(<"$DIR/samples")
    [[ -f "$DIR/hits" ]] && h=$(<"$DIR/hits")
    ca=(${(f)cur}); pa=(${(f)prev})
    for l in $ca; do (( ${pa[(Ie)$l]} )) || print "$(date '+%F %T') CONNECTED $l" >> "$LOG"; done
    for l in $pa; do (( ${ca[(Ie)$l]} )) || print "$(date '+%F %T') ENDED $l" >> "$LOG"; done
    print -r -- "$cur" > "$DIR/last"
    print $(( n + 1 )) > "$DIR/samples"
    (( ${#ca} )) && h=$(( h + 1 ))
    print "$h" > "$DIR/hits" ;;
  *) print "usage: m5-airplay-log.sh [sample|summary]" >&2 ;;
esac
exit 0
