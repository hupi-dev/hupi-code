#!/usr/bin/env bash
# Wraps an already-built VSCode-win32-x64 folder (from build.sh) into an
# MSIX package for Microsoft Store submission, using the "Desktop Bridge"
# pattern — "HUPI Code.exe" runs unmodified, no UWP rewrite needed.
#
# "HUPI Code" is reserved in Microsoft Partner Center as of 2026-09-19 —
# MSIX_IDENTITY_NAME/MSIX_PUBLISHER below default to the real values from
# that reservation's Identity page (these are public identifiers that
# ship inside the manifest and appear in the Store listing, not secrets).
# Override via env var only if the reservation is ever redone.
#
# The package this produces is still unsigned. For local sideload
# testing you'd need a self-signed test certificate; for the real Store
# listing, Microsoft signs it during certification — you don't need your
# own cert for that path (see docs/MICROSOFT_STORE.md).
#
# Usage (Windows only — makeappx.exe is part of the Windows SDK, already
# on GitHub's windows-latest runners):
#   ./build/package-msix.sh /path/to/VSCode-win32-x64 ./out/hupi-code.msix
set -euo pipefail

APP_DIR="${1:?usage: package-msix.sh <path to VSCode-win32-x64> <output .msix path>}"
OUT_MSIX="${2:?usage: package-msix.sh <path to VSCode-win32-x64> <output .msix path>}"
IDENTITY_NAME="${MSIX_IDENTITY_NAME:-HUPICode.HUPICode}"
PUBLISHER="${MSIX_PUBLISHER:-CN=7A8FE7AC-7EFD-475E-8E35-35E59012B58B}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# MSIX requires a strict four-part Major.Minor.Build.Revision version.
# hupi-code has no release versioning of its own yet, so this reuses
# UPSTREAM_TAG (already X.Y.Z) — override with MSIX_VERSION if that
# stops making sense once this repo has real releases.
MSIX_VERSION="${MSIX_VERSION:-$(cat "$SELF_DIR/UPSTREAM_TAG").0}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> staging package contents in $STAGING"
cp -r "$APP_DIR"/* "$STAGING/"
mkdir -p "$STAGING/Assets"
cp "$SELF_DIR"/resources/store/*.png "$STAGING/Assets/"

sed \
  -e "s/@@IDENTITY_NAME@@/$IDENTITY_NAME/" \
  -e "s/@@PUBLISHER@@/$PUBLISHER/" \
  -e "s/@@VERSION@@/$MSIX_VERSION/" \
  "$SELF_DIR/resources/store/AppxManifest.xml.template" > "$STAGING/AppxManifest.xml"

echo "==> locating makeappx.exe"
# Same class of gap as signtool.exe in build.sh: makeappx.exe ships with
# the Windows SDK, installed alongside Visual Studio on windows-latest,
# but isn't on PATH by default. Searching for it here instead of
# assuming it's already resolvable avoids repeating the exact mistake
# the original signtool.exe invocation made.
MAKEAPPX="$(find '/c/Program Files (x86)/Windows Kits/10/bin' -iname 'makeappx.exe' -path '*x64*' 2>/dev/null | sort -V | tail -1)"
if [ -z "$MAKEAPPX" ]; then
  echo "makeappx.exe not found under Windows Kits — is the Windows SDK installed?" >&2
  exit 1
fi
echo "    found: $MAKEAPPX"

echo "==> packing with makeappx.exe"
mkdir -p "$(dirname "$OUT_MSIX")"
# MSYS_NO_PATHCONV=1: Git Bash auto-converts any argument that looks
# like a POSIX path into a Windows one before exec'ing a native binary —
# a real, well-known gotcha for native Windows CLI tools using /flag
# syntax (not Unix -x/--flag). Without this, Git Bash sees the `/d`
# flag itself, mistakes it for "root of the D: drive", and silently
# rewrites it to `D:/` before makeappx.exe ever sees it — which is
# exactly what happened on a real CI run ("Unknown command line option:
# \"D:/\"", makeappx.exe's own complaint about receiving that instead
# of the flag it expected).
MSYS_NO_PATHCONV=1 "$MAKEAPPX" pack /d "$(cygpath -w "$STAGING" 2>/dev/null || echo "$STAGING")" \
  /p "$(cygpath -w "$OUT_MSIX" 2>/dev/null || echo "$OUT_MSIX")" /o

echo "MSIX package built: $OUT_MSIX"
echo "Unsigned — see docs/MICROSOFT_STORE.md for what happens next."
