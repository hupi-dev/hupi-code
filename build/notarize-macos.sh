#!/usr/bin/env bash
# Submits a signed app bundle (see sign-macos.sh, which must run first)
# to Apple for notarization, and staples the resulting ticket onto it
# IF Apple responds within a bounded window. A Developer ID signature
# alone isn't enough for Gatekeeper to trust the app on any machine
# other than the one that built it — macOS 10.15+ also requires the app
# to be notarized (scanned by Apple, ticket stapled) or it shows a
# "can't be opened because Apple cannot check it for malicious
# software" refusal, not just a warning.
#
# Deliberately does NOT use `notarytool submit --wait` unbounded: Apple
# doesn't guarantee turnaround time, and first-time submissions on a
# new Developer ID account in particular have been known to take far
# longer than the usual few minutes — occasionally many hours. Blocking
# a CI job on that would either eat a GitHub Actions runner for however
# long Apple takes (billable, and GitHub kills the job outright past its
# own timeout regardless) for no benefit, since nothing else in the
# pipeline depends on notarization finishing synchronously. Instead:
# submit, poll for a bounded window, staple if it finishes in time, and
# otherwise exit successfully having only submitted — see
# staple-macos.sh for finishing the job later once Apple responds.
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
MAX_WAIT_SECS="${NOTARIZE_MAX_WAIT_SECS:-1200}"

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

echo "==> submitting for notarization (not waiting unbounded — see script header)"
SUBMIT_OUTPUT="$SCRATCH/submit-output.txt"
xcrun notarytool submit "$ZIP_PATH" \
  --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  | tee "$SUBMIT_OUTPUT"

SUBMISSION_ID="$(grep -oE '^[[:space:]]*id: [a-f0-9-]+' "$SUBMIT_OUTPUT" | head -1 | awk '{print $2}')"
if [ -z "$SUBMISSION_ID" ]; then
  echo "couldn't parse a submission id out of notarytool's own output" >&2
  exit 1
fi
echo "    submission id: $SUBMISSION_ID"

echo "==> polling for up to ${MAX_WAIT_SECS}s (set NOTARIZE_MAX_WAIT_SECS to change)"
# A manual sleep-and-poll loop, not `timeout` (GNU-only, not on macOS by
# default — the same portability gap smoke-test.sh already documents
# for why it uses this same pattern instead) and not notarytool's own
# --wait (unbounded).
STATUS=""
DEADLINE=$(( $(date +%s) + MAX_WAIT_SECS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  INFO_OUTPUT="$(xcrun notarytool info "$SUBMISSION_ID" \
    --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")"
  STATUS="$(echo "$INFO_OUTPUT" | grep -oE '^[[:space:]]*status: .+' | head -1 | sed -E 's/^[[:space:]]*status: //')"
  echo "    status: $STATUS"
  if [ "$STATUS" != "In Progress" ]; then
    break
  fi
  sleep 30
done

if [ "$STATUS" = "Accepted" ]; then
  echo "==> stapling the notarization ticket onto $APP_BUNDLE"
  xcrun stapler staple "$APP_BUNDLE"
  echo "==> verifying Gatekeeper acceptance"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
  echo "Notarized and stapled: $APP_BUNDLE"
  exit 0
fi

if [ "$STATUS" = "In Progress" ]; then
  echo "notarization still in progress after ${MAX_WAIT_SECS}s — not failing the build over it."
  echo "The app is signed but NOT yet notarized/stapled. Once Apple finishes"
  echo "(check with: xcrun notarytool info $SUBMISSION_ID --key ... --key-id ... --issuer ...),"
  echo "run build/staple-macos.sh $SUBMISSION_ID <path to app dir> to finish."
  exit 0
fi

echo "notarization did not succeed (status: $STATUS) — fetching the detailed log" >&2
xcrun notarytool log "$SUBMISSION_ID" \
  --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" >&2 || true
exit 1
