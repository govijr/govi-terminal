#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/workflow-tests
swiftc -module-cache-path .build/workflow-tests/modules \
  macos/Sources/Features/Terminal/GoviWorkspaceModels.swift macos/Sources/Features/Terminal/GoviRemoteModels.swift govi/test_workflows.swift \
  -o .build/workflow-tests/check-workflows
.build/workflow-tests/check-workflows
