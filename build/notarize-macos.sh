#!/usr/bin/env bash
# Submits a signed app bundle (see sign-macos.sh, which must run first)
# to Apple for notarization and staples the resulting ticket onto it.
# A Developer ID signature alone isn't enough for Gatekeeper to trust
# the app on any machine other than the one that built it — macOS
# 10.15+ also requires the app to be notarized (scanned by Apple,
# ticket stapled) or it shows a "can't be opened because Apple cannot
# check it for malicious software" refusal, not just a warning.
#
# Uses an App Store Connect API key (.p8 + Key ID + Issuer ID) rather
# than an Apple ID + app-specific password — the modern, non-interactive
# auth path notarytool supports, and the only one that doesn't risk
# 2FA prompts in CI.
#
# Usage:
#   APPLE_API_KEY_P8_BASE64=... APPLE_API_KEY_ID=... APPLE_API_ISSUER_ID=... \
#     ./build/notarize-macos.sh /path/to/VSCode-darwin-arm64
set -euo pipefail

APP_DIR="${1:?usage: notarize-macos.sh <path to VSCode-darwin-arm64>}"

: "${APPLE_API_KEY_P8_BASE64:?APPLE_API_KEY_P8_BASE64 not set}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID not set}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID not set}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "notarize-macos.sh only runs on macOS (needs xcrun notarytool/stapler)" >&2
  exit 1
fi

APP_BUNDLE="$(find "$APP_DIR" -maxdepth 1 -iname '*.app')"
if [ -z "$APP_BUNDLE" ]; then
  echo "no .app bundle found in $APP_DIR" >&2
  exit 1
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "==> decoding the App Store Connect API key"
KEY_PATH="$SCRATCH/AuthKey_${APPLE_API_KEY_ID}.p8"
# -D (not the GNU-only --decode) is what macOS's own /usr/bin/base64
# documents.
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 -D > "$KEY_PATH"

echo "==> zipping $APP_BUNDLE for submission"
# notarytool only accepts a zip/dmg/pkg for submission, never a raw .app
# directory — ditto (Apple's own recommended tool for this) preserves
# the bundle's resource forks/extended attributes that plain zip drops.
ZIP_PATH="$SCRATCH/submission.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> submitting for notarization (polls Apple; can take several minutes)"
SUBMIT_OUTPUT="$SCRATCH/submit-output.txt"
set +e
xcrun notarytool submit "$ZIP_PATH" \
  --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait | tee "$SUBMIT_OUTPUT"
NOTARIZE_STATUS="${PIPESTATUS[0]}"
set -e

if [ "$NOTARIZE_STATUS" -ne 0 ] || ! grep -q "status: Accepted" "$SUBMIT_OUTPUT"; then
  echo "notarization did not succeed — fetching the detailed log" >&2
  SUBMISSION_ID="$(grep -oE '^[[:space:]]*id: [a-f0-9-]+' "$SUBMIT_OUTPUT" | head -1 | awk '{print $2}')"
  if [ -n "$SUBMISSION_ID" ]; then
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" >&2 || true
  fi
  exit 1
fi

echo "==> stapling the notarization ticket onto $APP_BUNDLE"
xcrun stapler staple "$APP_BUNDLE"

echo "==> verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

echo "Notarized and stapled: $APP_BUNDLE"
