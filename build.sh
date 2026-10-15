#!/bin/sh
# Собирает Peppap.app в ./build напрямую через swiftc (без SwiftPM и Xcode).
#
#   ./build.sh                       — сборка под текущий процессор
#   ARCHS="arm64 x86_64" ./build.sh  — универсальная сборка (так собирает CI)
#
# Версия берётся из файла VERSION, номер сборки — из числа коммитов (или BUILD_NUMBER).
set -eu
cd "$(dirname "$0")"

VERSION=$(tr -d ' \n' < VERSION)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=${ARCHS:-$(uname -m)}
APP=build/Peppap.app

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# Command Line Tools иногда содержат SDK новее компилятора — берём первый совместимый.
pick_sdk() {
  probe=$(mktemp -d)/probe.swift
  echo 'import AppKit' > "$probe"
  for sdk in "$(xcrun --show-sdk-path)" $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -sdk "$sdk" -typecheck "$probe" >/dev/null 2>&1; then echo "$sdk"; return; fi
  done
  echo "Не найден SDK, совместимый с swiftc" >&2; exit 1
}
SDK=${SDK:-$(pick_sdk)}
echo "Peppap $VERSION ($BUILD_NUMBER), архитектуры: $ARCHS"
echo "SDK: $SDK"

BINARIES=""
for arch in $ARCHS; do
  swiftc -O -sdk "$SDK" -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" \
    -o "build/obj/Peppap-$arch" \
    Sources/Peppap/*.swift
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
