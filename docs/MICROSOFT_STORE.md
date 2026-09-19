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

## What only a human can do first

1. **Register a Microsoft Partner Center account** — partner.microsoft.com,
   individual tier is a one-time $19 fee, lighter identity verification
   than Azure Trusted Signing's business validation wanted.
2. **Reserve the app name** ("HUPI Code") in Partner Center. This is what
   produces the real `Identity Name` and `Publisher` values —
   `AppxManifest.xml.template`'s `@@IDENTITY_NAME@@`/`@@PUBLISHER@@`
   placeholders — shown on the app's own Identity page afterward. There's
   no way to generate or guess these ahead of time; `package-msix.sh`
   will build a structurally valid `.msix` with the wrong identity until
   these are supplied, and Partner Center will reject that on submission.
3. **A privacy policy URL** — Store submissions require one whenever the
   app makes network calls, which HUPI Code does (to your own configured
   gateway). Needs to live somewhere reachable, e.g. a page on hupi.dev.
4. **The first submission itself** goes through the Partner Center web UI
   by hand — screenshots, description, age rating questionnaire, the
   privacy policy URL above, and the `.msix` from `package-msix.sh`.
   Certification review is usually hours to a few days.

## Once identity values exist

```bash
MSIX_IDENTITY_NAME="<from Partner Center>" \
MSIX_PUBLISHER="<from Partner Center>" \
  ./build/package-msix.sh ./out/VSCode-win32-x64 ./out/hupi-code.msix
```

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
