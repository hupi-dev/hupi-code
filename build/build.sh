#!/usr/bin/env bash
# Builds HUPI Code: shallow-clones microsoft/vscode at UPSTREAM_TAG into a
# scratch dir, applies patches/*.patch (see docs/UPSTREAM_UPGRADES.md for
# what's there and why), overlays product-overlay.json onto the
# checkout's own product.json, drops in HUPI's icon and the pre-built
# hupi-native extension as a true built-in (can't be disabled/uninstalled
# from the UI, same folder-under-extensions/ convention every other
# built-in extension — git, npm, typescript-language-features — already
# uses), then runs VS Code's own build for the *current* OS/arch (Linux,
# Windows, and macOS all run this same script — see BUILD_TARGETS in
# microsoft/vscode's build/gulpfile.vscode.ts for why cross-compiling to a
# different OS than the one gulp runs on isn't the supported path: the
# generic `vscode`/`vscode-min` gulp tasks are only registered when
# process.platform/arch match the target, so each platform builds on its
# own OS, same as upstream's own CI does with per-OS build agents).
#
# This is the VSCodium model on purpose: this repo never vendors VS
# Code's own source. Bumping upstream is "edit UPSTREAM_TAG, re-run this
# script, resolve any patch conflicts" — never a multi-hundred-thousand-
# file merge.
#
# Usage:
#   OUT_DIR=/path/to/output ./build/build.sh
#
# Requires (verified live, not just documented):
# - Linux: nvm (to install the exact Node version the pinned tag's
#   .nvmrc demands — VS Code's own preinstall check hard-fails on
#   anything older, even a lower patch version of the same major), and
#   these build/runtime deps: pkg-config libgtk-3-0 libxkbfile-dev
#   libkrb5-dev libgbm1 rpm bubblewrap socat libsecret-1-dev libx11-dev
#   libasound2 libnss3 libatk1.0-0 libatk-bridge2.0-0 libxss1 xvfb
#   (build deps from VS Code's own CI, azure-pipelines/linux/*.yml; the
#   last several are Electron's own runtime deps for actually launching
#   on a bare Linux box, not documented anywhere obvious — found by
#   running the built binary and fixing missing-library errors one at a
#   time).
# - Windows/macOS: the right Node version already on PATH (nvm-the-
#   Unix-tool doesn't run on native Windows; GitHub's windows-latest/
#   macos-latest runners plus an explicit actions/setup-node step cover
#   this — see .github/workflows/build.yml) and each OS's own native
#   toolchain for node-gyp (Visual Studio Build Tools + Python on
#   Windows, Xcode Command Line Tools on macOS) — both already present
#   on GitHub-hosted runners, nothing extra to install there.
# - Not yet exercised outside CI's own hosted runners: this script's
#   Windows/macOS path is new and, unlike the Linux path (hardened
#   through several real build failures caught by actually running it
#   locally), has only been reasoned through against microsoft/vscode's
#   build source, not run end-to-end on those OSes yet — expect the
#   first real CI runs there to surface something.
#
# IMPORTANT: this must run from a directory that allows executing
# binaries. Native module postinstall scripts (node-gyp-build and
# friends) fail silently under `npm ci` on a noexec-mounted /tmp with no
# clear top-level error — if OUT_DIR or the scratch clone end up under a
# noexec mount, resolve that before debugging anything else.
set -euo pipefail

case "$(uname -s)" in
  Linux*) PLATFORM=linux ;;
  Darwin*) PLATFORM=darwin ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=win32 ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
# Matches microsoft/vscode's own BUILD_TARGETS naming exactly
# (build/gulpfile.vscode.ts) — the gulp task name and the output folder
# name it produces both follow this same `<platform>-<arch>` pattern.
GULP_TASK="vscode-${PLATFORM}-${ARCH}-min"
DEST_FOLDER="VSCode-${PLATFORM}-${ARCH}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_TAG="$(cat "$SELF_DIR/UPSTREAM_TAG")"
HUPI_EXTENSION_DIR="${HUPI_EXTENSION_DIR:-$SELF_DIR/../hupi/vscode-extension}"
WORKROOT="${WORKROOT:-$(mktemp -d)}"

mkdir -p "${OUT_DIR:-./out}"
OUT_DIR="$(cd "${OUT_DIR:-./out}" && pwd)"

WORKDIR="$WORKROOT/vscode"
trap 'rm -rf "$WORKROOT"' EXIT

