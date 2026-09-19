`build/build.sh` applies every `*.patch` file in this directory (in
lexical order) to the freshly-cloned `microsoft/vscode` checkout, before
overlaying branding and the HUPI extension. See
[../docs/UPSTREAM_UPGRADES.md](../docs/UPSTREAM_UPGRADES.md) for what's
here so far and how to carry these forward across an `UPSTREAM_TAG`
bump.
