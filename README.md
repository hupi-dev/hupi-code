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
Cursor" (native chat UI,
inline ghost-text completions, custom diff panels) is reachable that
way, without touching upstream source, and that's still the preferred
direction before reaching for another core patch.

Linux, Windows, and macOS (arm64) all build in CI now — see
[docs/BUILD.md](docs/BUILD.md). The macOS build is now code-signed and
notarized with a real Apple Developer ID in CI (see the Phase 4 note
below). The raw Windows build is **unsigned and not directly
distributed** — see below for why.

## Distribution status (Phase 4)

Every push builds and smoke-tests all three platforms in CI. Linux and
macOS additionally publish to a rolling **"latest" GitHub Release** —
not a numbered version (this repo has no versioning scheme of its own
yet), just the build closest to `main`'s HEAD, updated on every push:
[hupi.dev/downloads](https://hupi.dev/downloads) links directly to
these. macOS is signed with a real Apple Developer ID Application
certificate and notarized (`build/sign-macos.sh` and
`build/notarize-macos.sh`, wired into the `macos-arm64` CI job — signing
reuses microsoft/vscode's own per-process entitlements/
`@electron/osx-sign` pattern, see `build/darwin/`); the release publish
step re-checks `xcrun stapler validate` itself rather than trusting
`notarize-macos.sh`'s own exit code, so a build only reaches the public
"latest" release once notarization has actually finished (see that
script's own comments on why it can legitimately exit 0 without having
stapled anything yet). Signing/notarizing/releasing only runs for
pushes to `main` and same-repo pull requests, since the required
secrets aren't available to fork PRs.

**Windows is Microsoft Store-only, deliberately** — not a temporary gap
to be filled later. A real Windows code-signing certificate (needed for
any direct-download `.msix`/`.exe` to install without being rejected
outright) requires Azure Artifact Signing (formerly "Trusted Signing"),
whose Public Trust certificates gate on real geographic/entity
eligibility: an *individual* must be based in the US or Canada, and an
*organization* needs a registered legal business entity in one of a
specific list of countries (US, Canada, EU, UK, Australia, NZ, Japan,
South Korea, Singapore, Switzerland, Norway, Israel) plus real business
registration paperwork. Neither applies here, so this path is closed for
now, not just unfinished. The Microsoft Store sidesteps this entirely —
Microsoft signs the package itself during certification, no certificate
of our own needed — which is why it's the only Windows channel:
"HUPI Code" is reserved in Partner Center, `build/package-msix.sh`
builds a real `.msix`, and `build/publish-store-submission.mjs` +
`.github/workflows/publish-store.yml` automate submitting it (create
submission, upload, commit, poll — see that workflow's own comments for
why it's `workflow_dispatch`-only, never automatic). A first submission
is already through Partner Center as of 2026-09-20 and was in
Certification at last check.

Auto-update and a nicer macOS installer (a signed DMG instead of the
current plain `.zip` of the notarized `.app`) are still open —
`product-overlay.json`'s `win32AppId`/`win32x64AppId`/etc. are real,
valid GUIDs now (fixed from Phase 1's placeholders) so that work isn't
blocked when it starts, but nothing uses them yet.

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
