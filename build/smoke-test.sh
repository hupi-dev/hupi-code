#!/usr/bin/env bash
# Headless smoke test for a build produced by build.sh: confirms the app
# launches without crashing and that the bundled HUPI extension is
# actually loaded — not just present on disk. Works against a build for
# any of the three platforms build.sh can produce.
#
# Verifying "is the extension loaded" turned out to need more than
# grepping startup logs: hupi-vscode's activationEvents is deliberately
# empty (it activates on a real UI interaction — opening its sidebar —
# not eagerly), so it produces zero log lines in a headless run that
# never opens a workspace or clicks anything. `--list-extensions` also
# doesn't help — it only ever reports user-installed extensions
# (ExtensionType.User), never built-ins (ExtensionType.System), by
# design (see extensionManagementCLI.ts's own listExtensions()).
#
# The only way that actually answers the question: a tiny probe
# extension, planted alongside the real one, that activates on
# `onStartupFinished` and writes `vscode.extensions.all`'s ids to a file.
# That's exactly what this script does, then asserts hupi.hupi-vscode is
# in the result.
#
# Usage: ./build/smoke-test.sh /path/to/VSCode-<platform>-<arch>
set -euo pipefail

APP_DIR="${1:?usage: smoke-test.sh <path to VSCode-<platform>-<arch>>}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

# The packaged binary's location/name differs per OS. Linux uses
# electron.ts's explicit linuxExecutableName: product.applicationName
# ("hupi-code"). Darwin and win32 both instead go through
# @vscode/gulp-electron's own packaging (build/gulpfile.vscode.ts sets
# packageJsonUpdates.name = product.nameShort, "HUPI Code" (with a
# space); that flows into the packaged app's package.json, which
# @vscode/gulp-electron's index.js reads as opts.productName, and
# win32.js's renameApp() renames the root .exe to `${productName}.exe`
# — confirmed by inspecting that package's actual source, not guessed,
# after a first win32 smoke-test attempt failed looking for
# "hupi-code.exe" instead of the real "HUPI Code.exe").
case "$(uname -s)" in
  Linux*)
    APP_BIN="$APP_DIR/hupi-code"
    RESOURCES_DIR="$APP_DIR/resources/app"
    ;;
  Darwin*)
    APP_BIN="$APP_DIR/HUPI Code.app/Contents/MacOS/HUPI Code"
    RESOURCES_DIR="$APP_DIR/HUPI Code.app/Contents/Resources/app"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    APP_BIN="$APP_DIR/HUPI Code.exe"
    RESOURCES_DIR="$APP_DIR/resources/app"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

PROBE_DIR="$RESOURCES_DIR/extensions/zzz-smoke-test-probe"
RESULT_FILE="$WORKDIR/probe-result.txt"

mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/package.json" <<EOF
{
  "name": "zzz-smoke-test-probe",
  "publisher": "hupi-code-ci",
  "version": "0.0.1",
  "engines": { "vscode": "^1.90.0" },
  "main": "./extension.js",
  "activationEvents": ["onStartupFinished"]
}
EOF
cat > "$PROBE_DIR/extension.js" <<EOF
const vscode = require('vscode');
const fs = require('fs');
function activate() {
  const ids = vscode.extensions.all.map(e => e.id).sort();
  fs.writeFileSync('$RESULT_FILE', ids.join('\n'));
}
module.exports = { activate };
EOF

cleanup_probe() { rm -rf "$PROBE_DIR" 2>/dev/null || true; }
# Best-effort cleanup, not a correctness check — `kill "$APP_PID"` below
# only signals the top-level Electron process, not its whole subprocess
# tree (renderer/GPU/extension host), so a file under $WORKDIR/user-data
# can still be open for a moment after. A real run hit exactly this:
# the actual verification passed, but `rm -rf` on a not-yet-released
# file made the *cleanup* fail, which — combined with `set -e` — turned
# a passing smoke test into a false failure. `|| true` here ensures only
# the actual pass/fail checks below ever set the script's exit code.
trap 'cleanup_probe; rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

echo "==> launching to confirm it starts and loads the HUPI extension"
# Linux CI runners have no display at all, hence xvfb; Windows/macOS
# GitHub-hosted runners run as a real logged-in desktop session already,
# so no virtual-display wrapper is needed (or available — xvfb-run/
# `timeout` are both Linux/GNU-specific) on those two. The launch just
# runs the whole app and waits for onStartupFinished, so something has to
# kill it afterward regardless of OS — a portable background+sleep+kill
# replaces `timeout` for that.
LAUNCH=("$APP_BIN" --no-sandbox --disable-gpu --user-data-dir="$WORKDIR/user-data")
case "$(uname -s)" in
  Linux*) LAUNCH=(xvfb-run -a "${LAUNCH[@]}") ;;
esac

"${LAUNCH[@]}" > "$WORKDIR/run.log" 2>&1 &
APP_PID=$!

# Poll for the probe's result file instead of a fixed sleep — a real
# CI run showed Windows cold-starting noticeably slower than Linux/
# macOS: a flat 30s sleep killed the extension host (SIGTERM, exit 143)
# before it ever reached onStartupFinished, even though the app itself
# had launched fine. Polling exits as soon as the probe fires (fast on
# Linux/macOS, which have consistently finished well under 30s) while
# still giving a slower cold start up to MAX_WAIT_SECS before giving up.
MAX_WAIT_SECS=90
for _ in $(seq 1 "$MAX_WAIT_SECS"); do
  if [[ -f "$RESULT_FILE" ]]; then
    break
  fi
  sleep 1
done
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

if [[ ! -f "$RESULT_FILE" ]]; then
  echo "FAIL: probe never activated — app likely failed to start. Log:"
  cat "$WORKDIR/run.log"
  exit 1
fi

if ! grep -qx "hupi.hupi-vscode" "$RESULT_FILE"; then
  echo "FAIL: hupi.hupi-vscode not found among loaded extensions:"
  cat "$RESULT_FILE"
  exit 1
fi

echo "OK: HUPI Code started and hupi.hupi-vscode is loaded as a built-in extension."
