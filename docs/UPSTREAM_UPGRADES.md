# Bumping the upstream VS Code version

This repo never vendors `microsoft/vscode`'s source — `build/build.sh`
clones it fresh from `UPSTREAM_TAG` every time (the VSCodium model, not
a fork-and-merge model). Upgrading is:

1. Pick a new tag from https://github.com/microsoft/vscode/releases and
   write it to `UPSTREAM_TAG` (just the tag, e.g. `1.139.0`, no `v`
   prefix, no trailing newline weirdness — `git clone --branch` reads it
   literally).
2. Re-run `./build/build.sh`. If `patches/` is non-empty, `git apply`
   will fail loudly on any patch that no longer applies cleanly —
   resolve each one against the new tag's source before moving on
   (`git apply --reject` then hand-fix the `.rej` files is usually
   fastest for a small patch stack).
3. Re-check `product-overlay.json` against the new tag's own
   `product.json` — confirm every key we override still exists with the
   type we expect. This isn't hypothetical: the initial version of this
   overlay set `crashReporter`/`aiConfig`/`appCenter`/`surveys` to
   values that don't exist at all in upstream's `product.json` (they're
   injected separately at Microsoft's own proprietary build time, not
   present in the OSS source), and one of those guesses broke the app
   at startup with `TypeError: Cannot read properties of undefined
   (reading 'concat')` — a real failure caught by actually launching the
   build, not by reading the overlay file. Diff a pristine
   `git show <tag>:product.json` against the previous tag's before
   assuming old overlay values still make sense.
4. Re-run `./build/smoke-test.sh` — confirms the app still starts and
   the HUPI extension still loads as a built-in after all of the above.
5. Bump `hupi/vscode-extension`'s own `engines.vscode` field if the new
   tag's API surface requires it.

## Known-bad upstream release: 1.138.0

