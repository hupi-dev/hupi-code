#!/usr/bin/env bash
# Headless smoke test for a build produced by build.sh: confirms the app
# launches without crashing and that the bundled HUPI extension is
# actually loaded — not just present on disk. Works against a build for
# any of the three platforms build.sh can produce.
#
# Verifying "is the extension loaded" turned out to need more than
# grepping startup logs: hupi-vscode's activationEvents is deliberately
# empty (it activates on a real UI interaction — opening its sidebar —
# not eagerly), so it produces zero log lines in a headless run that
# never opens a workspace or clicks anything. `--list-extensions` also
# doesn't help — it only ever reports user-installed extensions
# (ExtensionType.User), never built-ins (ExtensionType.System), by
# design (see extensionManagementCLI.ts's own listExtensions()).
#
# The only way that actually answers the question: a tiny probe
# extension, planted alongside the real one, that activates on
# `onStartupFinished` and writes `vscode.extensions.all`'s ids to a file.
# That's exactly what this script does, then asserts hupi.hupi-vscode is
# in the result.
#
# The same probe also asserts patches/0004's fix
# (hupiDisableChatSetup) actually took: upstream's
# `workbench.action.chat.triggerSetup` command only exists at all if
# `ChatSetupContribution`'s `registerActions` ran, which is exactly what
# that patch skips. Its absence from `vscode.commands.getCommands(true)`
# is the one check that would have caught the original bug (the "cannot
# be installed because it was not found" Chat Setup dialog) in CI,
# rather than needing a human to notice it by actually using Chat.
#
# Same technique, same reasoning, for patches/0006
# (hupiDisableCopilotAccountSignIn): `workbench.action.agenticSignIn`
# (AGENTIC_SIGN_IN_COMMAND_ID, src/vs/sessions/common/sessionCommands.ts)
# only exists if account.contribution.ts's wrapped `registerAction2` call
# ran, which is exactly what that patch's product.json gate skips. Its
# absence is the automated check that would have caught the original bug
# (the Account Menu's "Sign in to use GitHub Copilot" entry) without
# needing a human to open the Account Menu and look.
#
# patches/0005 (hupiDisableNativeChatView) can't be checked the same
# way — it works by a dedicated context key
# (`hupiNativeChatViewHidden`, pinned once from product.json, never
# bound/set again afterward — see that patch's own doc comment for why
# it deliberately doesn't reuse ChatEntitlementService's shared
# `hidden`/`setForceHidden` mechanism), not by skipping a command's
# registration, and no public (or proposed) extension API reads an
# arbitrary context key's live value. patches/0007
# exists purely to answer that for this script: it registers an
# internal, underscore-prefixed command
# (`_hupi.getContextKeyValue`, same "not a public API" convention
# upstream's own `_chat.notifyQuestionCarouselAnswer` already uses) that
# wraps `IContextKeyService.getContextKeyValue` directly, so this probe
# can ask the real running app what the key's value actually is instead
# of only checking that the patch compiled.
#
# patches/0009 (hupiDisableDefaultAccountProvider) reuses that same
# _hupi.getContextKeyValue probe against an *existing* upstream context
# key rather than needing a new one: `defaultAccountStatus`
# (`CONTEXT_DEFAULT_ACCOUNT_STATE` in
# src/vs/workbench/services/accounts/browser/defaultAccount.ts) is only
# ever bound (`.bindTo(contextKeyService)`) inside `DefaultAccountProvider`'s
# own constructor — and that class is only ever instantiated from inside
# `DefaultAccountProviderContribution`'s constructor, which is exactly
# the call 0009's early `return` skips. No network call, no real GitHub
# account, and no new core patch needed to observe this: when the gate
# is working, the key was never bound at all this session, so
# `getContextKeyValue` returns `undefined`; when it isn't (the
# regression this guards against — the entitlement probe silently
# running and sending a user's GitHub token to
# api.github.com/copilot_internal/* on every startup and hourly after,
# see docs/UPSTREAM_UPGRADES.md's 0009 section), the key is always some
# real string (`uninitialized`/`unavailable`/`available`) because the
# contribution — and the provider it builds — actually ran. Confirmed
# empirically both ways before wiring this in: against a build with
# 0009 reverted this read back `uninitialized` (no real GitHub session
# in a CI-like environment, so it never gets past that), and separately
# `available` against a build that also had the temp fake-session debug
# patch from 0009's own investigation; against the real patched build it
# read back `undefined` in every run.
#
# Usage: ./build/smoke-test.sh /path/to/VSCode-<platform>-<arch>
set -euo pipefail

APP_DIR="${1:?usage: smoke-test.sh <path to VSCode-<platform>-<arch>>}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

