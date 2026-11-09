#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/integration-tests
swiftc -module-cache-path .build/integration-tests/modules \
  macos/Sources/Features/Terminal/GoviWorkspaceModels.swift macos/Sources/Features/Terminal/GoviProcess.swift \
  macos/Sources/Features/Terminal/GoviRemoteModels.swift \
  macos/Sources/Features/Terminal/GoviIntegrationModels.swift \
  macos/Sources/Features/Terminal/GoviIntegrationServices.swift \
  govi/test_integrations.swift -o .build/integration-tests/check-integrations
.build/integration-tests/check-integrations