`UPSTREAM_TAG` is pinned to `1.137.0`, one release behind the latest at
the time this was written, on purpose. `1.138.0`'s own `npm ci` fails
deterministically — reproduced on two independent machines, 3/3
attempts each — with `spawn /bin/sh ENOENT` partway through
`build/npm/postinstall.ts`, on a **completely vanilla, unmodified**
checkout (no overlay, no patches, no extension bundling involved). This
is a real bug in that specific release's own build tooling, not
something this repo did — confirmed by cloning `1.137.0` plain and
watching the identical `npm ci` succeed cleanly. Worth trying `1.138.0`
again (or whatever's newest) next time this file is used, since it may
already be fixed upstream by then.

## Why removing extensions/copilot happens after npm ci, not before

`build.sh` deletes `extensions/copilot` **after** `npm ci` completes,
never before. `npm ci`'s own postinstall enumerates and installs every
`extensions/*` subdirectory itself, copilot included — deleting it
first leaves a dangling reference that fails with a completely
unrelated-looking `spawn /bin/sh ENOENT` (a real Node quirk: a spawn
whose `cwd` doesn't exist reports exactly this misleading error under
`shell: true`, not a clearer "directory not found"). This is the same
error string as the 1.138.0 bug above but a different, self-inflicted
cause — worth knowing the difference before assuming a new upstream tag
is broken when the real issue is this repo's own step ordering.

## Patches so far

`patches/0001-skip-copilot-ripgrep-shim-when-copilot-not-bundled.patch`
— makes VS Code's own packaging pipeline tolerate `extensions/copilot`
being absent, since it otherwise calls `prepareBuiltInCopilotRipgrepShim`
(`build/lib/copilot.ts`) unconditionally and hard-fails without it. Not
a UI/UX core patch in the Phase 3 sense (see the main README) — narrow
and mechanical, needed just to build without Microsoft's bundled
Copilot at all.

`patches/0002-remove-copilot-setup-steps-from-getting-started.patch` —
the actual first Phase 3 UX-level patch. Upstream's Getting Started
walkthrough (`src/vs/workbench/contrib/welcomeGettingStarted/common/gettingStartedContent.ts`)
leads its first-launch "Setup" walkthrough with one of four variants of
a "Use AI features with Copilot for free" step, hardcoded in core
workbench content — not something `product-overlay.json` reaches, and
not tied to whether `extensions/copilot` is even present (it's shown
based on chat-entitlement context keys, unrelated to the extension
folder). A HUPI-native IDE that already bundles its own chat (the
sidebar and `@hupi` participant, from `hupi/vscode-extension`) shouldn't
lead new users toward a competing product instead. The patch removes
the four `createCopilotSetupStep(...)` step entries and the
now-unused constants/helper feeding them (left in place, they'd fail
the build outright — `src/tsconfig.base.json` sets `noUnusedLocals`).
Investigated but deliberately not used: an enterprise "Account Policy
Gate" mechanism (`accountPolicyGateContribution.ts`) can force-hide
chat-setup UI, but it's policy/entitlement machinery for org-managed
Copilot access, not a general on/off switch — reaching for it here
would have been a bigger, less legible change for the same outcome a
small content patch already gets cleanly.

## A misdiagnosis worth recording: there was no Windows hang

Several windows-x64 CI runs failed with the smoke test reporting
"probe never activated — app likely failed to start", which looked
exactly like the app hanging partway through startup (real log output
stopped right after `update#ctor`, then nothing until the smoke test's
own timeout). Two rounds of patches went out against that theory —
disabling `AgentHostPrewarmContribution` (an eager "prewarm the local
agent-host utility process" optimization in
`src/vs/workbench/services/agentHost/electron-browser/agentHostService.ts`),
then also no-oping `LocalAgentHostServiceClient.startAgentHost()`
(`src/vs/platform/agentHost/electron-browser/localAgentHostService.ts`)
when the first one didn't fix it — plus adding `--verbose --log trace`
to try to see what the "hung" process was doing. None of it changed
the outcome, which in hindsight was the actual signal that the theory
was wrong, not that the fix needed to be more aggressive.

**The real bug was in `build/smoke-test.sh` itself, not the app.** The
probe extension's result-file path is baked as a JS string literal into
`extension.js`, generated from `$RESULT_FILE` (built from `mktemp -d`,
a Git-Bash/MSYS path like `/tmp/tmp.XXXX/probe-result.txt`). That
string is evaluated by the *native* win32 Electron/Node process, which
has no notion of MSYS path translation — a leading `/` resolves as
"root of the current drive", so the probe wrote to
`C:\tmp\tmp.XXXX\probe-result.txt` while bash's own `-f` checks
(correctly MSYS-translated, since those run in bash itself) polled the
real temp directory under `C:\Users\...\AppData\Local\Temp\...`. The
two never matched, so the poll always timed out — indistinguishable
from a real hang from bash's side, even though the app was very
possibly finishing startup and loading the extension correctly the
whole time. This also explains why `--verbose --log trace` showed
nothing new: there was nothing wrong to show.

Found by a human running the build interactively on a real Windows
machine instead of iterating on CI logs — worth remembering as a
general lesson: a verification script failing doesn't always mean the
thing it's verifying is broken.

The fix: `smoke-test.sh` now converts the result-file path via
`cygpath -m` (Git Bash only, a no-op elsewhere) before embedding it —
a real Windows path using forward slashes, valid as a JS string literal
with no backslash-escaping to get wrong, and understood natively by
Node on Windows. The two agent-host patches were reverted (no bug for
them to fix) and `--verbose --log trace` was removed — this project's
own stated policy is one deliberate core patch at a time with a real
justification, not speculative ones left in place after the reasoning
behind them turns out to be wrong.

A second, unrelated portability gap surfaced by the same local-Windows
testing: `build.sh` hardcoded `python3`, which native Windows Python
installs (python.org, the Microsoft Store package) typically don't
provide — only `python.exe`, not `python3.exe`, unlike Linux/macOS
which normally have both. Fixed with a `command -v python3 || command
-v python` fallback resolved once near the top of the script.

## Apple `.p12` certificates must be exported in "legacy" PKCS12 format

`security import` on the macOS CI runner failed every real signing
attempt with `MAC verification failed during PKCS12 import (wrong
password?)`, even after confirming byte-for-byte (decoded file size,
password length) that the certificate and password both crossed from
GitHub Secrets into the runner intact. The password was never wrong —
`openssl pkcs12 -export` (no special flags) on OpenSSL 3.x defaults to
AES-256-CBC encryption with a SHA-256 MAC, a format Apple's own
Security framework's PKCS12 importer doesn't support and reports as
this same misleading "wrong password" error rather than an "unsupported
algorithm" one. The fix: re-export with `openssl pkcs12 -export
-legacy ...` (OpenSSL 3.0+'s flag to fall back to the old
pbeWithSHA1And40BitRC2-CBC / pbeWithSHA1And3-KeyTripleDES-CBC scheme,
the one `security import` actually understands) — same key, same
certificate, same password, only the container's own encryption changed.
Worth remembering for any future Apple certificate this repo ever needs
to re-issue or rotate.