echo "==> cloning microsoft/vscode @ $UPSTREAM_TAG into $WORKDIR"
# core.autocrlf=false, scoped to just this clone: on Windows, Git for
# Windows' own default (core.autocrlf=true) checks files out with CRLF
# line endings, but patches/*.patch were authored with LF-only content —
# git apply's context matching fails on the mismatch ("patch does not
# apply") even though the actual diff content is correct. Forcing LF
# here keeps behavior identical across all three OSes instead of trying
# to make every patch CRLF-tolerant.
git -c core.autocrlf=false clone --depth 1 --branch "$UPSTREAM_TAG" https://github.com/microsoft/vscode.git "$WORKDIR"

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
case "$PLATFORM" in
  linux)  cp "$SELF_DIR/resources/linux/icons/hupi-code-512.png" "$WORKDIR/resources/linux/code.png" ;;
  win32)  cp "$SELF_DIR/resources/win32/code.ico" "$WORKDIR/resources/win32/code.ico" ;;
  darwin) cp "$SELF_DIR/resources/darwin/code.icns" "$WORKDIR/resources/darwin/code.icns" ;;
esac

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
# Retried on purpose: VS Code's own postinstall (build/npm/postinstall.ts)
# fans out into dozens of concurrent child npm installs across
# extensions/*, and under real resource contention one of those child
# processes can transiently fail to spawn its own shell ("spawn /bin/sh
# ENOENT") — reproduced identically on two independent machines (this
# sandbox and a GitHub Actions runner) at the exact same step, both
# resource-constrained, neither a deterministic logic bug. npm ci is
# always safe to retry — it reconciles against package-lock.json from
# scratch every time.
NPM_CI_ATTEMPTS=3
for attempt in $(seq 1 "$NPM_CI_ATTEMPTS"); do
  if ( cd "$WORKDIR" && npm ci ); then
    break
  fi
  if [ "$attempt" -eq "$NPM_CI_ATTEMPTS" ]; then
    echo "npm ci failed after $NPM_CI_ATTEMPTS attempts" >&2
    exit 1
  fi
  echo "npm ci failed (attempt $attempt/$NPM_CI_ATTEMPTS) — retrying" >&2
  sleep 5
done

echo "==> removing Microsoft's bundled Copilot extension"
# A HUPI-native IDE shouldn't ship a competing chat extension alongside
# HUPI's own. This must happen AFTER npm ci, not before: npm ci's own
# postinstall (build/npm/postinstall.ts) enumerates and installs every
# extensions/* subdirectory itself, copilot included — deleting it
# first leaves a dangling reference that fails with a confusingly
# unrelated "spawn /bin/sh ENOENT" (a real, reproduced-twice Node
# quirk: a spawn whose cwd doesn't exist reports this exact misleading
# error under `shell: true`, not a clearer "directory not found").
# Removing it here, after npm ci has already processed it, is safe —
# the packaging pipeline's own prepareBuiltInCopilotRipgrepShim step
# (build/lib/copilot.ts) still runs unconditionally regardless of
# copilot's presence and hard-fails if its SDK isn't there;
# patches/0001-*.patch (applied above) is what makes that a no-op
# instead when copilot is genuinely absent.
rm -rf "$WORKDIR/extensions/copilot"

if [ "$PLATFORM" = win32 ]; then
  echo "==> locating signtool.exe"
  # patchWin32DependenciesTask (build/gulpfile.vscode.ts) runs
  # unconditionally for every win32 build — for every bundled .node/
  # rg.exe/tgrep.exe/etc. it spawns `signtool.exe verify` to check for an
  # existing Authenticode signature to strip before rcedit patches the
  # file's version info (rcedit invalidates signatures, so any pre-
  # existing one needs stripping first). None of that needs an actual
  # cert of ours — it's just detecting/removing *other* signatures — but
  # the tool itself still needs to exist on PATH, and it isn't by
  # default even though the Windows SDK it ships in is installed
  # alongside VS on GitHub's windows-latest image. A real failure
  # ("spawn signtool.exe ENOENT"), not hypothetical — searching for it
  # here instead of hardcoding an SDK version number avoids repeating
  # the exact mistake the vs2022_install override made (guessing a
  # version-specific path that turned out not to exist on this image).
  SIGNTOOL="$(find '/c/Program Files (x86)/Windows Kits/10/bin' -iname 'signtool.exe' -path '*x64*' 2>/dev/null | sort -V | tail -1)"
  if [ -n "$SIGNTOOL" ]; then
    echo "    found: $SIGNTOOL"
    export PATH="$PATH:$(dirname "$SIGNTOOL")"
  else
    echo "    WARNING: signtool.exe not found under Windows Kits — the win32 packaging task will likely fail" >&2
  fi
fi

echo "==> building $GULP_TASK"
( cd "$WORKDIR" && NODE_OPTIONS="--max-old-space-size=8192" npm run gulp "$GULP_TASK" )

echo "==> copying build output to $OUT_DIR"
cp -r "$WORKROOT/$DEST_FOLDER" "$OUT_DIR/"

echo "HUPI Code built: $OUT_DIR/$DEST_FOLDER"
