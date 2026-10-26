#!/usr/bin/env bash
# Builds dav1d, VideoLAN's AV1 decoder, for iPhone, iPad, Mac, Mac Catalyst
# and Apple Vision Pro, and makes apple/dav1d.xcframework: its static library
# per platform, with the dav1d headers and a module map, so Swift can
# `import Dav1d`. The Apple player decodes AV1 with it on devices that have no
# AV1 hardware decoder.
#
#   scripts/build-dav1d-apple.sh
#
# It downloads the dav1d release pinned below from VideoLAN, checks its
# SHA-256, and builds it with meson and ninja from .toolchain/meson, which
# scripts/setup.sh installs. Release build, static library, 8-bit only (every
# Masko clip is 8-bit), no command-line tools and no tests. The minimum OS
# versions are the ones of Package.swift. The visionOS slices are left out
# when this Xcode has no visionOS SDK.
#
# The arm64 slices keep dav1d's assembly. The x86_64 slices (Intel Mac, the
# x86_64 iOS simulator, Mac Catalyst on Intel) build with -Denable_asm=false:
# dav1d's x86 assembly needs nasm, which this build does not install, so they
# decode with dav1d's C code only, which is slower.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The release tarball of the tag 1.5.4 (commit 54706fc6bc0c), from
# https://downloads.videolan.org/pub/videolan/dav1d/. After a version change,
# run `node scripts/third-party-notices.mjs` (it reads DAV1D_VERSION here).
DAV1D_VERSION="1.5.4"
DAV1D_SHA256="686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
# scripts/setup.sh installs these versions into .toolchain/meson.
WANT_MESON="1.12.1"
WANT_NINJA="1.13.2"

# The same minimum versions as Package.swift.
IOS_MIN=15.0
MACOS_MIN=13.0
XROS_MIN=1.0

MESON_ENV="$ROOT/.toolchain/meson"
installed() { "$MESON_ENV/bin/python" -c "import importlib.metadata as m; print(m.version('$1'))" 2>/dev/null || true; }
if [[ "$(installed meson)" != "$WANT_MESON" || "$(installed ninja)" != "$WANT_NINJA" ]]; then
  echo "error: this build needs meson $WANT_MESON and ninja $WANT_NINJA in .toolchain/meson; run scripts/setup.sh" >&2
  exit 1
fi
export PATH="$MESON_ENV/bin:$PATH"

WORK="$ROOT/target/dav1d"
TARBALL="$WORK/dav1d-$DAV1D_VERSION.tar.xz"
SRC="$WORK/dav1d-$DAV1D_VERSION"
mkdir -p "$WORK"

if [[ ! -f "$TARBALL" ]] || [[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$DAV1D_SHA256" ]]; then
  echo "==> download dav1d $DAV1D_VERSION"
  curl --proto '=https' --tlsv1.2 -sSfL -o "$TARBALL.part" \
    "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
have_sha="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$have_sha" != "$DAV1D_SHA256" ]]; then
  echo "error: $TARBALL has SHA-256 $have_sha, not $DAV1D_SHA256" >&2
  exit 1
fi
rm -rf "$SRC"
tar -xf "$TARBALL" -C "$WORK"

# THIRD_PARTY_NOTICES.md carries this license text, from scripts/licenses/.
if ! cmp -s "$SRC/COPYING" scripts/licenses/dav1d-COPYING.txt; then
  echo "error: dav1d $DAV1D_VERSION has another COPYING than scripts/licenses/dav1d-COPYING.txt." >&2
  echo "error: copy it there and run \`node scripts/third-party-notices.mjs\`." >&2
  exit 1
fi

# One slice per platform and architecture: name, SDK, clang target.
SLICES=(
  "ios-arm64 iphoneos arm64-apple-ios$IOS_MIN"
  "ios-simulator-arm64 iphonesimulator arm64-apple-ios$IOS_MIN-simulator"
  "ios-simulator-x86_64 iphonesimulator x86_64-apple-ios$IOS_MIN-simulator"
  "macos-arm64 macosx arm64-apple-macos$MACOS_MIN"
  "macos-x86_64 macosx x86_64-apple-macos$MACOS_MIN"
  "maccatalyst-arm64 macosx arm64-apple-ios$IOS_MIN-macabi"
  "maccatalyst-x86_64 macosx x86_64-apple-ios$IOS_MIN-macabi"
)
VISIONOS=0
if xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 && xcrun --sdk xrsimulator --show-sdk-path >/dev/null 2>&1; then
  VISIONOS=1
  SLICES+=(
    "xros-arm64 xros arm64-apple-xros$XROS_MIN"
    "xros-simulator-arm64 xrsimulator arm64-apple-xros$XROS_MIN-simulator"
  )
else
  echo "warning: this Xcode has no visionOS SDK; apple/dav1d.xcframework will have no visionOS slices" >&2
fi

