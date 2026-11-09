#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/layout-tests
swiftc -module-cache-path .build/layout-tests/modules \
  macos/Sources/Features/Splits/SplitTree.swift govi/test_layout.swift \
  macos/Sources/Helpers/Extensions/Array+Extension.swift \
  -o .build/layout-tests/check-layout
.build/layout-tests/check-layout
