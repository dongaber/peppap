# Общие функции для build.sh и scripts/*.sh (подключается через «.»).

# Версия приложения — поле version в package.json (его поднимает `bun run release`).
app_version() {
  plutil -extract version raw -o - package.json
}

# Command Line Tools иногда содержат SDK новее компилятора — берём первый совместимый.
pick_sdk() {
  probe=$(mktemp -d)/probe.swift
  echo 'import AppKit' > "$probe"
  for sdk in "$(xcrun --show-sdk-path)" $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -sdk "$sdk" -typecheck "$probe" >/dev/null 2>&1; then echo "$sdk"; return; fi
  done
  echo "Не найден SDK, совместимый с swiftc" >&2; exit 1
}
