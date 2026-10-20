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
- AppData write virtualization is kept, except for HUPI Code's own data
  folder, `%APPDATA%\HUPI Code`. The manifest excludes just that folder
  (Windows 11 flexible virtualization, `ExcludedDirectory`), which needs
  the `unvirtualizedResources` restricted capability and Windows 10 1903+
  (`MinVersion` 10.0.18362.0). With the MSIX default, writes there
  silently go to the package's private `LocalCache\Roaming` copy, and
  helper programs that extensions start may not see them. Store
  certification hit this: Universal Chat Provider's CLIProxyAPI couldn't
  find the `config.yaml` the extension had just written to its
  `globalStorage` folder. The first fix (hupi-code#12) disabled AppData
  virtualization altogether, and Partner Center denied the capability for
  that, asking for a specific `ExcludedDirectory` instead. See "Restricted
  capability justifications" below for the text Partner Center needs.
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

## Restricted capability justifications

Partner Center asks why the package needs each restricted capability.
Paste these into the submission's capability justification field:

- **runFullTrust:** "HUPI Code is a desktop code editor (a fork of VS
  Code) packaged with the Desktop Bridge pattern; runFullTrust is required
  for any packaged Win32 desktop app."
- **unvirtualizedResources:** the reviewer's questions after the first
  request was denied, answered in order. Fill in the account type before
  pasting:

  ```text
  Account type: [Individual / Company]

  Why: HUPI Code is a code editor (a fork of VS Code). Its extensions write files to their storage folder inside HUPI Code's data folder and then start helper programs (language servers, local proxies, CLIs) that read those files by path. With AppData write virtualization, those writes land in the package's private LocalCache copy, which the helper programs don't see, and the extension fails. This is the error Store certification reported: the Universal Chat Provider extension's CLIProxyAPI helper could not read the config.yaml the extension had just written to %APPDATA%\HUPI Code\User\globalStorage\maxdewald.universal-chat-provider\.

  1. Exact directory: only %APPDATA%\HUPI Code (declared as $(KnownFolder:RoamingAppData)\HUPI Code). Nothing under %LOCALAPPDATA% or %USERPROFILE%\AppData\LocalLow is excluded.
  2. HUPI Code-owned data only: that folder is HUPI Code's own user-data directory (settings, extension storage, logs and caches). HUPI Code creates it and nothing else uses it. All other AppData writes stay virtualized.
  3. Registry: no registry location is excluded and RegistryWriteVirtualization is not changed, so any HKCU writes stay in the package's private hive. HUPI Code makes no HKLM writes.
  4. No Windows or system-directory writes: the exclusion applies only to the folder above, and HUPI Code does not write to the Windows, Program Files or other system directories.
  5. No third-party application data: the exclusion covers only HUPI Code's own folder. Other applications' AppData folders keep normal MSIX virtualization, and the exclusion does not widen what HUPI Code or its extensions can access; it only changes where writes to that one folder are stored.
  6. Declaration (Windows 11 flexible virtualization, a specific ExcludedDirectory rather than disabling file system write virtualization):
     <virtualization:FileSystemWriteVirtualization>
       <virtualization:ExcludedDirectories>
         <virtualization:ExcludedDirectory>$(KnownFolder:RoamingAppData)\HUPI Code</virtualization:ExcludedDirectory>
       </virtualization:ExcludedDirectories>
     </virtualization:FileSystemWriteVirtualization>
     No pre-Windows 11 declaration (desktop6:FileSystemWriteVirtualization) is included, so on Windows 10 AppData stays fully virtualized.
  7. Persistence and uninstall: %APPDATA%\HUPI Code (settings, extension storage, logs, caches) remains after uninstall, as it does for the same editor installed outside the Store, so a reinstall keeps the user's settings. To remove it, the user deletes the %APPDATA%\HUPI Code folder (type %APPDATA% in File Explorer's address bar). Installed extensions live in %USERPROFILE%\.hupi-code, outside AppData, and can be removed the same way.
  8. Assurance: HUPI Code uses unvirtualizedResources only for the scenario described here: keeping its own data folder, %APPDATA%\HUPI Code, visible to the helper processes its extensions start.

  Tested on Windows 11 (build 26100): with this declaration, the extension's helper process starts and reads its config; HUPI Code's data is in %APPDATA%\HUPI Code; and the package's private LocalCache holds only virtualized Windows folders, none of HUPI Code's data.
  ```

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