# The packaged binary's location/name differs per OS. Linux uses
# electron.ts's explicit linuxExecutableName: product.applicationName
# ("hupi-code"). Darwin and win32 both instead go through
# @vscode/gulp-electron's own packaging (build/gulpfile.vscode.ts sets
# packageJsonUpdates.name = product.nameShort, "HUPI Code" (with a
# space); that flows into the packaged app's package.json, which
# @vscode/gulp-electron's index.js reads as opts.productName, and
# win32.js's renameApp() renames the root .exe to `${productName}.exe`
# — confirmed by inspecting that package's actual source, not guessed,
# after a first win32 smoke-test attempt failed looking for
# "hupi-code.exe" instead of the real "HUPI Code.exe").
case "$(uname -s)" in
  Linux*)
    APP_BIN="$APP_DIR/hupi-code"
    RESOURCES_DIR="$APP_DIR/resources/app"
    ;;
  Darwin*)
    APP_BIN="$APP_DIR/HUPI Code.app/Contents/MacOS/HUPI Code"
    RESOURCES_DIR="$APP_DIR/HUPI Code.app/Contents/Resources/app"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    APP_BIN="$APP_DIR/HUPI Code.exe"
    RESOURCES_DIR="$APP_DIR/resources/app"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

PROBE_DIR="$RESOURCES_DIR/extensions/zzz-smoke-test-probe"
RESULT_FILE="$WORKDIR/probe-result.txt"

# THE ACTUAL BUG behind every "Windows hang" this session chased (agent-
# host patches, the poll-vs-sleep rewrite, --verbose --log trace — none
# of it was wrong to have, but none of it was the cause either): this
# result-file path gets baked as a JS string literal into the probe
# below, which is evaluated by the *native* win32 Electron/Node process,
# not bash — it has no notion of Git Bash's MSYS path translation. A
# bash-side `/tmp/tmp.XXXX/...` path (from mktemp -d) means something
# different to bash (correctly translated for its own `-f` tests further
# down) than it does to that native Node process, which resolves a
# leading `/` as "root of the current drive" — so the probe actually
# wrote to `C:\tmp\tmp.XXXX\...` while bash polled the real temp dir
# under `C:\Users\...\AppData\Local\Temp\...`. They never matched, so
# the 90s poll always timed out — indistinguishable from a real hang
# from bash's side, since the app was very possibly working the whole
# time. `cygpath -m` (Git Bash only; a no-op elsewhere) converts to a
# real Windows path using forward slashes — valid as a JS string literal
# with no backslash-escaping to get wrong, and understood natively by
# Node on Windows.
RESULT_FILE_FOR_JS="$RESULT_FILE"
if command -v cygpath >/dev/null 2>&1; then
  RESULT_FILE_FOR_JS="$(cygpath -m "$RESULT_FILE")"
fi

mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/package.json" <<EOF
{
  "name": "zzz-smoke-test-probe",
  "publisher": "hupi-code-ci",
  "version": "0.0.1",
  "engines": { "vscode": "^1.90.0" },
  "main": "./extension.js",
  "activationEvents": ["onStartupFinished"]
}
EOF
cat > "$PROBE_DIR/extension.js" <<EOF
const vscode = require('vscode');
const fs = require('fs');
async function activate() {
  const ids = vscode.extensions.all.map(e => e.id).sort();
  const commands = await vscode.commands.getCommands(true);
  const chatSetupCommand = commands.includes('workbench.action.chat.triggerSetup') ? 'present' : 'absent';
  const agenticSignInCommand = commands.includes('workbench.action.agenticSignIn') ? 'present' : 'absent';
  const nativeChatViewHidden = await vscode.commands.executeCommand('_hupi.getContextKeyValue', 'hupiNativeChatViewHidden');
  const defaultAccountStatus = await vscode.commands.executeCommand('_hupi.getContextKeyValue', 'defaultAccountStatus');
  fs.writeFileSync('$RESULT_FILE_FOR_JS', ids.join('\n') + '\n---\n' + 'chatSetupCommand:' + chatSetupCommand + '\n' + 'agenticSignInCommand:' + agenticSignInCommand + '\n' + 'nativeChatViewHidden:' + nativeChatViewHidden + '\n' + 'defaultAccountStatus:' + defaultAccountStatus);
}
module.exports = { activate };
EOF

