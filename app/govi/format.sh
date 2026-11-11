#!/bin/zsh
# Formats Govi's Swift sources with swift-format and the repository's
# .swift-format settings. Ghostty's own Swift files are left as they are, so
# upstream changes stay easy to merge.
#
#   ./govi/format.sh          rewrite files in place
#   ./govi/format.sh --check  list files that need formatting and fail (CI)
set -euo pipefail
cd "${0:A:h}/.."

files=(
  macos/Sources/Features/Terminal/Govi*.swift(N)
  macos/Sources/Features/AI/*.swift(N)
  govi/cli/*.swift(N)
  govi/*.swift(N)
)

if [[ ${1:-} == --check ]]; then
  unformatted=()
  for file in $files; do
    xcrun swift-format format --configuration .swift-format "$file" | cmp -s - "$file" || unformatted+=($file)
  done
  if (( ${#unformatted} )); then
    print -u2 "These files need formatting. Run ./govi/format.sh and commit the result:"
    print -u2 -l -- "  "$^unformatted
    exit 1
  fi
  print "All ${#files} Swift files are formatted."
else
  xcrun swift-format format --configuration .swift-format --in-place $files
  print "Formatted ${#files} Swift files."
fi
