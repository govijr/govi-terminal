#!/bin/zsh
# Print a Zig 0.14.1 compiler path, downloading the official toolchain if needed.
set -euo pipefail
cd "${0:A:h}/.."
if [[ -n "${GOVI_ZIG:-}" ]]; then
  if [[ ! -x "$GOVI_ZIG" || "$("$GOVI_ZIG" version)" != 0.14.1 ]]; then
    print -u2 "GOVI_ZIG must point to a Zig 0.14.1 compiler."
    exit 1
  fi
  print -r -- "$GOVI_ZIG"
  exit 0
fi
if (( $+commands[zig] )) && [[ "$(zig version)" == 0.14.1 ]]; then
  print -r -- "$commands[zig]"
  exit 0
fi
case "$(uname -m)" in
  arm64)
    GOVI_ARCH=aarch64
    GOVI_CHECKSUM=39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa
    ;;
  x86_64)
    GOVI_ARCH=x86_64
    GOVI_CHECKSUM=b0f8bdfb9035783db58dd6c19d7dea89892acc3814421853e5752fe4573e5f43
    ;;
  *) print -u2 "Govi requires an Intel or Apple Silicon Mac."; exit 1 ;;
esac
GOVI_TOOLCHAIN="$PWD/.tools/zig-$GOVI_ARCH-macos-0.14.1"
if [[ ! -x "$GOVI_TOOLCHAIN/zig" ]]; then
  mkdir -p .tools
  GOVI_ARCHIVE="$PWD/.tools/zig-download.tar.xz"
  trap 'rm -f "$GOVI_ARCHIVE"' EXIT
  print -u2 "Downloading Zig 0.14.1 from ziglang.org…"
  curl --fail --location --silent --show-error \
    "https://ziglang.org/download/0.14.1/zig-$GOVI_ARCH-macos-0.14.1.tar.xz" -o "$GOVI_ARCHIVE"
  GOVI_ACTUAL="$(shasum -a 256 "$GOVI_ARCHIVE" | cut -d ' ' -f 1)"
  if [[ "$GOVI_ACTUAL" != "$GOVI_CHECKSUM" ]]; then
    print -u2 "The compiler download did not match its official checksum."
    exit 1
  fi
  tar -xJf "$GOVI_ARCHIVE" -C .tools
fi
print -r -- "$GOVI_TOOLCHAIN/zig"