cleanup_probe() { rm -rf "$PROBE_DIR" 2>/dev/null || true; }
# Best-effort cleanup, not a correctness check — `kill "$APP_PID"` below
# only signals the top-level Electron process, not its whole subprocess
# tree (renderer/GPU/extension host), so a file under $WORKDIR/user-data
# can still be open for a moment after. A real run hit exactly this:
# the actual verification passed, but `rm -rf` on a not-yet-released
# file made the *cleanup* fail, which — combined with `set -e` — turned
# a passing smoke test into a false failure. `|| true` here ensures only
# the actual pass/fail checks below ever set the script's exit code.
trap 'cleanup_probe; rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

echo "==> launching to confirm it starts and loads the HUPI extension"
# Linux CI runners have no display at all, hence xvfb; Windows/macOS
# GitHub-hosted runners run as a real logged-in desktop session already,
# so no virtual-display wrapper is needed (or available — xvfb-run/
# `timeout` are both Linux/GNU-specific) on those two. The launch just
# runs the whole app and waits for onStartupFinished, so something has to
# kill it afterward regardless of OS — a portable background+sleep+kill
# replaces `timeout` for that.
LAUNCH=("$APP_BIN" --no-sandbox --disable-gpu --user-data-dir="$WORKDIR/user-data")
case "$(uname -s)" in
  Linux*) LAUNCH=(xvfb-run -a "${LAUNCH[@]}") ;;
esac

"${LAUNCH[@]}" > "$WORKDIR/run.log" 2>&1 &
APP_PID=$!

# Poll for the probe's result file instead of a fixed sleep — a real
# CI run showed Windows cold-starting noticeably slower than Linux/
# macOS: a flat 30s sleep killed the extension host (SIGTERM, exit 143)
# before it ever reached onStartupFinished, even though the app itself
# had launched fine. Polling exits as soon as the probe fires (fast on
# Linux/macOS, which have consistently finished well under 30s) while
# still giving a slower cold start up to MAX_WAIT_SECS before giving up.
MAX_WAIT_SECS=90
for _ in $(seq 1 "$MAX_WAIT_SECS"); do
  if [[ -f "$RESULT_FILE" ]]; then
    break
  fi
  sleep 1
done
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

if [[ ! -f "$RESULT_FILE" ]]; then
  echo "FAIL: probe never activated — app likely failed to start. Log:"
  cat "$WORKDIR/run.log"
  exit 1
fi

if ! grep -qx "hupi.hupi-vscode" "$RESULT_FILE"; then
  echo "FAIL: hupi.hupi-vscode not found among loaded extensions:"
  cat "$RESULT_FILE"
  exit 1
fi

if grep -qx "chatSetupCommand:present" "$RESULT_FILE"; then
  echo "FAIL: workbench.action.chat.triggerSetup is registered — patches/0004's"
  echo "hupiDisableChatSetup gate did not take; Chat will try (and fail) to"
  echo "install GitHub.copilot-chat on first use. Full result:"
  cat "$RESULT_FILE"
  exit 1
fi

if grep -qx "agenticSignInCommand:present" "$RESULT_FILE"; then
  echo "FAIL: workbench.action.agenticSignIn is registered — patches/0006's"
  echo "hupiDisableCopilotAccountSignIn gate did not take; the Account Menu"
  echo "will still show a \"Sign in to use GitHub Copilot\" entry. Full result:"
  cat "$RESULT_FILE"
  exit 1
fi

if ! grep -qx "nativeChatViewHidden:true" "$RESULT_FILE"; then
  echo "FAIL: the hupiNativeChatViewHidden context key is not true —"
  echo "patches/0005's hupiDisableNativeChatView gate did not take; the"
  echo "native Chat view (Sessions/Automations/Chats) will still be visible"
  echo "with a broken \"Sign in to use GitHub Copilot\" notification on it."
  echo "Full result:"
  cat "$RESULT_FILE"
  exit 1
fi

if ! grep -qx "defaultAccountStatus:undefined" "$RESULT_FILE"; then
  echo "FAIL: the defaultAccountStatus context key has a real value instead of"
  echo "being unbound — patches/0009's hupiDisableDefaultAccountProvider gate did"
  echo "not take; DefaultAccountProviderContribution is still constructing a real"
  echo "DefaultAccountProvider, which means the app will silently send any"
  echo "existing GitHub OAuth session's token to"
  echo "api.github.com/copilot_internal/user (and re-check hourly) even though"
  echo "this build has no Copilot entitlement to ever check. Full result:"
  cat "$RESULT_FILE"
  exit 1
fi

echo "OK: HUPI Code started, hupi.hupi-vscode is loaded as a built-in extension,"
echo "upstream's Copilot Chat Setup is confirmed disabled, the native Chat view"
echo "is confirmed force-hidden, the Account Menu's Copilot sign-in command is"
echo "confirmed absent, and the default-account/Copilot-entitlement provider is"
echo "confirmed never registered."
