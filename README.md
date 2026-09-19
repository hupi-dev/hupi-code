# HUPI Code

A HUPI-native fork of VS Code — the chat/inline-edit experience that's
normally an extension you install (`hupi-vscode`, in the
[`hupi`](https://github.com/hupi-dev/hupi) repo) is here a permanent,
built-in part of the editor itself, on first launch, no install step.

## What this actually is right now

Phase 1: a rebranded VS Code — different name, icon, and identity
strings, the HUPI extension bundled in as a true built-in (can't be
disabled or uninstalled from the UI), and an [open-vsx.org](https://open-vsx.org)
extension gallery instead of Microsoft's (whose terms of service forbid
non-Microsoft products from using it — every serious VS Code fork,
VSCodium included, points here instead). No changes to VS Code's own
editor/workbench behavior — a lot of what "feels like Cursor" is
achievable through VS Code's own extension API (native chat UI, inline
ghost-text completions, custom diff panels) without touching upstream
source at all, and that's the direction future work goes in before any
real core patching starts.

Linux only for now — see [docs/BUILD.md](docs/BUILD.md).

## Why this repo is small

VS Code's own source (~19k files) is never vendored here. This repo
holds a pinned upstream tag (`UPSTREAM_TAG`), a `patches/` directory
(empty right now — see [docs/UPSTREAM_UPGRADES.md](docs/UPSTREAM_UPGRADES.md)
for why it exists anyway), branding assets, and build scripts that
clone-patch-build fresh every time. This is exactly
[VSCodium](https://github.com/VSCodium/vscodium)'s own model, chosen
for the same reason they chose it: bumping upstream is "move the pin,
resolve patch conflicts," not a multi-hundred-thousand-line merge, which
is the only way a small team keeps a VS Code fork alive across years of
upstream releases.

## Repository layout

```
UPSTREAM_TAG          pinned microsoft/vscode git tag
patches/               ordered *.patch files (empty for now)
product-overlay.json   branding/identity/gallery overrides merged onto
                       the pinned tag's own product.json at build time
resources/             HUPI icon set
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
