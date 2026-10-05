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

`patches/0003-skip-onboarding-wizard-when-copilot-not-bundled.patch` —
a second Phase 3 UX patch, found the same way 0002 was: by actually
looking at a real screenshot, not by auditing source in the abstract
(see the Microsoft Store certification story — the first submission
was rejected for using a website screenshot instead of the app, and the
CI-generated replacement screenshot then revealed this). Upstream's
first-launch onboarding wizard
(`src/vs/workbench/contrib/welcomeOnboarding/browser/onboardingVariationA.ts`)
is a whole multi-step modal (theme picker, keymap picker, a
"Get Started" step) gated entirely on `product.defaultChatAgent` — a
block every upstream `product.json` hardcodes to GitHub Copilot's
identity (sign-in copy, entitlement/quota-check machinery, a
`github.copilot.open.walkthrough` command reference), untouched by
`product-overlay.json`'s rename, and shown regardless of whether
`extensions/copilot` is actually present. Reskinning it to point at
HUPI's own extension instead was considered and rejected: the wizard
assumes Copilot-specific entitlement/quota state HUPI's extension has
no equivalent for, so repointing `defaultChatAgent.extensionId` would
trade one broken wizard for a differently-broken one, not a working
one. The patch adds a new optional `hupiDisableOnboardingWizard` field
to `IProductConfiguration` (`src/vs/base/common/product.ts`) — set to
`true` in `product-overlay.json` — and an early return at the top of
`OnboardingVariationA.show()` when it's set, so the wizard is skipped
outright rather than reskinned. HUPI's own sidebar/chat participant is
already visible in the editor without a wizard needed to introduce it.

`patches/0004-skip-chat-setup-when-copilot-not-bundled.patch` — a third
Phase 3 UX patch for the same `product.defaultChatAgent` root cause as
0002/0003, this time found by actually using the built app's Chat
panel rather than its Getting Started/onboarding surfaces: sending a
message (or running `/init`) with no chat extension active yet trips
`ChatSetupContribution`'s fallback "default agent"
(`src/vs/workbench/contrib/chat/browser/chatSetup/chatSetupContributions.ts`),
which calls `ChatSetupController.doInstall()`
(`chatSetupController.ts`) to silently install
`product.defaultChatAgent.chatExtensionId` — hardcoded upstream to
`GitHub.copilot-chat` — from the configured extension gallery. Since
`product-overlay.json` points the gallery at open-vsx.org, which
doesn't carry that proprietary extension, the install always fails and
surfaces as a user-facing dialog: "An error occurred while setting up
chat. Would you like to try again?" / "The extension
'GitHub.copilot-chat' cannot be installed because it was not found."
Same reasoning as 0003 for not reskinning: `ChatSetupController`'s
entitlement/quota/sign-up machinery is Copilot-specific, with nothing
in HUPI's own extension to repoint it at. The patch adds a new
optional `hupiDisableChatSetup` field to `IProductConfiguration`
(`src/vs/base/common/product.ts`) — set to `true` in
`product-overlay.json` — and an early return at the top of
`ChatSetupContribution`'s constructor when it's set, before any of its
sub-registrations run (the fallback default agent, growth-session
nags, the "Sign In" title bar entry, Copilot-specific command palette
actions, the URL link handler) — the whole contribution is upstream's
Copilot onboarding surface, not just the one call site that happens to
throw. Not yet verified against a real build (only confirmed: the
patch applies cleanly in sequence after 0001-0003 against a fresh
`1.137.0` checkout) — the next full `build/build.sh` run should
exercise this by using the live Chat panel, not just checking that it
launches.

