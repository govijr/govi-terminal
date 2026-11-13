#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
GOVI_ROOT="$PWD"
GOVI_ZIG="$(./govi/bootstrap-zig.sh)"
mkdir -p .build dist
# Zig 0.14.1 can only link against the macOS 26.0 SDK; newer SDKs make it
# report undefined libSystem symbols such as _abort and _waitpid. Zig then uses
# an older developer directory and a shim keeps xcodebuild on the selected Xcode.
# GOVI_ZIG_DEVELOPER_DIR picks that directory (CI points it at Xcode 26.0.1);
# otherwise the Command Line Tools 26 SDK is used when the selected one is newer.
zig_developer_dir=${GOVI_ZIG_DEVELOPER_DIR:-}
if [[ -z $zig_developer_dir && -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] &&
   (( ${$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)%%.*:-0} > 26 )); then
  zig_developer_dir=/Library/Developer/CommandLineTools
fi
if [[ -n $zig_developer_dir ]]; then
  mkdir -p .build/xcode-shim
  print -r -- $'#!/bin/sh\nunset DEVELOPER_DIR SDKROOT\nexec /usr/bin/xcodebuild "$@"' > .build/xcode-shim/xcodebuild
  chmod +x .build/xcode-shim/xcodebuild
  export PATH="$PWD/.build/xcode-shim:$PATH" DEVELOPER_DIR=$zig_developer_dir
fi
# Populate the same hash from the official archive; Zig 0.14's git transport
# intermittently fails against Codeberg. No dependency sources are modified.
if [[ ! -d .build/zig-cache/p/zg-0.13.4-AAAAAGiZ7QLz4pvECFa_wG4O4TP4FLABHHbemH2KakWM ]]; then
  "$GOVI_ZIG" fetch --global-cache-dir .build/zig-cache \
    https://codeberg.org/atman/zg/archive/4a002763419a34d61dcbb1f415821b83b9bf8ddc.tar.gz
fi
# Monaco powers the editor pane. The pinned release is fetched once, checked
# against the npm registry's integrity hash, and only its minified build kept.
monaco_version=0.52.2
monaco_sri=sha512-GEQWEZmfkOGLdd3XK8ryrfWz3AIP8YymVXiPHEdewrUq7mh0qrKrfHLNCXcbB6sTnMLnOZ3ztSiKcciFUkIJwQ==
monaco_dir=.build/monaco/$monaco_version
if [[ ! -f $monaco_dir/vs/loader.js ]]; then
  mkdir -p .build/monaco
  [[ -f .build/monaco/monaco.tgz ]] ||
    curl -fsSL -o .build/monaco/monaco.tgz "https://registry.npmjs.org/monaco-editor/-/monaco-editor-$monaco_version.tgz"
  if [[ "sha512-$(openssl dgst -sha512 -binary .build/monaco/monaco.tgz | base64)" != "$monaco_sri" ]]; then
    rm -f .build/monaco/monaco.tgz
    print -u2 "The Monaco download doesn't match its published checksum."
    exit 1
  fi
  rm -rf "$monaco_dir" "$monaco_dir.tmp" && mkdir -p "$monaco_dir.tmp"
  tar -xzf .build/monaco/monaco.tgz -C "$monaco_dir.tmp" package/min/vs package/LICENSE
  mkdir -p "$monaco_dir"
  mv "$monaco_dir.tmp/package/min/vs" "$monaco_dir/vs"
  mv "$monaco_dir.tmp/package/LICENSE" "$monaco_dir/LICENSE"
  rm -rf "$monaco_dir.tmp" .build/monaco/monaco.tgz
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
cp ../LICENSE dist/Govi.app/Contents/Resources/Govi/Licenses/Govi-LICENSE.txt
cp ../NOTICE dist/Govi.app/Contents/Resources/Govi/Licenses/Govi-NOTICE.txt
cp LICENSE dist/Govi.app/Contents/Resources/Govi/Licenses/Ghostty-LICENSE.txt
ditto "$monaco_dir/vs" dist/Govi.app/Contents/Resources/Govi/editor/vs
cp "$monaco_dir/LICENSE" dist/Govi.app/Contents/Resources/Govi/Licenses/Monaco-LICENSE.txt
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
# The `govi` command. Ghostty puts Contents/MacOS on every shell's PATH, so
# shells and agents inside Govi can run it without installing anything.
# Use Xcode's own toolchain and SDK; the Zig shim above may point at the
# Command Line Tools, whose SDK this compiler can't read.
env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun swiftc -O -o .build/govi-cli govi/cli/main.swift
cp .build/govi-cli dist/Govi.app/Contents/MacOS/govi
# Ad-hoc signatures change with every build, so macOS forgets Keychain
# "Always Allow" grants. Prefer a stable local identity when one exists.
sign_identity=${GOVI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)}
codesign --force --deep --sign "${sign_identity:--}" dist/Govi.app
print "Built $GOVI_ROOT/dist/Govi.app"
