# HUPI Code

A HUPI-native fork of VS Code — the chat/inline-edit experience that's
normally an extension you install (`hupi-vscode`, in the
[`hupi`](https://github.com/hupi-dev/hupi) repo) is here a permanent,
built-in part of the editor itself, on first launch, no install step.

## What this actually is right now

Phase 1: a rebranded VS Code — different name, icon, and identity
strings, the HUPI extension bundled in as a true built-in (can't be
disabled or uninstalled from the UI), Microsoft's own bundled Copilot
extension removed (a HUPI-native IDE shouldn't ship a competing chat
extension alongside HUPI's own), and an [open-vsx.org](https://open-vsx.org)
extension gallery instead of Microsoft's (whose terms of service forbid
non-Microsoft products from using it — every serious VS Code fork,
VSCodium included, points here instead).

Two core patches so far. `patches/0001-*.patch` is mechanical, not
UX — it stops VS Code's own packaging pipeline from hard-failing over
Copilot's absence (it unconditionally prepares Copilot's ripgrep shim
regardless of whether the extension exists at all). `patches/0002-*.patch`
is the first real Phase 3 UX-level patch: it removes the four
"Use AI features with Copilot for free" steps upstream leads its
first-launch Getting Started walkthrough with — core workbench content,
not reachable via `product-overlay.json` or by just removing the
Copilot extension, and not something a HUPI-native IDE (which already
bundles its own chat) should be steering new users toward. Everything
else so far is still extension-API-only — a lot of what "feels like
Cursor" (native chat UI, inline ghost-text completions, custom diff
panels) is reachable that way, without touching upstream source, and
that's still the preferred direction before reaching for another core
patch.

Linux, Windows, and macOS (arm64) all build in CI now — see
[docs/BUILD.md](docs/BUILD.md). Windows/macOS builds are **unsigned**:
real code signing needs credentials this repo doesn't have wired in yet
(a Windows certificate via Azure Trusted Signing, an Apple Developer ID +
notarization) — see the Phase 4 note below. An unsigned build still runs
fine; the OS just shows an "unknown publisher"-style warning on first
launch until signing is set up.

## Distribution status (Phase 4)

Every push builds and smoke-tests all three platforms in CI, uploaded as
build artifacts — there's no download page or release process yet, and
Windows/macOS builds are unsigned (see above). Real signing is blocked
on external credentials only a human can obtain: a Windows code-signing
certificate (in progress via Azure Trusted Signing — needs a validated
Trusted Signing Account, a Public Trust certificate profile, and an
Azure AD app registration granted the *Trusted Signing Certificate
Profile Signer* role, wired into CI via Microsoft's
[`trusted-signing-action`](https://github.com/Azure/trusted-signing-action))
and an Apple Developer ID + notarization credentials for macOS. Auto-
update and an installer (Inno Setup on Windows, a signed DMG on macOS)
are also still open — `product-overlay.json`'s `win32AppId`/
`win32x64AppId`/etc. are real, valid GUIDs now (fixed from Phase 1's
placeholders) so that work isn't blocked when it starts, but nothing
uses them yet since only the raw unsigned binary folder is produced today.

## Why this repo is small

VS Code's own source (~19k files) is never vendored here. This repo
holds a pinned upstream tag (`UPSTREAM_TAG`), a small `patches/`
directory (two patches so far — see
[docs/UPSTREAM_UPGRADES.md](docs/UPSTREAM_UPGRADES.md)), branding
assets, and build scripts that clone-patch-build fresh every time. This
is exactly
[VSCodium](https://github.com/VSCodium/vscodium)'s own model, chosen
for the same reason they chose it: bumping upstream is "move the pin,
resolve patch conflicts," not a multi-hundred-thousand-line merge, which
is the only way a small team keeps a VS Code fork alive across years of
upstream releases.

## Repository layout

```
UPSTREAM_TAG          pinned microsoft/vscode git tag
patches/               ordered *.patch files applied to the pinned tag
product-overlay.json   branding/identity/gallery overrides merged onto
                       the pinned tag's own product.json at build time
resources/             HUPI icon set (linux/, win32/code.ico, darwin/code.icns)
build/
  build.sh              clone -> patch -> overlay -> build
  smoke-test.sh         headless launch + "did the extension load" check
docs/
  BUILD.md              how to actually build and verify this
  UPSTREAM_UPGRADES.md  how to bump UPSTREAM_TAG
```

## Licensing

`microsoft/vscode`'s own source is MIT-licensed — building it yourself
and rebranding it is exactly what VSCodium already does openly. This
repo's own scripts/assets are MIT too (see [LICENSE](LICENSE)). "Visual
Studio Code" and Microsoft's own specific build of it (telemetry, their
marketplace, their branding) are separate from the OSS source and not
what this repo uses.
