#!/bin/sh
# Собирает и запускает тесты (Tests/*.swift) вместе с исходниками приложения, без App.swift.
# С флагом DEV, чтобы инструменты разработки тоже компилировались и проверялись.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
SDK=${SDK:-$(pick_sdk)}

mkdir -p build
SOURCES=$(find Sources/Peppap -name '*.swift' ! -path '*/App/App.swift' | sort)
# shellcheck disable=SC2086
swiftc -sdk "$SDK" -swift-version 5 -parse-as-library -D DEV \
  -target "$(uname -m)-apple-macos14.0" \
  -o build/PeppapTests $SOURCES Tests/*.swift
build/PeppapTests
