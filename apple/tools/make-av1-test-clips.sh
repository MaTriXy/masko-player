#!/usr/bin/env bash
# Writes the stacked AV1 clips the real-video tests play, beside the HEVC ones
# of make-test-clips.swift:
#
#   apple/tools/make-av1-test-clips.sh apple/Tests/MaskoPlayerTests/Clips
#
# The same 96 x 96 boxes at 30 frames a second, stacked: colour above,
# transparency below. The top-left corner is always transparent and the
# centre always opaque. loop-av1.mp4 carries a short tone, as a voiced clip.
set -euo pipefail
OUT="$1"

clip() { # name colour frames [sound]
  local seconds audio_in=() audio_out=()
  seconds="$(awk "BEGIN { print $3 / 30 }")"
  if [[ "${4:-}" == "sound" ]]; then
    audio_in=(-f lavfi -i "sine=frequency=440:duration=$seconds")
    audio_out=(-map 2:a -c:a aac -b:a 64k)
  fi
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=$2:s=96x96:r=30:d=$seconds" \
    -f lavfi -i "color=c=black:s=96x96:r=30:d=$seconds" \
    ${audio_in[@]+"${audio_in[@]}"} \
    -filter_complex "[1]drawbox=x=16:y=16:w=64:h=64:color=white:t=fill[a];[0][a]vstack,format=yuv420p[v]" \
    -map "[v]" -frames:v "$3" -c:v libaom-av1 -cpu-used 6 -crf 30 -b:v 0 -g 30 \
    ${audio_out[@]+"${audio_out[@]}"} -t "$seconds" -movflags +faststart "$OUT/$1.mp4"
}

clip loop-av1 0xF95D02 15 sound
clip move-av1 0xC94B8C 12
ls -l "$OUT"
