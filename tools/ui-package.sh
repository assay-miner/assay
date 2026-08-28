#!/usr/bin/env bash
# Builds dist/assay-vault-ui.zip — the vault UI source package Flap installs beside the contracts.
#
# Four files here are ours: the component, the ABI slice, the strings and the manifest. Everything
# under flap-ui/pkg came out of Flap's own `vault-ui-template` and is carried through untouched,
# because it describes their runtime and not our vault.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

forge build >/dev/null

# The ABI is a slice of the compiled vault, and which functions it carries is read out of
# vaultUISchema(). A stale slice is silent -- calls simply start reverting -- so refuse to package.
node tools/sync-flap-ui-abi.mjs --check

OUT="dist/assay-vault-ui"
rm -rf "$OUT" dist/assay-vault-ui.zip
mkdir -p "$OUT/src/vaults/assay" "$OUT/schemas" "$OUT/config" "$OUT/qa"

cp flap-ui/Component.tsx flap-ui/VaultABI.ts flap-ui/i18n.json flap-ui/manifest.json "$OUT/src/vaults/assay/"
cp flap-ui/pkg/schemas/manifest.schema.json "$OUT/schemas/"
cp flap-ui/pkg/config/mini-app-capability-profiles.json "$OUT/config/"
cp flap-ui/pkg/flap-vault-package.json flap-ui/pkg/package-metadata.json "$OUT/"
# The previous archive carried Flap's own qa/e2e-report.json, whose sourceSha256 described the
# source folder as it stood when their tooling ran. Editing the ABI changes that folder, so the
# report would attest to content this package does not contain. It is left out rather than shipped
# stale: a reviewer regenerates it with `yarn vault:package` against this source.
rmdir "$OUT/qa"

( cd "$OUT" && zip -qr ../assay-vault-ui.zip . )
echo "wrote dist/assay-vault-ui.zip ($(cd "$OUT" && find . -type f | wc -l | tr -d ' ') files)"
echo "sha256 $(shasum -a 256 dist/assay-vault-ui.zip | awk '{print $1}')"
