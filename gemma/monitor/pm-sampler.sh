#!/bin/bash
# pm-sampler.sh — run by the root LaunchDaemon com.gemma.powermetrics.
# powermetrics needs root, so this small loop runs it and leaves the latest sample in a
# world-readable file; the web monitor (com.gemma.monitor, not root) only reads that file.
# One 5 s sample every ~15 s: GPU residency, CPU/GPU/ANE power, thermal pressure.
set -u
OUT="${1:-/usr/local/var/gemma-monitor/powermetrics.txt}"
mkdir -p "$(dirname "$OUT")"
chmod 755 "$(dirname "$OUT")"
while true; do
  if /usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal -n 1 -i 5000 -f text > "$OUT.tmp" 2>/dev/null; then
    chmod 644 "$OUT.tmp"
    mv -f "$OUT.tmp" "$OUT"
  fi
  sleep 10
done
