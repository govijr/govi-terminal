#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/wordmark-tests
swiftc -module-cache-path .build/wordmark-tests/modules \
  macos/Sources/Features/Terminal/GoviLaunchWordmark.swift govi/test_wordmark.swift \
  -o .build/wordmark-tests/check-wordmark
.build/wordmark-tests/check-wordmark
