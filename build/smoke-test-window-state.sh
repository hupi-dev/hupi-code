#!/usr/bin/env bash
# Headless regression test for patches/0008 (restore all individually
# closed windows, not just the last one). Separate from build/smoke-test.sh
# on purpose: that script launches the app exactly once and probes it from
# inside, via an extension — this one has to drive two *separate* windows
# through two *separate*, real close actions, kill the whole app, then
# launch it a second time and check what comes back. That's a genuinely
# different shape of test, not just a bigger version of the same one.
#
# The real bug (see docs/UPSTREAM_UPGRADES.md's 0008 section for the full
# investigation): closing the main editor window first, then the
# "Agents"/Sessions window second, then relaunching against the same
# --user-data-dir, used to silently drop the editor's window state
# entirely — only the Agents window ever reopened. This script automates
# the exact manual repro that investigation already proved out, rather
# than reinventing a new technique:
#
#   1. Launch the app on a scratch folder (the editor window).
#   2. Open a second, real Agents/Sessions window in the *same* running
#      instance via the `--agents` CLI flag (routed through Code's own
#      single-instance IPC to the already-running main process — the same
#      mechanism a user gets from running `code --agents` in a terminal
#      while the app is already open, confirmed live: the already-running
#      instance's own log shows `windowsManager#openAgentsWindow` firing,
#      not the short-lived second CLI process).
#   3. Close the editor window first, the Agents window second — each via
#      a *real* close action, not a CDP shortcut. `Target.closeTarget` /
#      `Page.close` both bypass Electron's actual BrowserWindow close
#      sequence entirely (confirmed in the 0008 investigation: neither one
#      produces windowsStateHandler.ts's `onBeforeCloseWindow()` trace line
#      at all), which means using either here would silently test nothing.
#      The real editor close path is `workbench.action.closeWindow`
#      (default binding Ctrl+Shift+W), dispatched via CDP
#      `Input.dispatchKeyEvent` straight at the renderer — a real keypress,
#      not a shortcut around one. The Agents window has no such command at
#      all (`sessions.common.main.ts` never registers
#      electron's `CloseWindowAction`); its own titlebar wires a close
#      *icon*'s click handler directly to `nativeHostService.closeWindow()`
#      instead, so this script clicks that real DOM element via CDP
#      `Runtime.evaluate`. That icon only renders at all when
#      `window.controlsStyle` is `"custom"` (the default Window Controls
#      Overlay has no DOM element behind it for CDP to click) — this
#      script seeds that setting into the scratch profile before the first
#      launch so no mid-test restart is needed.
#   4. Wait for the whole process to actually exit (closing the last
#      window should trigger a real shutdown, which is exactly the code
#      path patches/0008 touches).
#   5. Relaunch against the identical --user-data-dir with no CLI
#      arguments and `restoreWindows: all` (the default) doing the work.
#   6. Assert both a `workbench.html` (editor) and a `sessions.html`
#      (Agents) page target exist in the relaunched process's own
#      `/json/list` — see "why /json/list" below for why this, and not
#      wmctrl/xdotool or the persisted state file, is the signal used.
#
# Why CDP's /json/list as the pass/fail signal, not wmctrl/xdotool window
# titles: this environment's Xvfb runs with no window manager at all (the
# same 0008 investigation already found `xdotool windowclose` does nothing
# under it, which is why the close actions above don't use it either) —
# wmctrl/xdotool's window listings are populated from X11 window-manager
# hints (_NET_CLIENT_LIST and friends) that a WM-less Xvfb may not
# maintain reliably, so a tool that depends on them is the wrong thing to
# trust here. CDP's /json/list talks to Chromium's own DevTools endpoint
# directly, independent of any window manager, and is the exact same
# mechanism this script already needs for every other step. The
# alternative the task description also raised — asserting
# `openedWindows` in the persisted state file contains both entries
# *before* even relaunching — was considered and rejected as strictly
# weaker: it would only prove the write side of the bug is fixed, not that
# the app genuinely reopens both real windows on a real relaunch, which is
# the actual, user-facing thing patches/0008 fixes and the actual thing
# the certification report complained about.
#
# Linux and Windows, not macOS: extended to windows-x64 CI
# (2026-10-07 investigation, see docs/UPSTREAM_UPGRADES.md's "Extending
# the 0008 regression check to Windows CI" section for the full
# reasoning) after confirming, by reading the real upstream source in
# both cases rather than assuming either way, that neither close
# technique this script depends on is actually Linux-specific:
#
#   - The editor's `Ctrl+Shift+W` close: `CloseWindowAction`
#     (src/vs/workbench/electron-browser/actions/windowActions.ts)
#     registers it as a *secondary* keybinding on both `linux` and `win`
#     (primary is Alt+F4 on both; macOS's only binding is Cmd+Shift+W) —
#     dispatching Ctrl+Shift+W via CDP exercises a real, registered
#     keybinding on Windows exactly as it does on Linux. CDP
#     `Input.dispatchKeyEvent` also synthesizes the keydown/keyup
#     directly in the renderer's own input pipeline, bypassing the
#     host OS's real input/focus queue entirely — whether the window
#     has real OS focus (never guaranteed under a WM-less Xvfb, and not
#     assumed on Windows either) doesn't matter.
#   - The Agents window's close-icon click: genuinely has no
#     `workbench.action.closeWindow` equivalent on *either* OS —
#     `src/vs/sessions/sessions.common.main.ts` only imports the
#     platform-agnostic `workbench/browser/actions/windowActions.js`,
#     never the electron-specific one `CloseWindowAction` lives in, on
#     any platform. So this can't be simplified to "keyboard shortcut
#     everywhere" on either OS — the DOM close-icon click is required
#     for the Agents window regardless. Whether that icon exists in the
#     DOM at all (`.window-icon.window-close`,
#     src/vs/workbench/electron-browser/parts/titlebar/titlebarPart.ts)
#     is gated on `!hasNativeTitlebar() && !useWindowControlsOverlay()`
#     — explicitly commented upstream as "Custom Window Controls (Native
#     Windows/Linux)" and excluded only for `isMacintosh`. The same
#     `window.controlsStyle: "custom"` settings.json seed this script
#     already uses to force that element to exist applies identically on
#     Windows; nothing here is Linux-only in the source.
#
# What *is* genuinely different, and was changed below to account for
# it: there is no Xvfb-equivalent concept on Windows to wrap this in —
# GitHub's windows-latest runner already provides a real, if
# non-interactive, desktop session that Electron renders real top-level
# windows into (the same session build/smoke-test.sh's own single-launch
# probe and build/capture-screenshot.sh's real GDI screenshot capture
# already depend on and already pass against today) — so the `$DISPLAY`
# requirement below only applies on Linux, and CI does not wrap this
# script in anything on Windows. The packaged binary's path also differs
# per OS (see build/smoke-test.sh's own comment for why), so APP_BIN
# below follows that script's same per-OS resolution.
#
# **Not verified against a real windows-latest run at the time this was
# written** — reasoned from reading the actual upstream source for both
# close techniques (above) and from this repo's own already-green
# Windows CI evidence (build/smoke-test.sh and build/capture-screenshot.sh
# already launch, interact with, and screenshot a real window on
# windows-latest today), not from running this exact script there. Three
# separate app launches plus the `--agents` single-instance relaunch is
# more process-management surface than smoke-test.sh's own one-launch
# case already proven on that runner, so treat a first real CI failure
# here as plausibly a genuine new Windows-only wrinkle (this repo's own
# "there was no Windows hang" war story in UPSTREAM_UPGRADES.md is a
# reminder that Windows + Git Bash path/process semantics have already
# produced at least one subtle, non-obvious false negative before) rather
# than assume the regression itself came back. macOS is still not
# covered: its real native titlebar/window-controls model is different
# enough (see `getWindowControlsStyle`'s own `isMacintosh` carve-out
# above) that this investigation did not attempt to extend the reasoning
# that far.
#
# Usage: ./build/smoke-test-window-state.sh /path/to/VSCode-<platform>-<arch>
# On Linux, must already be running under a display server that stays
# alive across multiple separate launches of the app binary (e.g. invoked
# as `xvfb-run -a ./build/smoke-test-window-state.sh ...`, the same
# whole-script-wrapping convention build/capture-screenshot.sh already
# uses and documents — see that script's own comment for why wrapping the
# whole script, rather than each individual launch the way
# build/smoke-test.sh's own single-launch case does, is required whenever
# more than one separate process invocation needs to land on the same
# virtual DISPLAY). On Windows, just run it directly — no wrapper needed
# or available.
set -euo pipefail

