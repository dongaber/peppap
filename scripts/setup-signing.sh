#!/bin/sh
# Создаёт постоянный самоподписанный сертификат «Peppap Local Signing» в отдельной связке ключей.
# С ним подпись приложения не меняется между сборками, и macOS не спрашивает разрешения заново.
set -eu
KC="$HOME/Library/Keychains/peppap-signing.keychain-db"
KC_PASS="peppap-local"
NAME="Peppap Local Signing"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "Сертификат уже есть: $NAME"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:peppap 2>/dev/null

[ -f "$KC" ] || security create-keychain -p "$KC_PASS" "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"   # не блокировать по таймауту
security import "$TMP/id.p12" -k "$KC" -P peppap -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
# Добавляем связку в список поиска, сохраняя существующие.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Готово: $NAME"
