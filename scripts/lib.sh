# Общие функции для build.sh и scripts/test.sh (подключается через «.»).

# Command Line Tools иногда содержат SDK новее компилятора — берём первый совместимый.
pick_sdk() {
  probe=$(mktemp -d)/probe.swift
  echo 'import AppKit' > "$probe"
  for sdk in "$(xcrun --show-sdk-path)" $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -sdk "$sdk" -typecheck "$probe" >/dev/null 2>&1; then echo "$sdk"; return; fi
  done
  echo "Не найден SDK, совместимый с swiftc" >&2; exit 1
}
