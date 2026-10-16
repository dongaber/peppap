#!/bin/sh
# Печатает раздел CHANGELOG.md для версии (заметки к GitHub Release).
#   scripts/changelog-section.sh 0.6.0
# Заголовки версий: «## [0.6.0](ссылка) (дата)» от release-it и «## [0.5.0] — дата» в старых записях.
set -eu
cd "$(dirname "$0")/.."
awk -v ver="$1" '
  index($0, "## [" ver "]") == 1 || index($0, "### [" ver "]") == 1 { f=1; next }
  /^###? \[[0-9]/ { if (f) exit }
  f
' CHANGELOG.md
