#!/usr/bin/env bash
# Headless smoke test for a build produced by build.sh: confirms the app
# launches without crashing and that the bundled HUPI extension is
# actually loaded — not just present on disk.
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
# Usage: ./build/smoke-test.sh /path/to/VSCode-linux-x64
set -euo pipefail

APP_DIR="${1:?usage: smoke-test.sh <path to VSCode-linux-x64>}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PROBE_DIR="$APP_DIR/resources/app/extensions/zzz-smoke-test-probe"
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

cleanup_probe() { rm -rf "$PROBE_DIR"; }
trap 'cleanup_probe; rm -rf "$WORKDIR"' EXIT

echo "==> launching headlessly (xvfb) to confirm it starts and loads the HUPI extension"
timeout 30 xvfb-run -a "$APP_DIR/hupi-code" \
  --no-sandbox --disable-gpu \
  --user-data-dir="$WORKDIR/user-data" \
  > "$WORKDIR/run.log" 2>&1 || true

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
