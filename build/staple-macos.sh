#!/usr/bin/env bash
# Finishes a notarization that notarize-macos.sh submitted but gave up
# waiting on (still "In Progress" after its own bounded poll window) —
# checks Apple's current verdict for that submission id and, if
# accepted, staples the ticket onto the app bundle. Safe to re-run;
# does nothing destructive if the verdict still isn't in yet.
#
# Usage:
#   APPLE_API_KEY_P8_BASE64=... APPLE_API_KEY_ID=... APPLE_API_ISSUER_ID=... \
#     ./build/staple-macos.sh <submission-id> /path/to/VSCode-darwin-arm64
set -euo pipefail

SUBMISSION_ID="${1:?usage: staple-macos.sh <submission-id> <path to VSCode-darwin-arm64>}"
APP_DIR="${2:?usage: staple-macos.sh <submission-id> <path to VSCode-darwin-arm64>}"

: "${APPLE_API_KEY_P8_BASE64:?APPLE_API_KEY_P8_BASE64 not set}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID not set}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID not set}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "staple-macos.sh only runs on macOS (needs xcrun notarytool/stapler)" >&2
  exit 1
fi

APP_BUNDLE="$(find "$APP_DIR" -maxdepth 1 -iname '*.app')"
if [ -z "$APP_BUNDLE" ]; then
  echo "no .app bundle found in $APP_DIR" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

KEY_PATH="$SCRATCH/AuthKey_${APPLE_API_KEY_ID}.p8"
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 -D > "$KEY_PATH"

echo "==> checking notarization status for submission $SUBMISSION_ID"
INFO_OUTPUT="$(xcrun notarytool info "$SUBMISSION_ID" \
  --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")"
echo "$INFO_OUTPUT"
STATUS="$(echo "$INFO_OUTPUT" | grep -oE '^[[:space:]]*status: .+' | head -1 | sed -E 's/^[[:space:]]*status: //')"

case "$STATUS" in
  Accepted)
    echo "==> stapling the notarization ticket onto $APP_BUNDLE"
    xcrun stapler staple "$APP_BUNDLE"
    echo "==> verifying Gatekeeper acceptance"
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
    echo "Notarized and stapled: $APP_BUNDLE"
    ;;
  "In Progress")
    echo "still in progress — try again later"
    exit 1
    ;;
  *)
    echo "notarization did not succeed (status: $STATUS) — fetching the detailed log" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" >&2 || true
    exit 1
    ;;
esac
