#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/remote-tests
swiftc -module-cache-path .build/remote-tests/modules \
  macos/Sources/Features/Terminal/GoviWorkspaceModels.swift macos/Sources/Features/Terminal/GoviModModels.swift macos/Sources/Features/Terminal/GoviProcess.swift macos/Sources/Features/Terminal/GoviRemoteModels.swift govi/test_remote.swift \
  -o .build/remote-tests/check-remote
.build/remote-tests/check-remote
