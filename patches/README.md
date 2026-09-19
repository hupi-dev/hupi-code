Empty on purpose — see [../docs/UPSTREAM_UPGRADES.md](../docs/UPSTREAM_UPGRADES.md).

`build/build.sh` applies every `*.patch` file in this directory (in
lexical order) to the freshly-cloned `microsoft/vscode` checkout, before
overlaying branding and the HUPI extension. Phase 1 needs zero core
patches — this exists so the mechanism is already proven by the time the
first real one is actually needed.