build_slice() {
  local name="$1" sdk="$2" triple="$3"
  local arch="${triple%%-*}"
  local dir="$WORK/$name"
  local sysroot cc ar strip cpu_family system asm
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  ar="$(xcrun --sdk "$sdk" --find ar)"
  strip="$(xcrun --sdk "$sdk" --find strip)"
  case "$arch" in
    arm64) cpu_family=aarch64 asm=true ;;
    # No nasm here, so no x86 assembly: see the top of this file.
    x86_64) cpu_family=x86_64 asm=false ;;
    *) echo "error: no dav1d settings for $arch" >&2; exit 1 ;;
  esac
  # dav1d knows darwin, ios and tvos as Apple systems (one of them gives its
  # assembly symbols their leading underscore), so Mac Catalyst and visionOS
  # build as ios. The clang target is what sets the platform of the objects.
  if [[ "$sdk" == macosx && "$triple" != *-macabi ]]; then system=darwin; else system=ios; fi

  echo "==> dav1d $DAV1D_VERSION for $name ($triple)"
  rm -rf "$dir"
  mkdir -p "$dir"
  # Source paths can end up in the library: name them from the release, never
  # from this machine's folders.
  cat >"$dir/cross.ini" <<EOF
[binaries]
c = '$cc'
ar = '$ar'
strip = '$strip'

[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sysroot', '-ffile-prefix-map=$SRC=dav1d-$DAV1D_VERSION', '-ffile-prefix-map=$dir=dav1d-build']
c_link_args = ['-target', '$triple', '-isysroot', '$sysroot']

[properties]
needs_exe_wrapper = true

[host_machine]
system = '$system'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
  meson setup "$dir/build" "$SRC" \
    --cross-file "$dir/cross.ini" \
    --prefix "$dir/install" --libdir lib \
    --buildtype release \
    -Ddefault_library=static \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false \
    -Dbitdepths="['8']" \
    -Denable_asm="$asm" >"$dir/setup.log" || { cat "$dir/setup.log" >&2; exit 1; }
  ninja -C "$dir/build" >"$dir/build.log" || { cat "$dir/build.log" >&2; exit 1; }
  meson install -C "$dir/build" --no-rebuild --quiet

  local lib="$dir/install/lib/libdav1d.a"
  if LC_ALL=C grep -a -q -e "$ROOT/" -e "$HOME/" "$lib"; then
    echo "error: $lib still contains a path on this machine" >&2
    exit 1
  fi
}

for slice in "${SLICES[@]}"; do
  # shellcheck disable=SC2086
  build_slice $slice
done

LIB=libdav1d.a
OUT="$WORK/xcframework"
rm -rf "$OUT"
mkdir -p "$OUT/macos" "$OUT/ios-simulator" "$OUT/maccatalyst"
lib() { echo "$WORK/$1/install/lib/$LIB"; }

# One header folder for every slice. The headers keep their usual folder,
# dav1d/, so C code still includes <dav1d/dav1d.h>, and the module map sits in
# it, so it never collides with another package's module.modulemap. Clang
# finds the module Dav1d there: folders under a header path are searched for
# module maps.
HEADERS="$OUT/headers"
mkdir -p "$HEADERS"
cp -R "$WORK/macos-arm64/install/include/dav1d" "$HEADERS/"
cat >"$HEADERS/dav1d/module.modulemap" <<'EOF'
module Dav1d {
    header "dav1d.h"
    export *
}
EOF

echo "==> universal libraries"
lipo -create "$(lib macos-arm64)" "$(lib macos-x86_64)" -output "$OUT/macos/$LIB"
lipo -create "$(lib ios-simulator-arm64)" "$(lib ios-simulator-x86_64)" -output "$OUT/ios-simulator/$LIB"
lipo -create "$(lib maccatalyst-arm64)" "$(lib maccatalyst-x86_64)" -output "$OUT/maccatalyst/$LIB"

LIBRARIES=(
  "$OUT/macos/$LIB"
  "$(lib ios-arm64)"
  "$OUT/ios-simulator/$LIB"
  "$OUT/maccatalyst/$LIB"
)
if [[ "$VISIONOS" == 1 ]]; then
  LIBRARIES+=("$(lib xros-arm64)" "$(lib xros-simulator-arm64)")
fi

echo "==> apple/dav1d.xcframework"
XCFRAMEWORK="$ROOT/apple/dav1d.xcframework"
rm -rf "$XCFRAMEWORK"
args=()
for library in "${LIBRARIES[@]}"; do
  args+=(-library "$library" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK"

for slice in "$XCFRAMEWORK"/*/; do
  printf '  %-32s %10s bytes  %s\n' "$(basename "$slice")" "$(stat -f %z "$slice$LIB")" \
    "$(lipo -archs "$slice$LIB")"
done
echo "Built $XCFRAMEWORK (dav1d $DAV1D_VERSION)"