APP_DIR="${1:?usage: smoke-test-window-state.sh <path to VSCode-<platform>-<arch>>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDP_HELPER="$SCRIPT_DIR/cdp_helper.py"

# Same python3-or-python fallback build/capture-screenshot.sh already
# needed — native Windows Python installs typically provide only
# python.exe, not a python3.exe alias (see
# docs/UPSTREAM_UPGRADES.md's "python3 hardcoded" note).
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "FAIL: python3 (or python) not found on PATH — required to drive cdp_helper.py" >&2
  exit 1
fi

# Same per-OS binary path resolution build/smoke-test.sh already
# established — see that script's own comment for exactly why each of
# these is what it is. macOS deliberately not handled here yet (see the
# top-of-file comment's "not verified" section); this script exits
# SKIP rather than guessing at an untested macOS technique.
case "$(uname -s)" in
  Linux*)
    APP_BIN="$APP_DIR/hupi-code"
    if [[ -z "${DISPLAY:-}" ]]; then
      echo "FAIL: \$DISPLAY is not set. This script must be run already wrapped in" >&2
      echo "xvfb-run (e.g. 'xvfb-run -a ./build/smoke-test-window-state.sh ...'), not" >&2
      echo "wrapping an internal xvfb-run itself around each launch — it needs the" >&2
      echo "same virtual display to persist across three separate app launches." >&2
      exit 1
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    APP_BIN="$APP_DIR/HUPI Code.exe"
    # No $DISPLAY/Xvfb equivalent needed or available on Windows — see
    # the top-of-file comment for why windows-latest's own desktop
    # session is already sufficient, unlike Linux.
    ;;
  *)
    echo "SKIP: smoke-test-window-state.sh has only been extended to Linux and" >&2
    echo "Windows so far (see this script's own top-of-file comment for why) —" >&2
    echo "nothing to do on $(uname -s)." >&2
    exit 0
    ;;
