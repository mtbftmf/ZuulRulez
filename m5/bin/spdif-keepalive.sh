#!/bin/zsh
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
# Hold the Cubilux S/PDIF clock only while it is the active output.
while true; do
  if [[ "$(/opt/homebrew/bin/SwitchAudioSource -c -t output)" == "USB SPDIF Adapter" ]]; then
    /opt/homebrew/bin/ffplay -nodisp -loglevel error \
      -f lavfi -i "anullsrc=r=48000:cl=stereo"
  fi
  sleep 10
done
