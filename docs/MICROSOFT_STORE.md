# Publishing HUPI Code to the Microsoft Store

Why bother with this alongside the direct Windows download: the Store
**signs the package itself** during certification — you don't need your
own code-signing certificate for this channel (unlike a direct/sideloaded
`.exe`, which does — see the main README's Distribution status section
for that separate effort). It's Windows-only; there's no macOS
equivalent worth pursuing (the Mac App Store's sandboxing is quite
restrictive for a full-featured editor with filesystem/process access
needs — real VS Code itself isn't on it either, for the same reason).

## What's already done (this repo)

- `resources/store/AppxManifest.xml.template` — the package manifest,
  using the "Desktop Bridge" pattern (`EntryPoint="Windows.
  FullTrustApplication"` + the `runFullTrust` capability): the
  Microsoft-documented way to package an existing, unmodified Win32 app
  for the Store. `hupi-code.exe` itself needs zero changes.
- `resources/store/*.png` — the Store's required tile/logo sizes
  (44/71/150/310 square, 310x150 wide, 50x50 store logo, 620x300 splash),
  generated from the existing HUPI icon.
- `build/package-msix.sh` — takes an already-built `VSCode-win32-x64`
  folder (from `build.sh`) and wraps it into a `.msix` via `makeappx.exe`
  (part of the Windows SDK, already on GitHub's `windows-latest` runners).

## Done

1. ~~Register a Microsoft Partner Center account~~ — done.
2. ~~Reserve the app name ("HUPI Code") in Partner Center~~ — done, as of
   2026-09-19. The real `Identity Name`/`Publisher` values from that
   reservation (`HUPICode.HUPICode` /
   `CN=7A8FE7AC-7EFD-475E-8E35-35E59012B58B`) are now the defaults in
   `build/package-msix.sh` and in `AppxManifest.xml.template`'s
   `PublisherDisplayName` — public identifiers, not secrets, so
   committing them directly is fine.

## What only a human can still do

1. **A privacy policy URL** — Store submissions require one whenever the
   app makes network calls, which HUPI Code does (to your own configured
   gateway). Needs to live somewhere reachable, e.g. a page on hupi.dev.
2. **The first submission itself** goes through the Partner Center web UI
   by hand — screenshots, description, age rating questionnaire, the
   privacy policy URL above, and the `.msix` from `package-msix.sh`.
   Certification review is usually hours to a few days.

## Building the package

```bash
./build/package-msix.sh ./out/VSCode-win32-x64 ./out/hupi-code.msix
```

No env vars needed for the common case now that the identity is
committed as the script's default — `MSIX_IDENTITY_NAME`/
`MSIX_PUBLISHER` still override if the reservation is ever redone.

Install it locally first to sanity-check before ever submitting — MSIX
sideload installation needs either a trusted signing certificate (an
Azure Trusted Signing profile, once that's set up for the direct-download
channel, would work here too) or a self-signed test certificate installed
into the local machine's Trusted People store (Windows-only, `New-
SelfSignedCertificate` + `Add-AppxPackage` — this is strictly for local
testing, never for the real Store submission, which Microsoft signs).

## After the first manual submission

Updates can be automated from CI via the Microsoft Store submission API
(`StoreBroker` PowerShell module, or the newer Partner Center REST API +
a GitHub Action like `isaacrlevin/windows-store-publish-action` or
similar) — worth wiring into `.github/workflows/build.yml` once the app
is actually live and updates are a recurring thing, not before.