esac

WORKDIR="$(mktemp -d)"
USER_DATA_DIR="$WORKDIR/user-data"
TESTPROJECT_DIR="$WORKDIR/testproject"

cleanup() {
  # Best-effort only, same reasoning as smoke-test.sh's own cleanup trap:
  # the actual pass/fail checks below are what sets this script's exit
  # code, not whether teardown here is perfectly tidy.
  [[ -n "${APP_PID:-}" ]] && kill -9 "$APP_PID" 2>/dev/null || true
  [[ -n "${RELAUNCH_PID:-}" ]] && kill -9 "$RELAUNCH_PID" 2>/dev/null || true
  # pkill isn't guaranteed present on Windows Git Bash (no procps by
  # default) — best-effort only anyway (see comment above), so just skip
  # it there rather than fail cleanup over a missing tool.
  command -v pkill >/dev/null 2>&1 && pkill -9 -f "$USER_DATA_DIR" 2>/dev/null || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$USER_DATA_DIR/User" "$TESTPROJECT_DIR"
echo "hello" > "$TESTPROJECT_DIR/hello.txt"
# See "real close action" above for why this is needed: forces a real
# DOM close-icon to render for both window types instead of an OS-drawn
# Window Controls Overlay region with nothing for CDP to click. Seeded
# before the very first launch of this scratch profile, so (unlike a
# config change on an existing profile) no restart-to-apply round trip
# is needed — there is no earlier launch for it to have missed.
cat > "$USER_DATA_DIR/User/settings.json" <<'EOF'
{ "window.controlsStyle": "custom" }
EOF

# Pulled out to a function: used for both the first launch and the final
# relaunch, each needing its own freshly-parsed ephemeral debug port.
# --remote-debugging-port=0 (rather than a fixed port, which would risk
# colliding with a concurrent CI job on a shared runner) asks
# Chromium/Electron to pick one and print it to stdout/stderr as
# "DevTools listening on ws://127.0.0.1:<port>/...".
wait_for_devtools_port() {
  local log_file="$1" port=""
  for _ in $(seq 1 60); do
    port="$(sed -nE 's#.*ws://127\.0\.0\.1:([0-9]+)/.*#\1#p' "$log_file" | head -1)"
    [[ -n "$port" ]] && break
    sleep 0.5
  done
  if [[ -z "$port" ]]; then
    echo "FAIL: app never printed a DevTools listening port. Log:" >&2
    cat "$log_file" >&2
    exit 1
  fi
  echo "$port"
}

echo "==> launching the editor window"
"$APP_BIN" --no-sandbox --disable-gpu --disable-workspace-trust --new-window \
  --user-data-dir="$USER_DATA_DIR" --remote-debugging-port=0 --remote-allow-origins='*' \
  "$TESTPROJECT_DIR" > "$WORKDIR/instance1.log" 2>&1 &
APP_PID=$!

PORT="$(wait_for_devtools_port "$WORKDIR/instance1.log")"

EDITOR_WS="$("$PYTHON" "$CDP_HELPER" wait "$PORT" workbench.html 60)" || {
  echo "FAIL: editor window (workbench.html) never appeared. Log:" >&2
  tail -c 4000 "$WORKDIR/instance1.log" >&2
  exit 1
}

echo "==> opening the Agents window via --agents against the same --user-data-dir"
# Routed through Code's own single-instance lock to the already-running
# process above (same mechanism as a user running `code --agents` from a
# terminal while the app is already open) — this second invocation's own
# process just forwards the request and exits; the actual new window
# opens inside the first process, and so shows up on *its* debug port.
"$APP_BIN" --no-sandbox --disable-gpu --user-data-dir="$USER_DATA_DIR" --agents \
  >> "$WORKDIR/instance1.log" 2>&1

AGENTS_WS="$("$PYTHON" "$CDP_HELPER" wait "$PORT" sessions.html 60)" || {
  echo "FAIL: Agents window (sessions.html) never appeared after --agents. Log:" >&2
  tail -c 4000 "$WORKDIR/instance1.log" >&2
  exit 1
}

echo "==> closing the editor window first (real Ctrl+Shift+W via CDP)"
"$PYTHON" "$CDP_HELPER" keypress-close-window "$EDITOR_WS"
"$PYTHON" "$CDP_HELPER" wait-absent "$PORT" workbench.html 30 || {
  echo "FAIL: editor window did not close after dispatching Ctrl+Shift+W." >&2
  "$PYTHON" "$CDP_HELPER" titles "$PORT" >&2
  exit 1
}

echo "==> closing the Agents window second (real DOM close-icon click via CDP)"
CLICKED="$("$PYTHON" "$CDP_HELPER" click-close-button "$AGENTS_WS")"
if [[ "$CLICKED" != "true" ]]; then
  echo "FAIL: the .window-icon.window-close element was not found on the Agents" >&2
  echo "window — window.controlsStyle: custom may not have taken effect, or" >&2
  echo "upstream moved/renamed the close icon." >&2
  exit 1
fi

echo "==> waiting for the app to fully exit"
for _ in $(seq 1 30); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "FAIL: app did not exit within 30s of closing both windows — either the" >&2
  echo "close sequence above didn't really close the last window, or shutdown" >&2
  echo "itself is hanging. Neither is something a relaunch check can usefully" >&2
  echo "run against." >&2
  exit 1
fi
APP_PID=""

echo "==> relaunching against the same --user-data-dir with no CLI arguments"
"$APP_BIN" --no-sandbox --disable-gpu --user-data-dir="$USER_DATA_DIR" \
  --remote-debugging-port=0 --remote-allow-origins='*' \
  > "$WORKDIR/relaunch.log" 2>&1 &
RELAUNCH_PID=$!

RELAUNCH_PORT="$(wait_for_devtools_port "$WORKDIR/relaunch.log")"

# Both windows should reopen as soon as the relaunch reaches the point of
# restoring windows (the default restoreWindows: 'all'); no extra user
# action is needed, so a generous bounded poll (not a fixed sleep) is
# enough and keeps this fast on the common pass case.
EDITOR_BACK=0
AGENTS_BACK=0
if "$PYTHON" "$CDP_HELPER" wait "$RELAUNCH_PORT" workbench.html 45 > /dev/null; then
  EDITOR_BACK=1
fi
if "$PYTHON" "$CDP_HELPER" wait "$RELAUNCH_PORT" sessions.html 10 > /dev/null; then
  AGENTS_BACK=1
fi

kill "$RELAUNCH_PID" 2>/dev/null || true
wait "$RELAUNCH_PID" 2>/dev/null || true
RELAUNCH_PID=""

if [[ "$EDITOR_BACK" -eq 1 && "$AGENTS_BACK" -eq 1 ]]; then
  echo "OK: both the editor window (testproject) and the Agents window reopened"
  echo "after being closed individually (editor first, then Agents) and the app"
  echo "relaunched — patches/0008's fix for the dropped-window-state regression"
  echo "is confirmed still in effect."
  exit 0
fi

echo "FAIL: relaunching after closing editor-then-Agents did not restore both" >&2
echo "windows (editor present: $EDITOR_BACK, Agents present: $AGENTS_BACK) —" >&2
echo "this is patches/0008's own regression: closing the editor window before" >&2
echo "the Agents window, then relaunching, used to lose the editor's window" >&2
echo "state entirely and reopen only the Agents window. See" >&2
echo "docs/UPSTREAM_UPGRADES.md's 0008 section for the full investigation." >&2
echo "Final devtools targets:" >&2
"$PYTHON" "$CDP_HELPER" titles "$RELAUNCH_PORT" >&2 || true
exit 1
