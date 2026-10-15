#!/bin/sh
# Упаковывает build/Peppap.app в dist/: Peppap-<версия>.zip и Peppap-<версия>.dmg.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(tr -d ' \n' < VERSION)
APP=build/Peppap.app
[ -d "$APP" ] || { echo "Сначала соберите приложение: ./build.sh" >&2; exit 1; }

rm -rf dist
mkdir -p dist

# ZIP: ditto сохраняет подпись и атрибуты бандла.
ditto -c -k --keepParent "$APP" "dist/Peppap-$VERSION.zip"

# DMG с ярлыком на «Программы» — перетащить и готово.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Peppap $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Peppap-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

(cd dist && shasum -a 256 Peppap-* > SHA256SUMS.txt)
ls -lh dist
