#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ ! -d dist/Govi.app ]]; then
  ./govi/build.sh
fi
open dist/Govi.app
