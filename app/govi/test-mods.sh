#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/mod-tests
swiftc -module-cache-path .build/mod-tests/modules \
  macos/Sources/Features/Terminal/GoviWorkspaceModels.swift macos/Sources/Features/Terminal/GoviModModels.swift macos/Sources/Features/Terminal/GoviRemoteModels.swift govi/test_mods.swift \
  -o .build/mod-tests/check-mods
.build/mod-tests/check-mods
