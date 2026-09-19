# Building HUPI Code

`build.sh` builds for whatever OS/arch it's running *on* — Linux,
Windows, and macOS (arm64) all run this same script (see the script's
own header comment for why cross-compiling to a different OS isn't the
supported path). CI (`.github/workflows/build.yml`) runs all three on
their matching GitHub-hosted runner. The Linux path is the most
battle-tested — hardened through several real build failures caught by
actually running it; the Windows/macOS paths are newer and were written
by reasoning through `microsoft/vscode`'s own build source rather than
by running them locally (this repo doesn't have access to those OSes
outside CI), so expect the first real failures there to need a fix, not
a sign the whole approach is wrong.

## Prerequisites

- **Linux**: [nvm](https://github.com/nvm-sh/nvm) — `build.sh` uses it
  to install whatever exact Node version the pinned upstream tag's
  `.nvmrc` demands. This matters more than it sounds: VS Code's own
  preinstall script hard-fails if your Node is older than the pinned
  version, even by a patch release, even within the same major version.
  Also these build dependencies (the same list VS Code's own CI
  installs, from `microsoft/vscode`'s `build/azure-pipelines/linux/*.yml`):
  ```bash
  sudo apt-get install -y pkg-config libgtk-3-0 libxkbfile-dev \
    libkrb5-dev libgbm1 rpm bubblewrap socat libsecret-1-dev libx11-dev
  ```
  and runtime libraries to actually *launch* the built app on a bare
  Linux box (not documented anywhere obvious upstream — found by running
  the built binary and fixing missing-library errors one at a time):
  ```bash
  sudo apt-get install -y libasound2 libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libxss1 xvfb
  ```
- **Windows**: the exact Node version from the pinned tag's `.nvmrc`
  already on `PATH` (`nvm`-the-Unix-tool doesn't run on native Windows —
  CI uses `actions/setup-node` instead; locally, install that Node
  version some other way), Visual Studio Build Tools + Python for
  native-module compilation, and Git Bash (`build.sh` is a bash script).
- **macOS**: same Node-on-PATH requirement, plus Xcode Command Line
  Tools (`xcode-select --install`) for native-module compilation.
- All platforms: `python3` (build.sh uses it for JSON merging) and the
  `hupi` repo checked out as a sibling directory (`../hupi` relative to
  this repo) with a working `vscode-extension/` — or point
  `HUPI_EXTENSION_DIR` at wherever yours lives.

## Build

```bash
OUT_DIR=./out ./build/build.sh
```

Clones `microsoft/vscode` at the tag in `UPSTREAM_TAG`, applies
`patches/*.patch`, overlays `product-overlay.json` onto `product.json`,
drops in HUPI's icon and the built `vscode-extension` as a built-in,
then runs VS Code's own `npm run gulp vscode-<platform>-<arch>-min` for
the OS/arch it's running on (e.g. `vscode-linux-x64-min` on Linux,
`vscode-win32-x64-min` on Windows, `vscode-darwin-arm64-min` on Apple
Silicon macOS). Expect ~5-10 minutes on a reasonably fast machine, most
of it in `npm ci` against VS Code's own (large) dependency tree. Output
lands at `$OUT_DIR/VSCode-<platform>-<arch>`.

**Run it from a directory that allows executing binaries.** If `OUT_DIR`
or your `$TMPDIR` are on a noexec-mounted filesystem, `npm ci` fails
partway through with an unhelpful `Permission denied` from whatever
native module's postinstall script tries to run a downloaded binary —
this looks like nothing related to permissions unless you already know
to look for it.

## Verify

```bash
./build/smoke-test.sh ./out/VSCode-<platform>-<arch>
```

Launches the build (headlessly via `xvfb-run` on Linux — Windows/macOS
GitHub-hosted runners already run as a real desktop session, so no
virtual-display wrapper is needed or available there) and confirms both
that it starts without crashing and that `hupi.hupi-vscode` actually
loaded as a built-in extension — see the script's own comment for why
this needs a small probe extension rather than a simpler check
(`--list-extensions` and startup logs both turned out not to answer this
question; see the script for exactly why).

## Manual checks worth doing at least once per upstream bump

- `./out/VSCode-<platform>-<arch>/bin/hupi-code --version` (Linux/macOS)
  or `bin\hupi-code.cmd --version` (Windows) reports the pinned
  `UPSTREAM_TAG`.
- Launch it for real (not headless), confirm the window title, About
  dialog, and taskbar/dock icon all say "HUPI Code."
- Open the Extensions view and confirm it can search/install something
  from open-vsx.org — `product-overlay.json`'s `extensionsGallery`
  points there instead of Microsoft's marketplace (which forbids
  non-Microsoft products from using it).
- Windows/macOS specifically: expect an "unknown publisher"/Gatekeeper
  warning on first launch — these builds are unsigned (see the README's
  Distribution status section).
