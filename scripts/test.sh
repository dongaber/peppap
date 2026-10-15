#!/bin/sh
# Собирает и запускает тесты (Tests/*.swift) вместе с исходниками приложения, без App.swift.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
SDK=${SDK:-$(pick_sdk)}

mkdir -p build
SOURCES=$(ls Sources/Peppap/*.swift | grep -v '/App.swift$')
# shellcheck disable=SC2086
swiftc -sdk "$SDK" -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -o build/PeppapTests $SOURCES Tests/*.swift
build/PeppapTests
