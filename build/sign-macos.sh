#!/usr/bin/env bash
# Code-signs a built VSCode-darwin-* app bundle with a real Apple
# Developer ID Application certificate under hardened runtime, using
# microsoft/vscode's own entitlements-per-process pattern (see
# build/darwin/entitlements/ and build/darwin/sign.mjs) via
# @electron/osx-sign — the same library and API VS Code's own
# build/darwin/sign.ts uses, pinned to the same ^2.0.0 major.
#
# A signed app is still not enough for Gatekeeper to trust it on a
# machine other than the one that built it — see notarize-macos.sh,
# which must run after this script.
#
# Usage:
#   APPLE_CERTIFICATE_P12_BASE64=... APPLE_CERTIFICATE_PASSWORD=... \
#     ./build/sign-macos.sh /path/to/VSCode-darwin-arm64
set -euo pipefail

APP_DIR="${1:?usage: sign-macos.sh <path to VSCode-darwin-arm64>}"

: "${APPLE_CERTIFICATE_P12_BASE64:?APPLE_CERTIFICATE_P12_BASE64 not set}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD not set}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "sign-macos.sh only runs on macOS (needs security/codesign)" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$(mktemp -d)"
KEYCHAIN="$SCRATCH/hupi-code-build.keychain"

cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "==> decoding the Developer ID Application certificate"
echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$SCRATCH/cert.p12"

echo "==> creating a temporary keychain for CI signing"
# A dedicated, throwaway keychain (rather than importing into the
# runner's default login keychain) avoids polluting a shared runner and
# is deleted unconditionally on exit above.
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "==> importing the certificate"
security import "$SCRATCH/cert.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

# Without this, codesign hangs waiting for a keychain-access UI prompt
# that never appears headlessly on a CI runner — a well-known macOS
# Sierra+ requirement for any non-interactively-imported identity.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# A keychain only found via -k on import isn't automatically searched by
# codesign — it has to be added to the user's keychain search list too.
EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $EXISTING_KEYCHAINS

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | grep 'Developer ID Application' | head -1 \
  | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')"
if [ -z "$IDENTITY" ]; then
  echo "no 'Developer ID Application' identity found in the imported certificate" >&2
  security find-identity -v -p codesigning "$KEYCHAIN" >&2
  exit 1
fi
echo "    identity: $IDENTITY"

echo "==> installing @electron/osx-sign (same major VS Code's own build pins: ^2.0.0)"
npm install --silent --no-save --prefix "$SCRATCH" '@electron/osx-sign@^2.0.0'

echo "==> signing $APP_DIR"
NODE_PATH="$SCRATCH/node_modules" node "$SELF_DIR/darwin/sign.mjs" "$APP_DIR" "$IDENTITY" "$KEYCHAIN"

APP_BUNDLE="$(find "$APP_DIR" -maxdepth 1 -iname '*.app')"
echo "==> verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Signed: $APP_BUNDLE"
echo "(not yet notarized — see notarize-macos.sh)"
