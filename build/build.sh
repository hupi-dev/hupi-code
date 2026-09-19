#!/usr/bin/env bash
# Builds HUPI Code: shallow-clones microsoft/vscode at UPSTREAM_TAG into a
# scratch dir, applies patches/*.patch (empty for now — see
# docs/UPSTREAM_UPGRADES.md), overlays product-overlay.json onto the
# checkout's own product.json, drops in HUPI's icon and the pre-built
# hupi-native extension as a true built-in (can't be disabled/uninstalled
# from the UI, same folder-under-extensions/ convention every other
# built-in extension — git, npm, typescript-language-features — already
# uses), then runs VS Code's own build for linux-x64.
#
# This is the VSCodium model on purpose: this repo never vendors VS
# Code's own source. Bumping upstream is "edit UPSTREAM_TAG, re-run this
# script, resolve any patch conflicts" — never a multi-hundred-thousand-
# file merge.
#
# Usage:
#   OUT_DIR=/path/to/output ./build/build.sh
#
# Requires (verified live, not just documented): nvm (to install the
# exact Node version the pinned tag's .nvmrc demands — VS Code's own
# preinstall check hard-fails on anything older, even a lower patch
# version of the same major), and Linux build/runtime deps —
# pkg-config libgtk-3-0 libxkbfile-dev libkrb5-dev libgbm1 rpm
# bubblewrap socat libsecret-1-dev libx11-dev libasound2 libnss3
# libatk1.0-0 libatk-bridge2.0-0 libxss1 xvfb (build deps from VS Code's
# own CI, azure-pipelines/linux/*.yml; the last several are Electron's
# own runtime deps for actually launching on a bare Linux box, not
# documented anywhere obvious — found by running the built binary and
# fixing missing-library errors one at a time).
#
# IMPORTANT: this must run from a directory that allows executing
# binaries. Native module postinstall scripts (node-gyp-build and
# friends) fail silently under `npm ci` on a noexec-mounted /tmp with no
# clear top-level error — if OUT_DIR or the scratch clone end up under a
# noexec mount, resolve that before debugging anything else.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_TAG="$(cat "$SELF_DIR/UPSTREAM_TAG")"
HUPI_EXTENSION_DIR="${HUPI_EXTENSION_DIR:-$SELF_DIR/../hupi/vscode-extension}"
WORKROOT="${WORKROOT:-$(mktemp -d)}"

mkdir -p "${OUT_DIR:-./out}"
OUT_DIR="$(cd "${OUT_DIR:-./out}" && pwd)"

WORKDIR="$WORKROOT/vscode"
trap 'rm -rf "$WORKROOT"' EXIT

echo "==> cloning microsoft/vscode @ $UPSTREAM_TAG into $WORKDIR"
git clone --depth 1 --branch "$UPSTREAM_TAG" https://github.com/microsoft/vscode.git "$WORKDIR"

echo "==> installing the exact Node version this tag requires"
if [ -f ~/.nvm/nvm.sh ]; then
  # shellcheck source=/dev/null
  source ~/.nvm/nvm.sh
  NODE_VERSION="$(cat "$WORKDIR/.nvmrc")"
  nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION"
else
  echo "nvm not found — proceeding with whatever 'node' is on PATH; if the" >&2
  echo "preinstall version check fails, install nvm and re-run." >&2
fi

echo "==> applying patches"
shopt -s nullglob
for patch in "$SELF_DIR"/patches/*.patch; do
  echo "    $patch"
  git -C "$WORKDIR" apply "$patch"
done
shopt -u nullglob

echo "==> overlaying product.json"
python3 - "$WORKDIR/product.json" "$SELF_DIR/product-overlay.json" <<'PYEOF'
import json, sys
product_path, overlay_path = sys.argv[1], sys.argv[2]
with open(product_path) as f:
    product = json.load(f)
with open(overlay_path) as f:
    overlay = json.load(f)
product.update(overlay)
with open(product_path, "w") as f:
    json.dump(product, f, indent="\t")
PYEOF

echo "==> installing HUPI branding"
cp "$SELF_DIR/resources/linux/icons/hupi-code-512.png" "$WORKDIR/resources/linux/code.png"

echo "==> building the HUPI extension (source of truth: $HUPI_EXTENSION_DIR)"
( cd "$HUPI_EXTENSION_DIR" && npm ci && npm run build )

echo "==> installing HUPI extension as a built-in"
BUILTIN_DIR="$WORKDIR/extensions/hupi-native"
mkdir -p "$BUILTIN_DIR"
cp -r "$HUPI_EXTENSION_DIR"/dist "$HUPI_EXTENSION_DIR"/package.json \
      "$HUPI_EXTENSION_DIR"/README.md "$HUPI_EXTENSION_DIR"/LICENSE \
      "$HUPI_EXTENSION_DIR"/resources \
      "$BUILTIN_DIR/"
# dist/extension.js is already an esbuild bundle with its dependencies
# (openai, marked) inlined — declaring them in package.json too makes
# the build's own `npm list --production` sanity check (which expects
# every extensions/*/package.json dependency to have a real
# node_modules install *inside that extension's own folder*) fail with
# "missing: marked, openai" even though nothing is actually missing at
# runtime. A pre-bundled built-in extension shouldn't declare
# dependencies its bundle doesn't need installed separately.
python3 - "$BUILTIN_DIR/package.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    pkg = json.load(f)
pkg.pop("dependencies", None)
pkg.pop("devDependencies", None)
with open(path, "w") as f:
    json.dump(pkg, f, indent=2)
PYEOF

echo "==> npm ci (the expensive step — VS Code's own dependency tree)"
( cd "$WORKDIR" && npm ci )

echo "==> building vscode-linux-x64-min"
( cd "$WORKDIR" && NODE_OPTIONS="--max-old-space-size=8192" npm run gulp vscode-linux-x64-min )

echo "==> copying build output to $OUT_DIR"
cp -r "$WORKROOT/VSCode-linux-x64" "$OUT_DIR/"

echo "HUPI Code built: $OUT_DIR/VSCode-linux-x64"
