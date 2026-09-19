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
