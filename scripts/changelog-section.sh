#!/bin/sh
# Печатает раздел CHANGELOG.md для версии (заметки к GitHub Release).
#   scripts/changelog-section.sh 0.3.0
set -eu
cd "$(dirname "$0")/.."
awk -v ver="$1" '
  $0 ~ "^## \\[" ver "\\]" { f=1; next }
  /^## \[/ { if (f) exit }
  f
' CHANGELOG.md
