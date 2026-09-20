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
  rm -rf "$SELF_DIR/darwin/node_modules" "$SELF_DIR/darwin/package.json" "$SELF_DIR/darwin/package-lock.json"
}
trap cleanup EXIT

echo "==> decoding the Developer ID Application certificate"
# -D (not the GNU-only --decode) is the flag macOS's own /usr/bin/base64
# actually documents — this script only ever runs on Darwin (guarded
# above), so there's no need to support GNU coreutils' flag spelling too.
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 -D > "$SCRATCH/cert.p12"
echo "    decoded p12 size: $(wc -c < "$SCRATCH/cert.p12" | tr -d ' ') bytes"
echo "    password length: ${#APPLE_CERTIFICATE_PASSWORD} chars"

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

APP_BUNDLE="$(find "$APP_DIR" -maxdepth 1 -iname '*.app')"

echo "==> DEBUG: Electron Framework.framework layout before signing"
# "bundle format is ambiguous (could be app or framework)" on this exact
# framework is a well-documented Electron signing issue, consistently
# traced to the framework's Versions/Current symlink chain having been
# flattened into real file copies somewhere upstream (the framework's
# top-level "Electron Framework" binary and "Resources" are supposed to
# be symlinks into Versions/Current/, not actual files) — checking this
# directly instead of guessing further at which build step did it.
find "$APP_BUNDLE/Contents/Frameworks/Electron Framework.framework" -maxdepth 3 -exec ls -la {} \; || true

echo "==> stripping extended attributes"
# Electron's own signing guide calls this out directly: leftover xattrs
# from however the Electron/VS Code binaries were downloaded and
# extracted (com.apple.provenance, resource forks, etc.) are a known
# cause of codesign misjudging a nested bundle's type — hit here as
# "bundle format is ambiguous (could be app or framework)" on
# Electron Framework.framework's inner binary, the first nested
# framework actually reached during signing.
xattr -cr "$APP_BUNDLE"

echo "==> installing @electron/osx-sign (same major VS Code's own build pins: ^2.0.0)"
# Installed as a sibling of sign.mjs (not into $SCRATCH) on purpose:
# Node's ESM resolver — unlike CommonJS require() — ignores NODE_PATH
# entirely, so `import { sign } from '@electron/osx-sign'` only resolves
# via a real node_modules directory found by walking up from the
# importing file's own location. Removed again in cleanup() above.
npm install --silent --no-save --prefix "$SELF_DIR/darwin" '@electron/osx-sign@^2.0.0'

echo "==> signing $APP_DIR"
node "$SELF_DIR/darwin/sign.mjs" "$APP_DIR" "$IDENTITY" "$KEYCHAIN"

echo "==> verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Signed: $APP_BUNDLE"
echo "(not yet notarized — see notarize-macos.sh)"
