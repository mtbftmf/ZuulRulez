#!/bin/zsh
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

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
owui=$(curl -s --cacert "$HOME/spdif-share/caddy-internal-root.crt" -o /dev/null -w "%{http_code}" --max-time 4 https://192.168.68.105:8443/)
print "  owui    ${owui} $( [[ "$owui" == 200 ]] && echo ok || echo CHECK )"
rule

print "[power]"
pmset -g custom 2>/dev/null | grep -E '^(AC Power|Battery)|sleep|powernap|autorestart|standby|ttyskeepawake' | sed 's/^/  /'
rule
