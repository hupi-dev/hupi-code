# Publishing HUPI Code to the Microsoft Store

This is the *only* Windows distribution channel for HUPI Code, not one
option alongside a direct download — the Store **signs the package
itself** during certification, sidestepping a real blocker: a direct/
sideloaded `.msix`/`.exe` needs our own Windows code-signing certificate
to install without being rejected outright, and Azure Artifact Signing
(the only realistic path to one) gates Public Trust certificates on
geographic/entity eligibility that HUPI doesn't currently meet (see the
main README's Distribution status section for the specifics). It's
Windows-only; there's no macOS equivalent worth pursuing (the Mac App
Store's sandboxing is quite restrictive for a full-featured editor with
filesystem/process access needs — real VS Code itself isn't on it
either, for the same reason).

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
3. ~~A privacy policy URL~~ — done; points at a page on hupi.dev.
4. ~~The first submission~~ — went through the Partner Center web UI by
   hand as of 2026-09-20 (screenshots, description, age rating
   questionnaire, privacy policy URL, the `.msix` from
   `package-msix.sh`, and a `runFullTrust` capability justification —
   `runFullTrust` is required by the Desktop Bridge packaging pattern
   itself, not something HUPI Code opted into). Was in Certification at
   last check.

## Building the package

```bash
./build/package-msix.sh ./out/VSCode-win32-x64 ./out/hupi-code.msix
```

No env vars needed for the common case now that the identity is
committed as the script's default — `MSIX_IDENTITY_NAME`/
`MSIX_PUBLISHER` still override if the reservation is ever redone.

Install it locally first to sanity-check before ever submitting — MSIX
sideload installation needs a self-signed test certificate installed
into the local machine's Trusted People store (Windows-only, `New-
SelfSignedCertificate` + `Add-AppxPackage` — this is strictly for local
testing, never for the real Store submission, which Microsoft signs).
There's no path to a trusted signing certificate of our own for this —
see the main README's Distribution status section.

## Automating further submissions

Done: `build/publish-store-submission.mjs` + the `workflow_dispatch`-only
`.github/workflows/publish-store.yml` automate the update path (create
submission → upload the `.msix` to the submission's Azure Blob SAS URL →
commit → poll status), using the classic Microsoft Store submission API
(`manage.devcenter.microsoft.com/v1.0`, *not* the newer
`api.store.microsoft.com`, which is for hosted exe/msi installers
referenced by URL rather than uploaded MSIX packages). One manual,
one-time Partner Center step it can't do for you: associating a
Microsoft Entra application with the account (**Account settings → User
management → Microsoft Entra applications** tab → add/create one,
assign it the **Manager** role, generate a key) to get the Tenant ID/
Client ID/key that go into the `STORE_TENANT_ID`/`STORE_CLIENT_ID`/
`STORE_CLIENT_SECRET` repo secrets (`STORE_APP_ID` is the Store ID shown
on the app's **Product management → Product identity** page).

Deliberately `workflow_dispatch`-only, never on push: a Store submission
is a real, public, largely irreversible action once committed (Microsoft
starts certification/publishing immediately), so it should never fire
automatically off the back of a merge.
