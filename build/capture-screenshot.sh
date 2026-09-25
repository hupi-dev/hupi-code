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
# Must be invoked already wrapped in xvfb-run (see build.yml) rather
# than calling xvfb-run internally: the app (backgrounded below) and the
# screenshot tool both need to see the same virtual DISPLAY, which only
# happens if both are children of the same xvfb-run-launched shell —
# backgrounding a second, separate `xvfb-run ... &` from here would hand
# each process its own independent virtual display.
#
# Linux-only: smoke-test.sh already runs on all three platforms because
# xvfb (Linux's virtual-display tool) is what makes a headless CI
# runner's total absence of a display survivable; Windows/macOS
# GitHub-hosted runners already have a real desktop session. VS Code
# draws its own title bar and UI rather than using native OS chrome, so
# it looks the same across platforms — one platform's screenshot is
# sufficient evidence of what the app actually looks like.
#
# Requires xdotool (installed alongside xvfb in build.yml) to dismiss
# the first-launch onboarding wizard before capturing — see below.
#
# Usage: xvfb-run -a ./build/capture-screenshot.sh /path/to/VSCode-linux-x64 /path/to/output.png
set -euo pipefail

APP_DIR="${1:?usage: capture-screenshot.sh <path to VSCode-linux-x64> <output png path>}"
OUTPUT_PNG="${2:?usage: capture-screenshot.sh <path to VSCode-linux-x64> <output png path>}"
APP_BIN="$APP_DIR/hupi-code"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

python3 -m pip install --quiet --user mss

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

# Upstream's first-launch onboarding wizard (a whole multi-step modal —
# theme picker, "Get started" — driven by product.json's
# defaultChatAgent block, which still points at GitHub Copilot; see
# docs/UPSTREAM_UPGRADES.md) covers the real window on first launch.
# It's a known, tracked issue (still Copilot-branded throughout, not yet
# patched — a bigger job than this script), but it also means a
# screenshot taken right after launch shows that wizard, not HUPI Code
# itself, which defeats the actual point of this script. Every step of
# that wizard shares the same close ("X") button position, so
# dismissing it this way is robust regardless of which step first
# render happens to land on.
xdotool mousemove 1250 245 click 1
sleep 2

python3 - "$OUTPUT_PNG" <<'PY'
import sys
from mss import mss
with mss() as sct:
    sct.shot(output=sys.argv[1])
PY

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo "OK: screenshot saved to $OUTPUT_PNG"
