#!/usr/bin/env bash
# Makes the stacked test clips in assets/clips: colour above, transparency
# below (white is opaque, black transparent). The left half of each mascot is
# opaque and the right half transparent, so a test can check both.
set -euo pipefail
cd "$(dirname "$0")/assets/clips"

clip() { # name colour seconds [transparency of the left half, white by default]
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=$2:s=128x128:r=30:d=$3" \
    -f lavfi -i "color=c=${4:-white}:s=64x128:r=30:d=$3" \
    -f lavfi -i "color=c=black:s=64x128:r=30:d=$3" \
    -filter_complex "[1][2]hstack[alpha];[0][alpha]vstack,format=yuv420p" \
    -c:v libx264 -profile:v baseline -preset veryslow -g 30 -an -movflags +faststart \
    "$1.mp4"
}

clip red red 1.0
clip green lime 0.6
clip blue blue 1.0
# Transparency drawn in pure red: its luma (about 0.2), not its red channel (1).
clip tint blue 1.0 red
ls -l
