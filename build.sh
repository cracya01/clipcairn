#!/bin/bash
# Build Clipcairn.app in a system temp dir, install it to /Applications, relaunch.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d -t clipcairn-build)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Clipcairn.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SQLCipher (vendored amalgamation) with Apple's CommonCrypto as the crypto provider.
clang -O2 -w -c Vendor/sqlcipher/sqlite3.c -o "$WORK/sqlcipher.o" \
  -target arm64-apple-macos26.0 \
  -DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_TEMP_STORE=2 -DSQLITE_THREADSAFE=1 \
  -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridging.h \
  Sources/*.swift "$WORK/sqlcipher.o" \
  -framework Security -framework Carbon \
  -o "$APP/Contents/MacOS/Clipcairn"

cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Prefer a stable self-signed identity, so macOS permissions and keychain access survive rebuilds.
IDENTITY="Local Self-Signed Code Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Signing identity \"$IDENTITY\" not found, using ad-hoc signing."
  codesign --force --sign - "$APP"
fi

pkill -x Clipcairn || true
sleep 1
rm -rf /Applications/Clipcairn.app
ditto "$APP" /Applications/Clipcairn.app
open /Applications/Clipcairn.app
echo "Installed /Applications/Clipcairn.app"
