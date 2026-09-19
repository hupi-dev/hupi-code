# Building HUPI Code

Linux only for now (see the repo README for why — Windows/macOS need
those OSes to build on, and this hasn't been done yet).

## Prerequisites

- [nvm](https://github.com/nvm-sh/nvm) — `build.sh` uses it to install
  whatever exact Node version the pinned upstream tag's `.nvmrc`
  demands. This matters more than it sounds: VS Code's own preinstall
  script hard-fails if your Node is older than the pinned version, even
  by a patch release, even within the same major version.
- Linux build dependencies (the same list VS Code's own CI installs,
  from `microsoft/vscode`'s `build/azure-pipelines/linux/*.yml`):
  ```bash
  sudo apt-get install -y pkg-config libgtk-3-0 libxkbfile-dev \
    libkrb5-dev libgbm1 rpm bubblewrap socat libsecret-1-dev libx11-dev
  ```
- Runtime libraries to actually *launch* the built app on a bare Linux
  box (not documented anywhere obvious upstream — found by running the
  built binary and fixing missing-library errors one at a time):
  ```bash
  sudo apt-get install -y libasound2 libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libxss1 xvfb
  ```
- `python3` (build.sh uses it for JSON merging — every real Linux box
  has this already).
- The `hupi` repo checked out as a sibling directory (`../hupi` relative
  to this repo) with a working `vscode-extension/` — or point
  `HUPI_EXTENSION_DIR` at wherever yours lives.

## Build

```bash
OUT_DIR=./out ./build/build.sh
```

Clones `microsoft/vscode` at the tag in `UPSTREAM_TAG`, applies
`patches/*.patch`, overlays `product-overlay.json` onto `product.json`,
drops in HUPI's icon and the built `vscode-extension` as a built-in,
then runs VS Code's own `npm run gulp vscode-linux-x64-min`. Expect
~5-10 minutes on a reasonably fast machine, most of it in `npm ci`
against VS Code's own (large) dependency tree.

**Run it from a directory that allows executing binaries.** If `OUT_DIR`
or your `$TMPDIR` are on a noexec-mounted filesystem, `npm ci` fails
partway through with an unhelpful `Permission denied` from whatever
native module's postinstall script tries to run a downloaded binary —
this looks like nothing related to permissions unless you already know
to look for it.

## Verify

```bash
./build/smoke-test.sh ./out/VSCode-linux-x64
```

Launches the build headlessly (`xvfb-run`) and confirms both that it
starts without crashing and that `hupi.hupi-vscode` actually loaded as a
built-in extension — see the script's own comment for why this needs a
small probe extension rather than a simpler check (`--list-extensions`
and startup logs both turned out not to answer this question; see the
script for exactly why).

## Manual checks worth doing at least once per upstream bump

- `./out/VSCode-linux-x64/bin/hupi-code --version` reports the pinned
  `UPSTREAM_TAG`.
- Launch it for real (not headless), confirm the window title, About
  dialog, and taskbar icon all say "HUPI Code."
- Open the Extensions view and confirm it can search/install something
  from open-vsx.org — `product-overlay.json`'s `extensionsGallery`
  points there instead of Microsoft's marketplace (which forbids
  non-Microsoft products from using it).
