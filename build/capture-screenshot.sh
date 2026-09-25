#!/usr/bin/env bash
# Launches a built HUPI Code and captures a real screenshot of it
# running — not the marketing site, not a mockup. That distinction is
# exactly what tripped Microsoft Store certification (10.1.1.3,
# "images... don't accurately show what the product does") on the first
# submission: the image submitted there was a hupi.dev website
# screenshot, not this app. This script exists so a real one is always
# available as a CI artifact instead of hand-captured off someone's own
# machine.
#
# Runs on all three platforms build.sh can produce, unlike its first
# version (Linux-only): mss (the Python screenshot library used below)
# is genuinely cross-platform — X11 on Linux, CoreGraphics on macOS,
# GDI on Windows — via ctypes, no native compilation and nothing
# platform-specific to install beyond the pip package itself.
#
# On Linux only, must be invoked already wrapped in xvfb-run (see
# build.yml) rather than calling xvfb-run internally: the app
# (backgrounded below) and the screenshot tool both need to see the
# same virtual DISPLAY, which only happens if both are children of the
# same xvfb-run-launched shell — backgrounding a second, separate
# `xvfb-run ... &` from here would hand each process its own
# independent virtual display. Windows/macOS GitHub-hosted runners
# already have a real desktop session, so no virtual-display wrapper is
# needed (or available) there.
#
# Usage:
#   Linux:          xvfb-run -a ./build/capture-screenshot.sh <path to VSCode-linux-x64> <output png>
#   macOS/Windows:  ./build/capture-screenshot.sh <path to VSCode-<platform>-<arch>> <output png>
set -euo pipefail

APP_DIR="${1:?usage: capture-screenshot.sh <path to VSCode-<platform>-<arch>> <output png path>}"
OUTPUT_PNG="${2:?usage: capture-screenshot.sh <path to VSCode-<platform>-<arch>> <output png path>}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

# Same per-OS binary path smoke-test.sh already resolves — see that
# script's own comment for exactly why each of these three is what it
# is (linuxExecutableName vs. product.nameShort-derived packaging).
case "$(uname -s)" in
  Linux*)   APP_BIN="$APP_DIR/hupi-code" ;;
  Darwin*)  APP_BIN="$APP_DIR/HUPI Code.app/Contents/MacOS/HUPI Code" ;;
  MINGW*|MSYS*|CYGWIN*) APP_BIN="$APP_DIR/HUPI Code.exe" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

# Same python3-or-python fallback build.sh already needed — native
# Windows Python installs typically provide only python.exe, not a
# python3.exe alias, unlike Linux/macOS (see
# docs/UPSTREAM_UPGRADES.md's "python3 hardcoded" note).
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "python3 (or python) not found on PATH — required to capture the screenshot" >&2
  exit 1
fi

"$PYTHON" -m pip install --quiet --user mss

echo "==> launching to render a real screenshot"
"$APP_BIN" --no-sandbox --disable-gpu --disable-workspace-trust \
  --user-data-dir="$WORKDIR/user-data" --new-window \
  > "$WORKDIR/run.log" 2>&1 &
APP_PID=$!

# A fixed wait, not a poll: unlike smoke-test.sh's probe extension
# (which signals the exact moment onStartupFinished fires), there's no
# equivalent signal for "the window has finished painting" — 15s was
# comfortably enough headroom in local testing for the window, sidebar,
# and Getting Started content to fully render.
sleep 15

# Belt-and-suspenders only, Linux-only: patches/0003 already suppresses
# upstream's first-launch onboarding wizard outright (see
# docs/UPSTREAM_UPGRADES.md), so this click now lands on the empty
# editor and does nothing — kept as a no-op safety net in case a future
# upstream version bump reopens the wizard before that patch is
# re-verified against the new tag, rather than silently capturing it
# again unnoticed. Not worth the extra dependency (xdotool has no
# direct macOS/Windows equivalent) to replicate on those two platforms
# for a wizard that's already fully suppressed at the source.
case "$(uname -s)" in
  Linux*)
    xdotool mousemove 1250 245 click 1
    sleep 2
    ;;
esac

"$PYTHON" - "$OUTPUT_PNG" <<'PY'
import sys
from mss import mss
with mss() as sct:
    sct.shot(output=sys.argv[1])
PY

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo "OK: screenshot saved to $OUTPUT_PNG"