`patches/0005-hide-native-chat-view-when-copilot-not-bundled.patch` —
a fourth Phase 3 UX patch, this time against a root cause that isn't
`product.defaultChatAgent` at all: found from real Microsoft Store
certification feedback, a first submission came back rejected with
"Unusable Feature: Sign In" and a screenshot of the native "Chat" view
container (`chatParticipant.contribution.ts`'s `chatViewContainer`/
`chatViewDescriptor`, which internally renders the "Sessions /
Automations / Chats" Agent Sessions UI) showing a floating "Sign in to
use GitHub Copilot" notification
(`agentSessions/agentHost/agentHostSignedOutModelsNotification.ts`'s
`AgentHostSignedOutModelsNotificationContribution`) sitting over an
otherwise-empty panel. Unlike the old `GitHub.copilot`/
`GitHub.copilot-chat` marketplace extensions (already fully removed by
`build.sh` before `0001` even existed), this view's one built-in
harness — `copilotcli`, provided by the `@github/copilot-sdk` package
imported directly into `platform/agentHost/node/copilot/copilotAgent.ts`
— was never an extension to begin with; that package's own e2e test
suite documents it as "always enabled (the CLI is a dev dependency)".
Confirmed via a direct grep of the `hupi` repo that HUPI's own
extension doesn't register as an agent-host provider or chat
participant at all today, so this entire surface is dead weight for
this build specifically, not a feature HUPI needs — removing it costs
nothing.

Investigated and rejected: skipping the `registerViewContainer`/
`registerViews` calls in `chatParticipant.contribution.ts` outright.
That view's `ChatViewId`/`ChatViewContainerId` constants are referenced
directly elsewhere in the workbench (reveal/focus commands and
similar) with no guard for the view never having been registered at
all — an unknown, unbounded blast radius for a one-off certification
fix, the same category of risk 0003's own doc comment already rejected
reskinning the onboarding wizard for. Used instead:
`IChatEntitlementService.setForceHidden()`, the exact same API
`AccountPolicyGateContribution`
(`services/policies/browser/accountPolicyGateContribution.ts`) already
calls, production-tested, to hide this identical view container for
enterprise-policy-restricted accounts. The patch adds a new optional
`hupiDisableNativeChatView` field to `IProductConfiguration`
(`src/vs/base/common/product.ts`) — set to `true` in
`product-overlay.json` — and a small new `IWorkbenchContribution`
(appended to the end of `chat.shared.contribution.ts`, which already
imports every symbol the new class needs — zero new imports) that
calls `setForceHidden(true)` once at startup when the flag is set. The
view container itself still exists (so nothing else in the workbench
that references its ID breaks), it's just forced invisible via the
same context-key path upstream's own policy gate already relies on,
and `chatViewContainer`'s existing `hideIfEmpty: true` then removes it
from the Auxiliary Bar entirely once its one view's `when` clause
evaluates false. Verified: the patch applies cleanly in sequence after
0001-0004 against a fresh `1.137.0` checkout (`git apply --check`, in a
scratch clone, then reverted — see this repo's own `src-explore`
scratch checkout convention). **Not yet verified against a real
build/launch** — `npm ci`/`tsc` weren't run against the patched tree
(no `node_modules` installed in the scratch checkout used for this),
so the next full `build/build.sh` run should confirm it compiles and
that the Chat view container is actually gone from a running build,
not just that the patch applies.

`patches/0006-remove-copilot-sign-in-from-account-menu.patch` — asked,
after 0005 shipped, whether any other "Sign in to use GitHub Copilot"
surface remained — a real, warranted question, not a hypothetical one.
Grepping every occurrence of that exact string across upstream source
turned up `src/vs/sessions/contrib/accountMenu/browser/account.contribution.ts`:
an unconditional `registerAction2` registering a "Sign In" command
(`AGENTIC_SIGN_IN_COMMAND_ID`) in the Account Menu (the person icon),
shown via `menu.when: defaultAccountStatus != 'available'` — i.e.
whenever the user isn't signed into *any* default account, completely
independent of the Chat view 0005 just hid. Its `run()` calls
`CHAT_SETUP_ACTION_ID`, which 0004 already made inert (the command is
registered inside `ChatSetupContribution`'s `registerActions()`, never
reached once that contribution's constructor returns early) — so
clicking it today silently does nothing. That's not a fix, though: the
menu entry itself, labeled "Sign in to use GitHub Copilot," is still
visibly present and clickable, arguably a worse certification target
than an absent feature (a named, branded button with no effect). Traced
two other `IChatInputNotificationService`-based surfaces from the same
grep pass and ruled them out as already closed: `chatSetupRunner.ts`'s
dialog-title string is only reachable through `ChatSetupController`,
itself only ever constructed from inside the same
`ChatSetupContribution` 0004 disables — no independent instantiation
site exists. `onboardingVariationA.ts`'s two footer/subtitle strings
are downstream of `show()`'s own early return, which 0003 already
added.

One nuance worth recording for any future similar audit: 0005's
`setForceHidden()` approach only hides the Chat *view container* — it
does not disable `AgentHostSignedOutModelsNotificationContribution`
(the notification 0005's own commit message centers on) at the
contribution level. That contribution pushes its notification through
`IChatInputNotificationService`, a global singleton whose own doc
comment states content it's given is rendered by *every* mounted chat
input widget ("panel, side bar, …") — not just the one in the view 0005
hides. Quick Chat (`chatQuickInputActions.ts`) is a separate,
independent entry point that can still mount a chat input widget with
the view hidden. This wasn't chased down further for this patch (0006
only covers the Account Menu item that prompted the question), but it's
the most likely place a *fourth* "Sign in to use GitHub Copilot"
surface could still appear, if a future audit or certification run
turns one up.

The patch adds a new optional `hupiDisableCopilotAccountSignIn` field
to `IProductConfiguration` — set to `true` in `product-overlay.json` —
and wraps just that one `registerAction2` call in
`account.contribution.ts` behind it (the adjacent "Sign Out" action,
the rest of the file's account-widget/dashboard UI, and Settings Sync's
own separate, non-Copilot sign-in affordance in the same menu are all
untouched). Verified the same way as 0005: the full `0001`-`0006` chain
applies cleanly in sequence against a fresh `1.137.0` checkout
(`git apply --check`, scratch clone, reverted after). Not yet verified
against a real build/launch, for the same `node_modules`/`tsc`
availability reason as 0005.

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
