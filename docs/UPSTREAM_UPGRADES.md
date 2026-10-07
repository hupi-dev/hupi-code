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
reskinning the onboarding wizard for.

**This patch went through three real implementations before the one
that actually works, two of them caught only by building and running
the app for real — worth recording in full, since each failure mode is
a real, general lesson, not specific to this one patch.**

*Attempt 1 — reused `setForceHidden`, appeared to work, didn't.* The
first version called `IChatEntitlementService.setForceHidden()`, the
same API `AccountPolicyGateContribution`
(`services/policies/browser/accountPolicyGateContribution.ts`) already
calls, production-tested, to hide this identical view container for
enterprise-policy-restricted accounts — reused here for a different
reason (no Copilot bundled at all, not a policy restriction). It was
hand-written directly as a unified diff rather than generated from a
real edit via `git diff` (the method 0006 already used safely). The
hunk header for its `chat.shared.contribution.ts` change *undercounted
its own new-line total* (claimed 33, the real diff body had 47) — `git
apply` accepted the mismatched header without complaint and silently
stopped applying after the declared line count, dropping the entire
contribution class and its registration call, leaving only a dangling,
syntactically-valid comment block behind. A full `build/build.sh` run
and `build/smoke-test.sh` pass were recorded against this version
without catching it: the build genuinely had 0 TypeScript errors
(there was nothing of this patch's own code left in the file to error
on), and the smoke test at the time had no assertion for this patch's
own effect at all (only 0004's). Caught afterward by grepping the
*real shipped build's own bundled* `workbench.desktop.main.js` for the
contribution's own ID string — zero matches, confirming the "verified"
build had never actually contained the fix. The general lesson: "0
compile errors" proves a file is syntactically valid, not that the
intended code is present in it — always generate patch hunks from a
real `git diff` against an actual edit, never hand-count context
lines, and grep the *shipped artifact* for a patch's own effect before
trusting an aggregate pass/fail signal.

*Attempt 2 — fixed the hunk, reused `setForceHidden` correctly this
time, still didn't work.* Regenerated the hunk properly (`git diff`
against a real edit in the `src-explore` scratch checkout, confirmed
the contribution class was now genuinely present after a fresh
`0001`-`0007` apply) and rebuilt. The build again had 0 TypeScript
errors, and this time a *direct runtime probe* (not just "did it
compile") read the context key back from the real running app via the
diagnostic command described in 0007 below — and it came back `false`,
not `true`. Traced into `chatEntitlementService.ts`:
`ChatEntitlementContext.setForceHidden()` is a single, shared,
last-write-wins flag (`_forceHidden`), and `AccountPolicyGateContribution`
calls it unconditionally on every startup to assert "not
policy-restricted" (`setForceHidden(false)`) — in a normal,
non-enterprise build, that call runs and silently overwrites whatever
this patch had just set, with no accumulation or ownership semantics
between the two callers. The general lesson: "a production-tested API"
doesn't mean *safe for a second, independent caller* — check every
other call site of a shared mutable flag before assuming it's free to
reuse, not just that it exists and works for its original caller.

*What's actually shipped*: a context key the fix owns exclusively,
nothing shared. The patch adds a new optional `hupiDisableNativeChatView`
field to `IProductConfiguration` (`src/vs/base/common/product.ts`) —
set to `true` in `product-overlay.json` — a new, dedicated
`hupiNativeChatViewHidden` `RawContextKey` declared directly in
`chatParticipant.contribution.ts` (ANDed, negated, into
`chatViewDescriptor`'s existing `when` clause, alongside the existing
`accountPolicyGateActive.negate()` check), and a small new
`HupiNativeChatViewHiddenContribution` `IWorkbenchContribution` in that
same file that binds the key and sets it exactly once, at startup, from
the product flag — nothing else in the codebase ever touches this key,
so there is no equivalent contention risk. (A `RawContextKey`'s own
declared default value turned out *not* to be a safe shortcut either —
a brief middle iteration tried setting only the default, never calling
`.bindTo(...).set(...)` anywhere, reasoning that the context-key
evaluator would fall back to it; the real
`getContextKeyValue`/`Context.getValue` chain, read directly rather
than assumed, never consults a `RawContextKey`'s static default at
all — only an explicit `bindTo` + `set` makes a key's value exist
anywhere. This is why the key is bound in a real contribution, not left
to its declared default.) The view container itself still exists (so
nothing else in the workbench that references its ID breaks), it's
just forced invisible via its own `when` clause evaluating false, and
`chatViewContainer`'s existing `hideIfEmpty: true` then removes it from
the Auxiliary Bar entirely.

**Verified, this time for real, at every level**: the patch applies
cleanly in sequence after `0001`-`0004` against a fresh `1.137.0`
checkout; a full `build/build.sh` run (`0001`-`0007` together) compiled
with 0 TypeScript errors; grepping the *shipped build's own bundled*
`workbench.desktop.main.js` found the contribution's ID string and a
3rd `setForceHidden` call site where only the original 2 upstream ones
existed before (confirming attempt 1's absence and this version's
presence, by direct comparison); and a standalone probe against the
real running app, independent of `build/smoke-test.sh`'s own assertion,
read the context key back and got genuine `raw:true typeof:boolean` —
not inferred from "it didn't crash," read directly.

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

**Follow-up, chased down rather than left open**: 0005 only hides the
Chat *view container* itself — it does not disable
`AgentHostSignedOutModelsNotificationContribution` at the contribution
level, and that contribution's notification is pushed through
`IChatInputNotificationService`, a global singleton whose own doc
comment states content it's given is rendered by *every* mounted chat
input widget ("panel, side bar, …"), not just the one in the view 0005
hides. Quick Chat (`chatQuickInputActions.ts`) is a separate,
independent entry point that can still mount a chat input widget with
the view hidden, which raised a real question: could Quick Chat (or any
other chat input) still show this notification?

Traced and ruled out. The notification scopes itself explicitly —
`agentHostSignedOutModelsNotification.ts`'s own `_createNotification()`
sets `sessionTypes: [SessionType.AgentHostCopilot]`, and
`chatInputNotificationService.ts`'s `isChatInputNotificationApplicableToSessionType`
only renders a notification in a widget whose own session type is in
that list (or the notification sets no `sessionTypes` at all — this one
does). `chatSessionsService.ts` separately defines `localChatSessionType
= SessionType.Local` as "the session type used for local agent chat
sessions" — i.e. ordinary extension-backed chat (what HUPI's own
extension provides) runs as `SessionType.Local`, a different type
entirely from `SessionType.AgentHostCopilot`. `ChatContextKeys.enabled`
(Quick Chat's own precondition) is generic — true whenever any
extension registers a default chat agent with a real implementation,
not Copilot-specific — and nothing in `chatQuickInputActions.ts` or the
generic `chatNewActions.ts` (which has a distinct, separate
`workbench.action.chat.newLocalChat` command) prompts for or switches
session type. The only identified way to actually reach an
`AgentHostCopilot`-typed session is the Agent Sessions view's own
session-type picker — which lives inside the view 0005 already hides,
with no other command found that creates or switches to that session
type independently. No fourth surface found; not fixing anything
further here since there's nothing left to fix.

The patch adds a new optional `hupiDisableCopilotAccountSignIn` field
to `IProductConfiguration` — set to `true` in `product-overlay.json` —
and wraps just that one `registerAction2` call in
`account.contribution.ts` behind it (the adjacent "Sign Out" action,
the rest of the file's account-widget/dashboard UI, and Settings Sync's
own separate, non-Copilot sign-in affordance in the same menu are all
untouched). Verified the same way as 0005: the full `0001`-`0006` chain
applies cleanly in sequence against a fresh `1.137.0` checkout
(`git apply --check`, scratch clone, reverted after), and — same as
0005 — a full `build/build.sh` + `build/smoke-test.sh` run confirmed it
compiles with 0 TypeScript errors and the built app still starts and
loads `hupi.hupi-vscode`. This patch's own effect is a command-presence
question (0005's needed a context-key read instead — see its own entry
above for why, and for a real case where "0 TypeScript errors" and "the
smoke test passed" did *not* mean the fix actually worked) —
`smoke-test.sh` now also asserts
`workbench.action.agenticSignIn` (`AGENTIC_SIGN_IN_COMMAND_ID`,
`src/vs/sessions/common/sessionCommands.ts`) is absent from
`vscode.commands.getCommands(true)`, the exact same technique 0004's
own check already established, confirmed against the real build from
this same run (checked with a standalone probe before wiring the
assertion in, not just trusted because the script didn't throw).

`patches/0007-expose-context-key-read-for-smoke-test-probe.patch` —
diagnostic-only, no user-facing effect, added directly because of
0005's own saga above. Registers one internal, underscore-prefixed
command, `_hupi.getContextKeyValue` (appended to the end of
`chat.shared.contribution.ts`, same file 0005's very first, broken
attempt touched — same "not a public API" convention upstream's own
`_chat.notifyQuestionCarouselAnswer` a few hundred lines above already
uses), that wraps `IContextKeyService.getContextKeyValue` directly. No
public or proposed extension API reads an arbitrary context key's live
value, so without this, `build/smoke-test.sh`'s probe extension has no
way to ask a real running app what a context key's value actually is —
which is exactly the gap that let 0005's first implementation ship
with 0 TypeScript errors and a passing smoke test despite doing
nothing at all. `build/smoke-test.sh` now calls it to assert
`hupiNativeChatViewHidden` (0005's own key) is `true`. Verified the
full `0001`-`0007` chain applies cleanly in sequence against a fresh
`1.137.0` checkout, and — this one especially worth saying plainly —
*used* to catch both of 0005's real bugs before arriving at the version
that actually works: this patch is not theoretical, it is the specific
tool that made the rest of 0005's entry above possible to write
honestly.

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

## Real build + smoke test history for 0005/0006/0007 (2026-10-05)

Superseded by the fuller, corrected account now folded directly into
0005's, 0006's, and 0007's own entries above (0005's in particular
documents two real, build-verification-only-caught failures before the
version that actually works) — kept this section only as a pointer so
a reader scanning dates doesn't wonder whether the day's work went
undocumented. One finding from that day worth repeating here since it's
about the build process itself, not any one patch: `build.sh`'s own
already-documented `nvm.sh`-under-`set -e` gotcha (sourcing it
non-interactively aborts the whole script silently, right after
"installing the exact Node version this tag requires," exit code 3, no
error text) reproduced exactly as described on this exact tag/
environment combination — the documented workaround (temporarily
rename `~/.nvm/nvm.sh` out of the way, with the target Node version's
`bin` directory already on `PATH` directly, then restore it
immediately after) still works. Not a new finding, just a fresh
confirmation it's still accurate.

`patches/0008-restore-all-individually-closed-windows-not-just-last.patch`
— the first patch in this repo against real Microsoft Partner Center
certification feedback (not Microsoft Store; a separate review channel),
not a Copilot-removal patch, and not something found by reading source
in the abstract — found by actually reproducing the report against a
real running build, which changed the diagnosis completely partway
through.

**The report, verbatim**: "Unusable Feature: Primary Functionality - When
users close the code editor window first, before the Sessions window,
they cannot reopen the code editor even after relaunching the product."
Observed on real Windows hardware (Surface Laptop 5, Dell Inspiron
13-5379).

**Starting hypothesis — plausible, and wrong.** `lifecycleMainService.ts`'s
`registerWindow()` tracks a shared `windowCounter` across every
registered main window; its `'closed'` handler fires
`fireOnWillShutdown(QUIT)` the instant `windowCounter` hits 0 on
non-macOS. Separately, `registerAuxWindow()` tracks auxiliary (popped-out)
windows on a completely different path that never touches
`windowCounter` at all. The obvious hypothesis: if the Sessions window is
some kind of auxiliary window rather than a real registered main window,
closing the one real main window (the editor) would drop `windowCounter`
to 0 and fire a premature shutdown — persisting "0 windows to restore"
while the Sessions window is still visibly open on screen.

This turned out to be **wrong**, confirmed two ways before writing a
single line of the actual fix. First, by reading source: `windowImpl.ts`
shows the Sessions/"Agents" window is constructed as a plain `CodeWindow`
— the exact same class and `registerWindow()` path as an editor window —
distinguished only by an `isSessionsWindow` boolean on its
`INativeWindowConfiguration` that picks which HTML entry point to load
(`vs/sessions/electron-browser/sessions.html` vs. the normal
`workbench.html`); `windowsMainService.ts` sets that flag by checking
whether the window's workspace resolves to a dedicated, stable pseudo-
workspace file (`<user-data-dir>/User/agent-sessions.code-workspace`,
`IEnvironmentService.agentSessionsWorkspace`, created on first use via
`ensureAgentsWindow()`). Nothing about it is an auxiliary window. Second,
and more convincingly, by actually running it: with the editor and
Sessions windows both open under `--log trace`, closing the editor window
first produced `Lifecycle#window.on('closed') - window ID 1` with **no**
`Lifecycle#onWillShutdown.fire()` following it — exactly the correct,
non-premature behavior, because the Sessions window (window ID 2) was
still alive and `windowCounter` was still 1. The aux-window theory would
have predicted a premature fire here; it didn't happen.

**Reproducing it for real, including the tooling dead ends.** Getting a
faithful "user clicks the window's own X button" close, rather than
something that only looks like one, took three failed approaches before
one that actually exercised the real code path:

- `curl http://localhost:<port>/json/close/<targetId>` (Chrome DevTools
  Protocol's `Target.closeTarget`, HTTP shortcut) closed the window
  instantly, but `--log trace` showed only
  `Lifecycle#window.on('closed')` — no `'close'` event, no
  `Lifecycle#unload()`, no `Lifecycle#onBeforeCloseWindow.fire()`. This
  bypasses Electron's own `BrowserWindow` close sequence entirely, which
  means it also bypasses `windowsStateHandler.ts`'s
  `onBeforeCloseWindow()` listener — exactly the code this bug lives in.
  Using it would have silently tested nothing.
- CDP's `Page.close` (sent over the raw WebSocket instead of the HTTP
  shortcut, after adding `--remote-allow-origins=*` so the handshake
  wasn't rejected) is documented as running `beforeunload` handlers —
  still produced the identical bare `'closed'`-only log signature. Same
  dead end, just a slower way to find it.
- `xdotool windowclose <id>` (send a real `WM_DELETE_WINDOW` ClientMessage
  to the X11 window, the literal mechanism behind clicking a title bar's
  close button) produced no effect at all and no log output under this
  environment's window-manager-less `Xvfb` — never root-caused further
  since the next approach worked and this one added nothing.

The approach that actually worked: VS Code's own `workbench.action.closeWindow`
command (`Ctrl+Shift+W` / `Alt+F4`, dispatched for real via CDP
`Input.dispatchKeyEvent` against the focused renderer) reliably produced
the complete, real sequence —
`Lifecycle#window.on('close')` → `Lifecycle#unload()` →
`Lifecycle#onBeforeCloseWindow.fire()` → `Lifecycle#window.on('closed')`
— for the **editor** window. It did nothing at all against the
**Sessions** window: `sessions.common.main.ts` imports a leaner
`workbench/browser/actions/windowActions.js` that doesn't include the
electron-specific `CloseWindowAction` the editor's workbench registers,
so that command and its keybinding simply don't exist there. Sessions'
own custom titlebar (`sessions/electron-browser/parts/titlebarPart.ts`)
wires its close icon's click handler directly to
`nativeHostService.closeWindow()` instead — but that icon
(`.window-icon.window-close`) only renders when
`useWindowControlsOverlay()` is false, and this environment's default
window chrome uses Electron's native Window Controls Overlay (confirmed
live: the DOM showed `.window-controls-container.wco-enabled` with no
close-icon child at all) — a real OS-compositor-drawn control with no DOM
element for CDP to click. Setting `window.controlsStyle: "custom"` in the
scratch profile's `settings.json` (the same setting `desktop.contribution.ts`
exposes, "changes require a full restart to apply" per its own
description) forced the DOM-rendered close icon to render for both
windows, making `document.querySelector('.window-icon.window-close').click()`
a faithful, real click on the actual close affordance for either window
type.

**The real mechanism, confirmed live.** With both windows open, closing
the editor first (via its real close button) produced the expected
"nothing happens yet" trace — `windowCounter` still 1, no shutdown. Then
closing the Sessions window (now the last one) produced the full real
shutdown sequence, and the exact
`[WindowsStateHandler] onBeforeShutdown { ... }` trace line it logs
showed:
```
lastActiveWindow: { workspaceIdentifier: { configURIPath: '.../User/agent-sessions.code-workspace' }, ... },
lastPluginDevelopmentHostWindow: undefined,
openedWindows: []
```
— the persisted `storage.json` matched exactly. The editor's own
workspace (`testproject`) does not appear anywhere in the final state.
Root cause, in `windowsStateHandler.ts`: `onBeforeCloseWindow()` only
ever remembers one single window's state as `lastClosedState` — and only
when `windowsMainService.getWindowCount() === 1`, i.e. whichever window
happens to be the very last one standing right before it, too, closes.
`saveWindowsState()`'s broader "all windows" snapshot (`openedWindows`,
used to support `window.restoreWindows: 'all'`, the default) is only
populated from `windowsMainService.getWindows()` live at the moment
`onBeforeShutdown` actually runs — and on Windows/Linux, by the time the
*last* window's `'closed'` event fires `onWillShutdown` → `onBeforeShutdown`,
every window (including ones closed earlier) is already gone from that
list, so it's always empty in this sequential-close scenario. Closing the
editor first, then Sessions, means: the editor's close never gets
remembered anywhere (`getWindowCount()` was 2, not 1, when it closed),
and the Sessions window's close stamps *its own* pseudo-workspace as the
sole `lastActiveWindow`, with `openedWindows` empty. On relaunch (default
`restoreWindows: 'all'`), `doGetPathsFromLastSession()` has only that one
entry to work with — it resolves successfully (the pseudo-workspace file
is real and persists on disk), so the app reopens **only** the
Sessions/"Agents" window. The editor's project is not merely
de-prioritized; its reference is gone from persisted state entirely, and
no further relaunch brings it back. Confirmed live: after the sequence
above, relaunching against the same `--user-data-dir` with no CLI
arguments opened exactly one window, titled "Agents," loading
`sessions.html` — never the editor, never the `testproject` folder.

This is **not** actually specific to the Sessions window, or even to
`isSessionsWindow` — it's a latent gap in `windowsStateHandler.ts`'s
single-slot "last individually-closed window" memory that would equally
lose an earlier-closed *editor* window's state if a user closed two
ordinary project windows one at a time down to zero (as opposed to one
batched `Quit`). The reason this reaches end users here, and reads as a
broken product rather than expected behavior, is specific to how Sessions
is used: it is easy to pop open via `--agents` / `Ctrl+Shift+A` /
"Open Agents Window", is not something most users think of as "a window I
need to manage," and routinely gets left open in the background while the
user closes their actual work. The certification report's "Tested
Without Issue: None" is consistent with that — this reproduces every
time the close order happens to go editor-then-Sessions, not
intermittently.

**The fix.** Track every individually-closed non-extension-host window's
state (`lastClosedWindows: IWindowState[]`, not just the existing single
`lastClosedState`), appended in `onBeforeCloseWindow()` regardless of
`getWindowCount()`, cleared whenever a new window opens (same trigger
that already clears `lastClosedState`). In `saveWindowsState()`, when
`getWindowCount()` is 0 at final shutdown and more than one window closed
this way, use that accumulated list as `openedWindows` instead of leaving
it empty — the same `openedWindows` field upstream already populates from
`getWindows()` directly when two or more windows are simultaneously
*still open* (`getWindowCount() > 1`); this just extends that existing,
already-shipped-and-trusted mechanism to the sequential-close-to-zero
case it previously had no coverage for at all. `lastActiveWindow` keeps
its existing meaning and computation unchanged (already-existing upstream
behavior already lets `lastActiveWindow` duplicate an entry that's also
present in `openedWindows` for the `getWindowCount() > 1` case — this
fix's fallback list follows that same precedent deliberately, rather than
inventing new dedup semantics).

Rejected approach: making the non-macOS premature-shutdown check in
`lifecycleMainService.ts` (`registerWindow`'s `'closed'` handler) also
account for other real or auxiliary windows still open. This was the
natural shape the starting hypothesis pointed at, but there is no bug
there to fix — `windowCounter` already behaves correctly for the Sessions
window specifically because it's a real registered main window, confirmed
live above. Patching code that already works correctly, for a theory the
live trace had already ruled out, would have been exactly the kind of
unverified, plausible-sounding fix this file's own `smoke-test.sh` war
story (above) warns against.

**Verified against a real rebuilt, rerun instance** (not just "it
compiles"): confirmed the full `0001`-`0008` chain applies cleanly in
sequence against a fresh `1.137.0` checkout; ran `build/build.sh` to
completion producing a real `hupi-code` Linux binary; then repeated the
*exact* repro sequence above against the newly built, patched app with a
fresh scratch `--user-data-dir` — open editor + Sessions window, close
editor first (real close-button click, confirmed via the full
`'close'`→`unload`→`onBeforeCloseWindow`→`'closed'` trace), close
Sessions second (the last window), inspect the resulting
`[WindowsStateHandler] onBeforeShutdown { ... }` trace line and persisted
`storage.json`, then relaunch against the same `--user-data-dir` with no
CLI arguments and check which window(s) actually come back. See the
dated follow-up note immediately below for the before/after result of
that specific run.

## 0008 before/after build-verification result (2026-10-06)

Build: `build/build.sh` with `HUPI_EXTENSION_DIR=/home/samuel/repos/hupi/vscode-extension`
(the default `../hupi/vscode-extension` relative path doesn't resolve
from this checkout's actual location — a local environment detail, not
a repo issue) against the `0001`-`0008` chain, `UPSTREAM_TAG=1.137.0`.
79 `tsgo`/typecheck passes in the build log, all "with 0 errors"; grepped
the shipped `resources/app/out/main.js` directly for `lastClosedWindows`
(the patch's own new field name) and found it present — confirming, the
same way 0005's saga insists on, that the fix is actually *in* the built
artifact and not just absent-but-compiling.

**Before (pre-0008, `out11`, built from `0001`-`0007` only)**: editor +
Agents window open, closed editor first (real close-button click,
confirmed `'close'`→`unload`→`onBeforeCloseWindow`→`'closed'` trace),
closed Agents second (last window, triggered real
`onWillShutdown`/shutdown). The logged
`[WindowsStateHandler] onBeforeShutdown { ... }` payload:
```
lastActiveWindow: { workspaceIdentifier: { configURIPath: '.../agent-sessions.code-workspace' }, ... },
openedWindows: []
```
Relaunching against the same `--user-data-dir` with no CLI arguments
opened exactly **one** window: "Agents", loading `sessions.html`. The
editor and its `testproject` folder never came back.

**After (0008 applied, `out12`, same `0001`-`0007` chain plus 0008,
same scratch `--user-data-dir`, same exact click sequence)**: the same
trace point now logs:
```
lastActiveWindow: { workspaceIdentifier: { configURIPath: '.../agent-sessions.code-workspace' }, ... },
openedWindows: [
  { folder: 'file:///.../testproject', backupPath: '.../Backups/578c4b94c3048cedd35c7704837ca554', ... },
  { workspaceIdentifier: { configURIPath: '.../agent-sessions.code-workspace' }, ... }
]
```
— the editor's `testproject` folder is present in `openedWindows` where
it was previously dropped entirely, and `storage.json` on disk matched
this exactly. Relaunching against the same `--user-data-dir` with no CLI
arguments opened **two** windows this time: "Welcome - testproject -
HUPI Code" (`workbench.html`, the real editor, with the correct folder)
and "Agents" (`sessions.html`). The gap the certification report
describes is closed — the editor comes back, every time, regardless of
which window the user happened to close first.

## 0009 — the GitHub Copilot entitlement probe nobody asked for (2026-10-07)

`patches/0009-disable-default-account-provider-copilot-entitlement-probe.patch`
— not found by using a feature and hitting a dead end like 0002-0006,
and not a certification report like 0008; found by auditing the parts
of `product.defaultChatAgent` those patches never touched. 0001-0008
each found and removed a Copilot-shaped *UI* dead end (onboarding, chat
setup, the native chat view, the account menu). None of them touched
the thing that actually resolves whether an account is Copilot-
entitled in the first place — because that machinery has no UI of its
own to notice broken. It just runs, in the background, forever,
against a real Microsoft/GitHub endpoint, using whatever GitHub
credential the user happens to have lying around for something
completely unrelated.

**The mechanism.** `product-overlay.json` has never touched
`defaultChatAgent` itself — only the four `hupiDisableX` booleans layered
around it. That block still carries upstream's real values straight
through to the shipped `product.json`, including
`entitlementUrl: "https://api.github.com/copilot_internal/user"`,
`tokenEntitlementUrl: ".../v2/token"`, `managedSettingsUrl:
".../managed_settings"`, and `providerExtensionId:
"vscode.github-authentication"` — the *generic* built-in GitHub OAuth
provider every VS Code fork ships for Settings Sync, Source Control,
and Pull Requests/Issues, with no Copilot involvement at all.
`src/vs/workbench/services/accounts/browser/defaultAccount.ts`'s
`DefaultAccountProviderContribution` is registered unconditionally via
`registerWorkbenchContribution2(..., WorkbenchPhase.BlockStartup)` — no
`hupiDisableX` check gates it, because it predates all of this chain's
Copilot-UI-specific flags and isn't itself UI. Its constructor
immediately builds a `DefaultAccountProvider` and calls
`defaultAccountService.setDefaultAccountProvider(...)`, which resolves
the account right away and then reschedules itself every
`ACCOUNT_DATA_POLL_INTERVAL_MS` (one hour) for as long as the window
stays open. Each resolution calls `findMatchingProviderSession('github',
providerScopes)`, and `providerScopes` is `[["read:user","user:email",
"repo","workflow"],["user:email"],["read:user"]]` — matched with
`expectedScopes.every(scope => scopes.includes(scope))`, so *any*
existing `github` session with as little as the `read:user` or
`user:email` scope qualifies, not one obtained for Copilot specifically.
If a match exists, `GET https://api.github.com/copilot_internal/user`
(and, depending on the response, `.../v2/token`) fires for real, with
that session's access token attached as `Authorization: Bearer
<token>`. None of patches 0001-0008 touch this file or this
contribution at all.

**Why this matters more than 0001-0006 combined.** Those patches each
stopped a Copilot-shaped dead end from being *shown* to a user who went
looking for Copilot. This one runs regardless of whether anyone ever
opens Chat — the only precondition is having signed into GitHub for any
reason at all (Settings Sync is the obvious one; HUPI Code ships the
generic auth provider, not a Copilot-gated one). A real user's GitHub
OAuth token then gets silently sent to a Microsoft-owned API, hourly,
for the entire time the window is open, to ask a question — "is this
account Copilot-entitled?" — that a Copilot-less IDE has no legitimate
reason to be asking in the first place. This is also, transitively, the
same data source `ChatEntitlementService`'s own Pro/Business/Enterprise
entitlement state and Voice Mode's `isVoiceEntitled()` gate
(`src/vs/workbench/contrib/chat/browser/voiceClient/voiceSessionController.ts`)
both read from (`ChatEntitlementRequests.resolveEntitlement()` calls
`defaultAccountService.refresh({ refreshEntitlements: true })`
directly) — see the Voice Mode re-check below.

**The fix.** Same `hupiDisableX` convention as 0003-0006: a new
`hupiDisableDefaultAccountProvider` field on `IProductConfiguration`
(`src/vs/base/common/product.ts`), set `true` in `product-overlay.json`,
checked at the top of `DefaultAccountProviderContribution`'s
constructor (`defaultAccount.ts`) with an early `return` before
`DefaultAccountProvider` is ever instantiated or registered. Leaving
`IDefaultAccountService`'s provider unset this way is safe, not just
convenient — every consumer already treats "no provider set" as the
ordinary signed-out state via optional chaining
(`this.defaultAccountProvider?.refresh(options)`,
`getDefaultAccountAuthenticationProvider()` falling back to its
hardcoded default) — confirmed by reading those call sites, not
assumed. Folded into the same patch: clearing
`builtInExtensionsEnabledWithAutoUpdates` (upstream hardcodes
`["GitHub.copilot-chat"]` here, inert today since that extension isn't
bundled, but a literal Copilot extension ID sitting in the shipped
`product.json` is worth a reviewer never seeing) — `product-overlay.json`
now sets it to `[]`.

**Rejected approach:** blanking out individual URL fields inside
`defaultChatAgent` (`entitlementUrl`, `tokenEntitlementUrl`, etc.)
directly in `product-overlay.json` instead of adding a new flag. Looked
simpler at first, but `build/build.sh`'s overlay step is a flat
`dict.update()` (Python), not a deep merge — supplying a partial
`defaultChatAgent` object would silently wipe every other field in it
(`extensionId`, `chatExtensionId`, the command-id strings 0002/0003
reference) rather than merge over just the URLs. The new boolean flag
avoids touching that block's shape at all.

**Live-verified before fixing, not just reasoned from source** (same
discipline as 0008): reproducing the real HTTP call without a real
GitHub/Copilot account used a temporary, not-committed debug patch
(`patches/9999-HUPI-DEBUG-temp-not-for-commit.patch`, deleted before
this entry was written) that replaced `DefaultAccountProvider.getSessions()`
with a hardcoded fake session (`scopes: ["read:user"]`, a garbage
access token) and shortened `ACCOUNT_DATA_POLL_INTERVAL_MS` from one
hour to 8 seconds — exercising every real line of unmodified downstream
logic (scope matching, URL construction, the actual `IRequestService`
call) without ever touching a real account. Confirmed first that
outbound HTTPS to the real target is reachable from the build/test
environment (`curl -sI https://api.github.com` → real `HTTP/2 200`), so
a captured 401 below is a genuine round trip to GitHub's production
API, not a local artifact.

**Before (pre-0009, `out-debug-before`, `0001`-`0008` chain plus the
temp debug patch).** Launched under `xvfb-run` with `--log trace`,
`renderer.log` shows, unprompted, at startup:
```
[debug] [DefaultAccount] Getting Default Account from authenticated sessions for provider: github
[warning] [HUPI-DEBUG] getSessions() called for provider github - returning a FAKE session to verify the entitlement request actually fires
[debug] [DefaultAccount] Checking session with scopes ["read:user"]
[debug] [DefaultAccount] Fetching entitlements from: https://api.github.com/copilot_internal/user
[debug] [DefaultAccount] Received 401 for URL https://api.github.com/copilot_internal/user with session hupi-debug-fake-session, likely due to expired/revoked token or insufficient permissions. Trying next session if available.
```
— a real 401 from GitHub's real server, ~250ms round trip, using only
a locally-fabricated fake session. The debug-shortened poll then
re-armed itself and repeated the identical fetch-and-401 sequence
every ~8 seconds, unprompted, for as long as the window stayed open
(six consecutive cycles observed in a 41-second window:
`22:58:33`, `:42`, `:50`, `:58`, `22:59:06`, `:14`), confirming the
production one-hour `RunOnceScheduler` is a real, self-sustaining
repeat, not a one-shot. Independently corroborated by an untouched
`renderer.log` from the prior 0008 testing session
(`scratch-repro/user-data/logs/20261006T214316/window1/renderer.log`,
`0001`-`0008` only, no debug patch, no real GitHub session present),
which already shows this same contribution running unconditionally at
startup and actively checking for a session (`"No matching session
found for provider: github"`) even with nothing to find — proof the
mechanism is live in the real shipped build, not just in this debug
variant.

**After (0009 applied, `out-debug-after`, same `0001`-`0008` chain plus
0009 plus the same temp debug patch, same `run_debug_probe.sh`
sequence).** `renderer.log` (436 lines total) contains:
```
$ grep -c '[DefaultAccount]' renderer.log
0
$ grep -c 'HUPI-DEBUG' renderer.log
0
```
Zero. Not "no HTTP calls" — *no `DefaultAccountProvider` activity of
any kind*, including the debug instrumentation's own fake-session
log line, because `DefaultAccountProviderContribution` returns before
`DefaultAccountProvider` is ever constructed, so the patched
`getSessions()` override is dead code that's never reached. (The
log does still contain unrelated, pre-existing `https://api.github.com`
mentions from a completely different subsystem — `[AgentHost] No
signed-in session resolved for resource: https://api.github.com` —
present in equal numbers in the *before* log too; confirmed this is
baseline noise from AgentHost's own separate GitHub integration, not
a regression or something this patch should have touched.)

**Voice Mode re-check (finding from the same investigation, no
separate patch needed).** `isVoiceEntitled()`
(`voiceSessionController.ts`) requires `ChatEntitlement.Pro` (or
Business/Enterprise), which `ChatEntitlementService` only ever sets
from `ChatEntitlementRequests.resolveEntitlement()` calling
`defaultAccountService.refresh({ refreshEntitlements: true })` —
confirmed by reading that call site directly. With
`hupiDisableDefaultAccountProvider` set, `defaultAccountProvider` is
permanently `null`, so `refresh()`'s `this.defaultAccountProvider?.refresh(options)`
is permanently a no-op returning `null` — there is no longer any live
data source that could ever flip entitlement to Pro, for any account,
real or fake. Not independently live-verified with a real paid Copilot
account (out of scope here — fabricating one wasn't attempted, per the
investigation's own ground rules), but the entitlement context key
itself (`[chat entitlement context] updateContext(): {"entitlement":1}`,
the synchronous startup default) was confirmed identical in both the
before and after debug traces, and the only asynchronous path that
could ever change it is now provably severed by the same zero-activity
result above. No follow-up patch needed — Voice Mode's entitlement gate
is a downstream consequence of this same fix, not a separate bug.

**Verified against a real rebuilt, rerun instance, not just "it
compiles"**: the full `0001`-`0009` chain applies cleanly in sequence
against a fresh `1.137.0` checkout (confirmed in the build log's own
"applying patches" listing for both the debug and the final clean
build); `build/smoke-test.sh` passes against the final `0001`-`0009`
build with no debug patches applied, confirming the app still starts,
the HUPI extension still loads, and none of 0004/0005/0006's own
smoke-test assertions regressed.

## Permanent automated checks for 0008 and 0009 (2026-10-06)

Both 0008 and 0009 were found and verified by hand (CDP-driven real UI
actions, `--log trace`, a temporary debug patch) rather than by any
existing CI check — nothing before this would have caught either
regression coming back. This adds one permanent check per patch, each
shaped to match how that patch actually needs to be observed rather than
forcing both into the same mechanism.

**0009 (`hupiDisableDefaultAccountProvider`) — extended the existing
`build/smoke-test.sh` probe, no new patch needed.** The fix makes
`DefaultAccountProviderContribution` return before ever constructing a
`DefaultAccountProvider` or calling `defaultAccountService.setDefaultAccountProvider()`.
Rather than inventing a new internal probe command the way 0007 did for
0005, this reuses an *existing* upstream context key that already
happens to be gated on the exact same code path:
`CONTEXT_DEFAULT_ACCOUNT_STATE` (`'defaultAccountStatus'`, declared in
`src/vs/workbench/services/accounts/browser/defaultAccount.ts`) is only
ever `.bindTo(contextKeyService)`'d inside `DefaultAccountProvider`'s own
constructor — and that class is only ever instantiated from inside
`DefaultAccountProviderContribution`'s constructor, which is exactly the
call 0009's early `return` skips. Per 0005's own already-documented
finding (a `RawContextKey`'s static default is never consulted by the
real `getContextKeyValue` chain — only an explicit `bindTo` + `set` makes
a key's value exist at all), a key that is never bound reads back as
`undefined`, not as its declared `'uninitialized'` default. So: 0009
working means `_hupi.getContextKeyValue('defaultAccountStatus')` (0007's
probe command, already wired into `smoke-test.sh`'s probe extension)
returns `undefined`; 0009 regressing means it returns some real string,
because the contribution — and the provider it builds — actually ran.
No real GitHub account and no real network call are needed either way:
`build/smoke-test.sh`'s probe extension now also captures this value and
the script fails if it is anything other than `undefined`.

Confirmed empirically, both directions, against real builds already on
disk from this same investigation rather than reasoning from source
alone:
- Against `out-debug-before` (`0001`-`0008` plus 0009's own temporary
  fake-session debug patch, 0009 itself **not** applied): the probe read
  back `defaultAccountStatus:available` — the fake session resolves far
  enough to flip to `Available`, confirming the contribution ran.
- Against `out12` (`0001`-`0008`, no 0009, no debug patch — the closest
  thing to what a real CI run without any GitHub session looks like):
  the probe read back `defaultAccountStatus:uninitialized` — a different
  real string than the debug build's, but still not `undefined`, same
  conclusion.
- Against `out-final` (`0001`-`0009`, no debug patch — the real shipped
  state): the probe read back `defaultAccountStatus:undefined` every
  time.

Running the actual updated `build/smoke-test.sh` (not just a standalone
probe) against both confirms the same thing end-to-end: it exits 0
against `out-final` with the new line in its OK summary, and exits 1
against `out-debug-before` with only the new assertion failing — every
other assertion (`chatSetupCommand:absent`, `agenticSignInCommand:absent`,
`nativeChatViewHidden:true`) still passes on that same build, confirming
the new check fails for the right, specific reason and not as a side
effect of something else being broken.

**0008 (restore all individually closed windows) — a new, dedicated
script, `build/smoke-test-window-state.sh`, not an extension of
`smoke-test.sh`.** This regression only manifests across a real
close → close → relaunch sequence against a persisted `--user-data-dir`,
driving two separate windows through two separate, real close actions —
not something a single-launch, single-process probe extension can
express. The new script automates the exact manual technique this file's
own 0008 section above already proved out: launch the editor window on a
scratch folder; open a second, real Agents window in the *same* running
instance via the `--agents` CLI flag (confirmed live that this routes
through Code's own single-instance IPC to the already-running process,
the same as a user running `code --agents` in a terminal); close the
editor first via a real `Ctrl+Shift+W` dispatched with CDP
`Input.dispatchKeyEvent` (not `Target.closeTarget`/`Page.close`, both of
which bypass the real close sequence entirely — already discovered and
documented above, not rediscovered here); close the Agents window second
via a real click on its DOM close icon through CDP `Runtime.evaluate`
(`window.controlsStyle: "custom"`, seeded into the scratch profile's
`settings.json` before the first launch, makes that icon exist in the DOM
at all — also already discovered above); wait for the process to fully
exit; relaunch against the identical `--user-data-dir` with no CLI
arguments; assert both a `workbench.html` and a `sessions.html` page
target exist in the relaunched process's own CDP `/json/list`.

`/json/list` was chosen as the pass/fail signal over `wmctrl`/`xdotool`
window titles because this environment's Xvfb runs with no window
manager at all (the same reason `xdotool windowclose` didn't work for
the close actions either, per the 0008 investigation above) — a
window-manager-hint-dependent tool is the wrong thing to trust under a
WM-less Xvfb. It was chosen over asserting `openedWindows` in the
persisted state file *before* relaunching because that would only prove
the write side of the fix, not that the app genuinely reopens both real
windows on an actual relaunch — the real, user-facing thing both the
certification report and 0008 itself are about.

A small, dependency-free CDP client (`build/cdp_helper.py`) backs both
the keypress and the close-icon click: hand-rolled HTTP (for
`/json/list`) and raw-socket RFC 6455 framing (for the WebSocket RPC
calls) using only the Python standard library, rather than depending on
`websocket-client` (pip) or a Node-based CDP client — neither is
guaranteed installed, network-reachable, or on `PATH` at this point in a
fresh GitHub Actions job, while `python3` already is (`build.sh` itself
already hard-depends on it).

Linux-only, wired into `.github/workflows/build.yml`'s `linux-x64` job
only, invoked as `xvfb-run -a ./build/smoke-test-window-state.sh ...`
(wrapping the *whole script*, not each individual launch the way
`build/smoke-test.sh`'s own Linux case does — the same reasoning
`build/capture-screenshot.sh`'s own comment already documents for why,
since this script launches the app three separate times and all three
need to land on the same virtual `DISPLAY`). Not extended to
Windows/macOS: those runners provide a real desktop session rather than
Xvfb, and this script's whole technique (the close-icon click, the
`--agents` single-instance relaunch routing, the WM-less-Xvfb framing of
why `/json/list` is trusted over window-manager hints) has only been
verified against this runner's specific xvfb+xdotool setup — extending
it without verifying it there first would be exactly the kind of
unverified, plausible-sounding addition this file's own `smoke-test.sh`
war story (above) already warns against.

**Verified against real builds already on disk, both directions, with
the actual final script** (not a hand-rolled approximation of it):
- Against `out11` (`0001`-`0007`, pre-0008): the script closed the
  editor then the Agents window exactly as described, the app exited,
  and on relaunch only the Agents window's `sessions.html` target ever
  appeared (45s timeout on `workbench.html`) — the script printed the
  exact documented symptom and exited 1.
- Against `out12` (`0001`-`0008`): the identical sequence relaunched
  with both `workbench.html` and `sessions.html` targets present, and
  the script printed its OK summary and exited 0 — run twice in a row
  with the same result, to rule out a one-off timing fluke.

## Extending the 0008 regression check to Windows CI (2026-10-07)

The original certification bug this check guards (above) was reported
from real Windows hardware (a Surface Laptop 5 and a Dell Inspiron
13-5379) — a regression test for it that only ever runs on Linux leaves
exactly the platform that hit the bug unverified in CI. This was
investigated before touching anything, matching this file's own
"verify before fixing" discipline (the `smoke-test.sh` war story above
is the canonical example of why): the question was whether the Linux
technique transfers to `windows-latest`, not whether it's convenient to
assume it does.

**Does Windows CI need an Xvfb-equivalent?** No — confirmed, not
assumed. `windows-latest` already runs a real (non-interactive, but
real) logged-in desktop session that Electron renders actual top-level
windows into, which `build/smoke-test.sh`'s single-launch probe and
`build/capture-screenshot.sh`'s real GDI screen capture already depend
on and already pass against on every `windows-x64` CI run today. Xvfb
exists only because Linux CI runners have no display server at all;
Windows was never missing the thing Xvfb provides in the first place.

**Does the CDP-driven close technique need to change?** Read the real
upstream source for both close actions rather than guess:
- The editor's close (`Ctrl+Shift+W` → `workbench.action.closeWindow`,
  `CloseWindowAction` in
  `src/vs/workbench/electron-browser/actions/windowActions.ts`)
  registers that exact chord as a *secondary* keybinding on both
  `linux` and `win` (primary on both is Alt+F4; only macOS binds
  Cmd+Shift+W as primary). CDP's `Input.dispatchKeyEvent` synthesizes
  the keydown/keyup directly into the renderer's own input pipeline,
  bypassing the host OS's real focus/input queue entirely on any
  platform — it doesn't depend on Linux's WM-less Xvfb quirk to work,
  it was never going through the OS input queue at all.
- The Agents window's close (a DOM click on
  `.window-icon.window-close`): checked whether `Ctrl+Shift+W` could
  replace this everywhere, which would have been the simpler, one-
  technique design the task asked to consider. It can't, on *any* OS:
  `src/vs/sessions/sessions.common.main.ts` only imports the
  platform-agnostic `workbench/browser/actions/windowActions.js`, never
  the electron-specific file `CloseWindowAction` is defined and
  registered in (`workbench/electron-browser/desktop.contribution.ts`).
  The Agents window simply never gets `workbench.action.closeWindow`
  registered, independent of platform — confirmed by reading both
  files' own import lists, not inferred from behavior. So the DOM
  close-icon click stays necessary everywhere this check runs. Whether
  that icon even exists in the DOM is gated in
  `src/vs/workbench/electron-browser/parts/titlebar/titlebarPart.ts` by
  `!hasNativeTitlebar() && !useWindowControlsOverlay()`, under a comment
  that literally reads "Custom Window Controls (Native Windows/Linux)"
  — excluded only for `isMacintosh`. `getTitleBarStyle()`
  (`src/vs/platform/window/common/window.ts`) also defaults to
  `TitlebarStyle.CUSTOM` "on all OS" unless `window.titleBarStyle` is
  explicitly set to native (or on a couple of macOS-only edge cases
  irrelevant here) — so the `window.controlsStyle: "custom"` seed this
  script already plants in the scratch profile's `settings.json` to
  force that close icon to render is not a Linux-specific trick; it
  exercises the identical, shared, non-mac code path on Windows.

**Conclusion: the technique itself is not Linux-specific** — nothing
about either close action's mechanics required Linux. What *was*
genuinely different going from the Linux job to the Windows job: no
`xvfb-run` wrapper (none needed or available), the packaged binary path
(`HUPI Code.exe`, following `build/smoke-test.sh`'s own already-
established per-OS resolution), and the `python3`/`python` fallback
`build/capture-screenshot.sh` already needed for the same reason.
`build/smoke-test-window-state.sh` was made cross-platform in place
(Linux + Windows; macOS deliberately left alone — its native
titlebar/window-controls model is different enough that this
investigation didn't extend the reasoning that far) rather than forked
into a separate Windows-only script, since one script covering both
platforms with a shared `case "$(uname -s)"` block (the same pattern
`build/smoke-test.sh` already uses) is easier to keep correct than two
scripts that would drift. `build/cdp_helper.py` needed no changes at
all — it was already dependency-free stdlib Python with no OS-specific
code path.

**Honesty about verification, matching this file's own stated
discipline**: unlike every other entry in this file, this one is
**reasoned from source, not verified by actually running the updated
script against a real `windows-latest` run** at the time this was
written — this investigation had no interactive access to a real
Windows machine or a way to iterate against one. The reasoning above is
as rigorous as source-reading gets (both close techniques traced to the
exact shared, non-mac code paths that make them platform-independent),
but this repo's own "there was no Windows hang" war story above is a
direct, on-the-nose precedent for why that's not the same as proof:
`build/smoke-test.sh`'s Windows path looked correct by inspection too,
and still shipped with a real bug (an MSYS path baked into a JS string
literal) that only a human iterating on a real Windows machine caught.
The failure mode most likely to repeat that pattern here would be in
process-management plumbing this check leans on more heavily than
`smoke-test.sh` ever did — three separate app launches plus the
`--agents` single-instance relaunch, versus `smoke-test.sh`'s one —
rather than in the close techniques themselves, which is why the CI
wiring started as `continue-on-error: true` rather than immediately
gating the build the way the Linux job's equivalent step does.

**Update**: PR #6's CI (run `37582039737`) then actually exercised this
on a real `windows-latest` runner, and the step reported `success` on
its own merit, not masked by `continue-on-error`. That's the real run
this section said to wait for — the step was flipped to blocking in
`.github/workflows/build.yml`, matching the Linux job's equivalent step.

## 0008 Windows CI: a real flake found right after flipping to blocking

One green run turned out not to be enough. The very next CI run on the
*same commit* (`37593639920`, script content unchanged from
`37582039737`) failed:

```
==> closing the editor window first (real Ctrl+Shift+W via CDP)
cdp_helper.py keypress-close-window: CDP websocket: connection closed mid-frame
##[error]Process completed with exit code 1.
```

A transient WebSocket disconnect during the very first close action —
not a logic regression (nothing in the script changed between the two
runs), and not the same failure shape as the earlier screenshot-capture
hang (that one never completed a step at all; this one failed fast,
cleanly, with a clear error). This is precisely the risk the original
`continue-on-error: true` reasoning called out before ever seeing a
real run: three separate app launches plus the `--agents`
single-instance relaunch is real process-management surface, and a
WebSocket connection over a loaded, possibly-throttled CI runner is a
known source of exactly this kind of drop — more load-bearing
infrastructure than `build/smoke-test.sh`'s single launch has ever
needed.

**Reverted back to `continue-on-error: true`** rather than leaving it
blocking and hoping the flake doesn't recur — a single confirmed pass
was insufficient evidence, and this step gates every future Windows PR
if left blocking. Before attempting the blocking flip again:

1. Harden `build/cdp_helper.py`'s connection handling against a
   transient drop — a bounded retry on initial connect and/or a
   reconnect-and-resume path for a mid-sequence disconnect, rather than
   failing the whole script on the first hiccup.
2. Confirm the hardened version passes several real `windows-latest`
   runs in a row (not just one), the same bar this session has already
   held every other check in this file to.

## Hardening `cdp_helper.py` against the mid-frame disconnect (2026-10-07)

**Tracing the exact failure, not guessing.** The log line is
`cdp_helper.py keypress-close-window: CDP websocket: connection closed
mid-frame`. That exact string is raised in exactly one place in
`cdp_helper.py`: `ws_recv_frame`'s inner `recv_exact`, when `sock.recv()`
returns `b''` (an abrupt TCP EOF) while reading a frame's header or
payload bytes. That's a meaningfully different code path from:
- the WebSocket *handshake* (`ws_connect`), which has its own, different
  message (`"connection closed before headers completed"`) — not what
  fired here, so the TCP connection and the HTTP Upgrade handshake both
  completed successfully;
- a *clean* WebSocket close handshake (opcode `0x8`), which also has its
  own distinct message (`"server closed the connection"`) — not what
  fired here either, so this was a raw, abrupt socket death, not a
  graceful protocol-level close;
- a timeout (`ws_rpc`'s own deadline raises a separate `TimeoutError`) —
  not what fired here, so the process didn't just go quiet, the TCP
  connection itself died.

`cmd_keypress_close_window` makes exactly two `ws_rpc` calls, each
opening its *own* fresh TCP connection (`ws_rpc` calls `ws_connect`
internally): one for the `rawKeyDown` `Input.dispatchKeyEvent`, one for
the `keyUp`. The failure happened on "the first close action" per the
log, i.e. during one of these two calls, after its handshake had already
succeeded and its request had already been sent (`ws_send_text` doesn't
raise) — the socket died while this script was waiting for the JSON
reply.

**Root cause: this is category (a), an inherent property of the
technique, not CI-runner resource contention and not a bug in the
hand-rolled framing.** `rawKeyDown` is what actually fires VS Code's
keybinding service (keybindings act on keydown, not keyup) —
dispatching it is what triggers `workbench.action.closeWindow` to run,
synchronously, inside the renderer whose own CDP agent is the thing
answering this exact RPC. If the close begins tearing the renderer (and
therefore this WebSocket) down before the devtools agent finishes
writing the reply frame, the client sees precisely an abrupt EOF
mid-frame — not a clean close, because there was no time left in the
renderer's lifecycle to perform one. In other words: the thing this
script is trying to cause (the window closing) is itself what kills the
connection used to cause it. This was confirmed by reasoning through the
actual call sequence above, not assumed — and it also explains why this
never showed up in dozens of local Linux runs so far (see below): it's a
timing race, not a deterministic bug, and Linux's Xvfb-driven renderer
teardown happens to be slow enough relative to this script's own
recv loop that the race window hasn't been hit here, while a loaded
`windows-latest` runner apparently can be fast/jittery enough to hit it.

A **bare retry of the same keypress is the wrong fix**: if the close
already succeeded, retrying `Input.dispatchKeyEvent` would try to
reconnect to a WebSocket endpoint that may already be completely gone
(the window — and its devtools agent — no longer exists), turning a
success into a spurious hard failure. The Windows Defender angle from
the task brief was also considered and ruled out: the existing exclusion
(`Add-MpPreference -ExclusionPath "${{ github.workspace }}"`,
`.github/workflows/build.yml`) is a *file-path* real-time-scan exclusion
for `npm ci`'s tens of thousands of writes; it has no mechanism that
would touch a loopback TCP/WebSocket connection, and the failure shape
(abrupt EOF exactly when the close-triggering keydown's reply was due,
not a generic slow/dropped connection at a random point) doesn't match
"antivirus scanning interference" either. A plain CI-runner timing issue
(slow loopback, GC pause) was also considered, and a **bounded retry on
*connection establishment* specifically** was added for that general
class of transient hiccup (see below) — but it is not the explanation
for the actual logged failure, which happened well past the point where
a connect-time retry would even apply (it had already connected,
handshaken, and sent the command).

**What changed in `build/cdp_helper.py`:**
- A new `CDPConnectionLost` exception type distinguishes "the socket
  died abruptly" (mid-frame EOF/reset, or a clean close-frame) from a
  protocol error (bad handshake) or a timeout (target alive but slow) —
  see its docstring.
- `ws_connect` gained a bounded retry (3 attempts, 0.3s apart) around
  connection establishment *and* the handshake only — for the
  CI-runner-timing hypothesis, kept narrowly scoped to the phase where a
  retry can't be ambiguous about whether the target already did what was
  asked.
- `cmd_keypress_close_window` now treats a `CDPConnectionLost` on the
  `rawKeyDown` call as a likely sign the close already happened — it
  logs a clear, specific message to stderr and returns success rather
  than crashing the whole script, instead of trying (and failing) to
  reconnect for the `keyUp`. If `rawKeyDown` got a normal reply, `keyUp`
  is still attempted, and a connection problem there (lost mid-frame, or
  unable to reconnect at all) gets the same tolerant treatment, since the
  keybinding has already fired by that point regardless of what happens
  to `keyUp`. A genuine `TimeoutError` (the target is alive but never
  answers) is deliberately *not* given this treatment anywhere — Python
  3.10+ makes `TimeoutError` a subclass of `OSError`, so this had to be
  special-cased explicitly to avoid accidentally swallowing a real hang
  as if it were a benign disconnect.
- `cmd_click_close_button` (the Agents window's close, which also
  synchronously triggers `nativeHostService.closeWindow()` from inside
  the `Runtime.evaluate` call being answered) gets the same treatment:
  a `CDPConnectionLost` is logged and treated as the click having
  already gone through.
- Critically, **this does not weaken the actual regression check**:
  `build/smoke-test-window-state.sh` already runs an independent
  downstream verification after each close action regardless —
  `wait-absent` (polls `/json/list` until the window is actually gone)
  for the keyboard close, and the subsequent bounded wait for the whole
  app process to exit for the click close. If a close action is logged
  as a "benign" disconnect but the window didn't actually close, those
  checks still fail loudly and specifically, exactly as before. If
  anything this is a *more* accurate test than before the fix: previously
  a transient disconnect on `keypress-close-window` killed the whole
  script immediately (via `set -e`) without ever consulting
  `wait-absent` at all, even in cases where the window really had
  closed — a false failure. A genuine, non-close-related hang
  (`TimeoutError`) still fails fast and loudly, as verified below.

**Verification this isn't just "retry until it looks right": a fake CDP
server test harness** (not committed — a throwaway script, since this
repo doesn't otherwise have a unit-test setup for `cdp_helper.py`) was
used to directly exercise the four scenarios a bare Linux run can't
reliably trigger on demand:
- `rawKeyDown`'s reply connection dropped abruptly → logged as benign,
  exit 0, `keyUp` not attempted (no renderer left to send it to).
- `rawKeyDown` replies normally, `keyUp`'s reply connection then drops →
  logged as benign, exit 0.
- `rawKeyDown` replies normally, the listening socket is gone entirely
  before `keyUp` can even connect (`ConnectionRefusedError`) → logged as
  benign, exit 0.
- Both replies normal (sanity baseline) → silent, exit 0, no spurious
  warnings.
- A target that's simply unreachable from the start (nothing listening)
  → still a real, fast (~0.7s, after the bounded connect retries) hard
  failure, exit 1, clear message. Confirms the connect-retry doesn't
  mask a genuinely broken target.
- A target that accepts the connection, completes the handshake, reads
  the command, and then genuinely hangs (never replies, never
  disconnects) on the `keyUp` call specifically (the one with the
  widened `OSError` catch) → still a real, hard failure after the full
  15s timeout budget, exit 1. This was the one case worth real
  skepticism about (since `TimeoutError` is an `OSError` subclass), and
  it was caught by an explicit `except TimeoutError: raise` ahead of the
  broader catch — confirmed by actually running it, not just reasoning
  about exception hierarchies.

**Local regression check against the real builds already on disk**
(`out11` = pre-0008, `out12`/`out-final` = post-0008, per the "0008
before/after build-verification result" section above), run repeatedly
under `xvfb-run` on this Linux box with the hardened script: **3/3**
runs against `out11` still correctly **FAIL** (`editor present: 0,
Agents present: 1`, patches/0008's own regression signature, unchanged
from pre-hardening behavior), and **8/8** runs across `out12` (3) and
`out-final` (5) still correctly **PASS** (`OK: both the editor window
... and the Agents window reopened`). None of these Linux runs ever hit
the benign-disconnect path — consistent with the root-cause theory above
that this is a narrow timing race more exposed on `windows-latest` than
on this box's Xvfb setup, and confirming the hardening introduced no
regression in the already-proven-correct Linux behavior.

**Not yet run on Windows CI as of this commit** — the fake-server
harness and the Linux regression sweep above are real, but neither one
is `windows-latest`, and this file's own "there was no Windows hang" and
"0008 Windows CI" sections are direct precedent for why source-level
reasoning plus Linux-side testing is not a substitute for actually
watching it on the real runner this bug was found on. The step stays
`continue-on-error: true` in `.github/workflows/build.yml`; it should
only be flipped to blocking after several real `windows-x64` runs are
observed to pass with this change in place (see the follow-up note below
once that evidence exists), and that flip should be a deliberate,
separate decision, not something this change makes unilaterally.
