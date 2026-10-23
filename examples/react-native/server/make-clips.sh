#!/usr/bin/env bash
# Makes the example's clips in ../clips (git-ignored): a coloured disc with a
# word on a transparent background, in the two files the players take.
#
# - <name>.mov: HEVC with alpha, for iOS, written by Apple's encoder
#   (hevc-alpha.swift), so this runs on a Mac. Colour is premultiplied by
#   alpha, as Core Animation draws it.
# - <name>.mp4: stacked, colour above and transparency below, for Android.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/.." && pwd)/clips"
FONT=/System/Library/Fonts/Supplemental/Arial\ Rounded\ Bold.ttf
SIZE=256
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O "$HERE/hevc-alpha.swift" -o "$TMP/hevc-alpha"

clip() { # name colour word seconds radius-expression
  local name=$1 colour=$2 word=$3 seconds=$4 radius=$5
  local graph="[0]drawtext=fontfile='$FONT':text='$word':fontcolor=white:fontsize=60:x=(w-tw)/2:y=(h-th)/2[c];"
  graph+="[1]format=gray,geq=lum='255*lte(hypot(X-W/2\,Y-H/2)\,$radius)'[a]"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=$colour:s=${SIZE}x${SIZE}:r=30:d=$seconds" \
    -f lavfi -i "color=c=black:s=${SIZE}x${SIZE}:r=30:d=$seconds" \
    -filter_complex "$graph;[c][a]alphamerge,premultiply=inplace=1,format=bgra[v]" -map "[v]" \
    -f rawvideo -pix_fmt bgra - | "$TMP/hevc-alpha" "$OUT/$name.mov" $SIZE $SIZE 30
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=$colour:s=${SIZE}x${SIZE}:r=30:d=$seconds" \
    -f lavfi -i "color=c=black:s=${SIZE}x${SIZE}:r=30:d=$seconds" \
    -filter_complex "$graph;[c]format=yuv420p[cc];[a]format=yuv420p[aa];[cc][aa]vstack,format=yuv420p[v]" -map "[v]" \
    -c:v libx264 -profile:v baseline -g 30 -an -movflags +faststart "$OUT/$name.mp4"
}

# The disc breathes on the pose clips and grows or shrinks on the moves.
clip idle 0xF95D02 idle 1.0 '100+8*sin(2*PI*T)'
clip celebrate 0xC94B8C 'yay!' 1.0 '104+20*sin(4*PI*T)'
clip hi 0x1F9D55 'hi!' 0.8 '100+12*sin(2.5*PI*T)'
clip to-work 0x7A5AF8 '...' 0.5 '100-40*T'
clip work 0x2D6CDF work 1.0 '80+4*sin(4*PI*T)'
clip to-idle 0x7A5AF8 '...' 0.5 '80+40*T'
ls -l "$OUT"
