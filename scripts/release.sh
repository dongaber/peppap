#!/bin/sh
# Готовит релиз: обновляет VERSION и CHANGELOG, делает коммит и тег vX.Y.Z.
#
#   scripts/release.sh 0.4.0
#   git push origin main --follow-tags   # запустит сборку релиза в GitHub Actions
set -eu
cd "$(dirname "$0")/.."

NEW=${1:-}
echo "$NEW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Использование: scripts/release.sh X.Y.Z" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Есть незакоммиченные изменения — сначала закоммитьте их." >&2; exit 1; }
git rev-parse "v$NEW" >/dev/null 2>&1 && { echo "Тег v$NEW уже существует." >&2; exit 1; }
grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "В CHANGELOG.md нет раздела ## [Unreleased]." >&2; exit 1; }

# Содержимое Unreleased становится разделом новой версии; над ним — пустой Unreleased.
NOTES=$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')
[ -n "$NOTES" ] || { echo "Раздел Unreleased пуст — опишите изменения в CHANGELOG.md." >&2; exit 1; }

DATE=$(date +%Y-%m-%d)
awk -v ver="$NEW" -v date="$DATE" '
  /^## \[Unreleased\]/ { print; print ""; print "## [" ver "] — " date; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
echo "$NEW" > VERSION

git add VERSION CHANGELOG.md
git commit -m "Release v$NEW"
git tag -a "v$NEW" -m "Peppap $NEW"
echo "Готово. Опубликуйте: git push origin main --follow-tags"
