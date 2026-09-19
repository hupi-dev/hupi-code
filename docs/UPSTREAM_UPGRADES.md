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

## Why patches/ is empty right now

Phase 1 (see the main README) deliberately does zero core patches —
branding and the bundled extension cover everything needed so far. The
mechanism above exists and is exercised (the `git apply` loop runs on
every build) so that adding the first real patch later is "drop a file
in `patches/`," not "build this machinery for the first time under
pressure."
