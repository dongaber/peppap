#!/bin/sh
# Собирает Peppap.app в ./build напрямую через swiftc (без SwiftPM и Xcode).
#
#   ./build.sh                       — сборка под текущий процессор
#   ARCHS="arm64 x86_64" ./build.sh  — универсальная сборка (так собирает CI)
#
# Версия берётся из package.json, номер сборки — из числа коммитов (или BUILD_NUMBER).
set -eu
cd "$(dirname "$0")"

. scripts/lib.sh
VERSION=$(app_version)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=${ARCHS:-$(uname -m)}
APP=build/Peppap.app

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SDK=${SDK:-$(pick_sdk)}
echo "Peppap $VERSION ($BUILD_NUMBER), архитектуры: $ARCHS"
echo "SDK: $SDK"

SOURCES=$(find Sources/Peppap -name '*.swift' | sort)
BINARIES=""
for arch in $ARCHS; do
  # shellcheck disable=SC2086
  swiftc -O -sdk "$SDK" -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" \
    -o "build/obj/Peppap-$arch" \
    $SOURCES
  BINARIES="$BINARIES build/obj/Peppap-$arch"
done
# shellcheck disable=SC2086
lipo -create $BINARIES -output "$APP/Contents/MacOS/Peppap"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Постоянная подпись (scripts/setup-signing.sh): разрешения macOS сохраняются между сборками.
# Без сертификата (например, в CI) — временная подпись.
KC="$HOME/Library/Keychains/peppap-signing.keychain-db"
if [ -f "$KC" ] && security unlock-keychain -p peppap-local "$KC" 2>/dev/null \
   && security find-identity -p codesigning "$KC" | grep -q "Peppap Local Signing"; then
  codesign --force --keychain "$KC" --sign "Peppap Local Signing" "$APP"
  echo "Подпись: Peppap Local Signing"
else
  codesign --force --sign - "$APP"
  echo "Подпись: временная (для постоянной запустите scripts/setup-signing.sh)"
fi

echo "Готово: $APP"
echo "Запуск: open $APP"
