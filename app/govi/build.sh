#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
GOVI_ROOT="$PWD"
GOVI_ZIG="$(./govi/bootstrap-zig.sh)"
mkdir -p .build dist
# Zig 0.14.1 cannot link against SDKs newer than macOS 26 (it reports undefined
# libSystem symbols such as _abort). When the selected Xcode is newer, Zig uses
# the Command Line Tools SDK and a shim keeps xcodebuild on the selected Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] &&
   (( ${$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)%%.*:-0} > 26 )); then
  mkdir -p .build/xcode-shim
  print -r -- $'#!/bin/sh\nunset DEVELOPER_DIR SDKROOT\nexec /usr/bin/xcodebuild "$@"' > .build/xcode-shim/xcodebuild
  chmod +x .build/xcode-shim/xcodebuild
  export PATH="$PWD/.build/xcode-shim:$PATH" DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
# Populate the same hash from the official archive; Zig 0.14's git transport
# intermittently fails against Codeberg. No dependency sources are modified.
if [[ ! -d .build/zig-cache/p/zg-0.13.4-AAAAAGiZ7QLz4pvECFa_wG4O4TP4FLABHHbemH2KakWM ]]; then
  "$GOVI_ZIG" fetch --global-cache-dir .build/zig-cache \
    https://codeberg.org/atman/zg/archive/4a002763419a34d61dcbb1f415821b83b9bf8ddc.tar.gz
fi
"$GOVI_ZIG" build -Doptimize=ReleaseFast -Dxcframework-target=native \
  -Demit-themes=true --global-cache-dir .build/zig-cache "$@"
if [[ -d dist/Govi.app ]]; then
  rm -rf .build/Govi-previous.app
  mv dist/Govi.app .build/Govi-previous.app
fi
ditto .build/macos/ReleaseLocal/Ghostty.app dist/Govi.app
# Copy the current resources rather than leaving removed font files in a bundle
# assembled by an incremental Xcode build.
rm -rf dist/Govi.app/Contents/Resources/Govi
ditto govi/Govi dist/Govi.app/Contents/Resources/Govi
mkdir -p dist/Govi.app/Contents/Resources/Govi/Licenses
cp LICENSE dist/Govi.app/Contents/Resources/Govi/Licenses/Ghostty-LICENSE.txt
cp README.md dist/Govi.app/Contents/Resources/Govi/README.md
cp govi/SCOPE.md dist/Govi.app/Contents/Resources/Govi/SCOPE.md
# The upstream build retains its internal executable name for compatibility
# with shell integration. The product name and bundle identity are Govi's.
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Govi' dist/Govi.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Govi' dist/Govi.app/Contents/Info.plist
if [[ -f govi/Govi/Govi.icns ]]; then
  cp govi/Govi/Govi.icns dist/Govi.app/Contents/Resources/Govi.icns
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Govi.icns' dist/Govi.app/Contents/Info.plist
fi
# Ad-hoc signatures change with every build, so macOS forgets Keychain
# "Always Allow" grants. Prefer a stable local identity when one exists.
sign_identity=${GOVI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)}
codesign --force --deep --sign "${sign_identity:--}" dist/Govi.app
print "Built $GOVI_ROOT/dist/Govi.app"
