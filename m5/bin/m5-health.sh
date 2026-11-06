#!/bin/zsh
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ -f "$HOME/.config/macllm.env" ]] && source "$HOME/.config/macllm.env"
# Caddy URL for the Open WebUI probe; must match the certificate's name (see env.example)
OWUI_PROBE_URL="${OWUI_PROBE_URL:-https://localhost:8443/}"

HR=$(printf '=%.0s' {1..78})
rule() { print -r -- "$HR" }

print "=== M5 Studio health  $(date '+%F %T %Z')  uptime:$(uptime | sed 's/.*up //' | cut -d, -f1 | xargs) ==="
rule

print "[display]"
system_profiler SPDisplaysDataType 2>/dev/null \
  | grep -E 'Resolution:|Main Display:|Online:|Connection Type:' | sed 's/^  */  /'
hpd5=$(log show --last 5m --predicate 'eventMessage CONTAINS "IRQ_HPD"' --style compact 2>/dev/null | grep -c IRQ_HPD)
print "  HPD last 5m: ${hpd5}"
log show --last 5m --predicate 'eventMessage CONTAINS "IRQ_HPD"' --style compact 2>/dev/null \
  | grep -oE 'device=0x[0-9a-f]+' | sort | uniq -c | sed 's/^/    /'
if (( hpd5 > 20 )); then print "  WARN: HPD climbing - dock suspect"
elif (( hpd5 > 5 )); then print "  watch: more than handshake-level"
else print "  ok: link quiet"; fi
rule

print "[audio]"
out=$(SwitchAudioSource -c -t output 2>/dev/null)
print "  output: ${out:-none}"
if [[ "$out" == *"USB SPDIF Adapter"* ]]; then
  print "  ok: Edifier chain is default (AMS must read 48,000 Hz / 2ch 24-bit - CLI cannot verify)"
else
  print "  note: not S/PDIF - keepalive is correctly idle"
fi
pgrep -fl "ffplay.*anullsrc" | sed 's/^/  /' || print "  no ffplay child"
launchctl print "gui/$(id -u)/com.ewagner.spdif-keepalive" 2>/dev/null \
  | grep -E 'state =|runs =|last exit code' | sed 's/^  */  /' \
  || print "  keepalive agent not loaded"
rule

print "[llm stack]"
for ep in "flash|http://127.0.0.1:11234/v1/models" "gemma|http://127.0.0.1:11235/v1/models"; do
  name=${ep%%|*}; url=${ep##*|}
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url")
  if [[ "$code" == 200 ]]; then print "  ${name} ${code} ok"
  else print "  ${(r:8)name}${code} DOWN"; fi
done
owui=$(curl -s --cacert "$HOME/spdif-share/caddy-internal-root.crt" -o /dev/null -w "%{http_code}" --max-time 4 "$OWUI_PROBE_URL")
print "  owui    ${owui} $( [[ "$owui" == 200 ]] && echo ok || echo CHECK )"
rule

print "[power]"
pmset -g custom 2>/dev/null | grep -E '^(AC Power|Battery)|sleep|powernap|autorestart|standby|ttyskeepawake' | sed 's/^/  /'
rule

print "[web]"
m=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:9090/)
print "  monitor9090 loopback: ${m}$([[ "$m" != 2* ]] && print '  <- monitor DOWN (direct :9090 is closed, so :9443 is dead too)')"
w=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8080/api/config)
print "  openwebui8080 loopback: ${w}$([[ "$w" != 2* ]] && print '  <- engine or UI down')"
b=$(netstat -an -p tcp -W 2>/dev/null | awk '$4 ~ /\.9090$/ && $6 == "LISTEN" && $4 !~ /^127\./ {print $4}')
print "  lan9090 closed: ${b:+REGRESSION listener on $b}${b:-no non-loopback :9090 listener}"
f=$(sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
print "  firewall: ${f:-unreadable (sudo not cached)}"
# Open WebUI streams chat over a websocket and rejects any Origin missing from CORS_ALLOW_ORIGIN, while
# /health stays 200. Handshake with each origin clients use: 101 = accepted, anything else = rejected.
owui_ws() { curl -s -o /dev/null --max-time 1 --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Origin: $1" -w '%{http_code}' "http://127.0.0.1:8080/ws/socket.io/?EIO=4&transport=websocket" }
if [[ -n "${OWUI_ORIGINS:-}" ]]; then
  for o in ${=OWUI_ORIGINS}; do
    c=$(owui_ws "$o")
    print "  ws-origin ${o}: ${c}$([[ "$c" == 101 ]] || { [[ "$c" == 000 ]] && print '  <- no response (Open WebUI down?)' || print '  <- REJECTED: chat will not stream; add it to CORS_ALLOW_ORIGIN'; })"
  done
  c=$(owui_ws "https://example.invalid")
  print "  ws-origin unlisted: ${c}$([[ "$c" == 101 ]] && print '  <- allowlist is open (wildcard CORS?)')"
else
  print "  ws-origin: skipped (set OWUI_ORIGINS in ~/.config/macllm.env)"
fi
rule
