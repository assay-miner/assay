# ASSAY's custom vault UI for flap.sh

Flap's generic vault renderer shows two things and drops everything else: reads that take no
arguments, and write methods. That is why `stats()` exists. This package is the other route —
Flap's [custom component template](https://github.com/flap-sh/flap-vault-component-template) lets
a vault ship its own React component, which is how the bounty list, the crucible and our own
palette get onto their page instead of a column of numbers.

## What is here

Four files, which is all the template permits: `Component.tsx`, `manifest.json`, `VaultABI.ts`,
`i18n.json`. No extra modules, no local assets, no folders — the checker rejects them.

`VaultABI.ts` is generated. Run `node tools/sync-flap-ui-abi.mjs` after changing the vault, and
`--check` in CI; nothing else would catch a signature change, because this package is built
outside this repo.

## What could not come across from the protocol site

The runtime blocks external resources outright, and the identity leans on two of them:

- **The display faces.** Michroma, Chakra Petch and IBM Plex Mono are loaded from a font host.
  There is no `@font-face`, no `@import` and no remote URL inside the sandbox, and the host ships
  no custom families. The component uses the platform mono stack with our tracking and case
  treatment, which carries most of the voice and none of the letterforms.
- **The paper and gold-etch textures.** They are image files. The only admissible route is
  `IpfsImage`/`IpfsBackground` with a pinned CID, so they are recoverable later; for now the gold
  is a gradient rather than a photograph of one, and the crucible is drawn as SVG rather than
  placed as artwork.

Two further constraints shape the layout rather than the palette. `visual-policy/row-heavy-dashboard`
requires one compact business card instead of a stacked multi-section page, so this is a panel and
not a copy of the site. And `risk-status/not-prominent-placement` requires the contract risk badge
above any large visual, so the unverified badge leads and the lockup follows it — which is the
right order on an unverified vault anyway.

The button keeps Flap's chamfered geometry and takes our gold through the two CSS custom
properties their `Button` exposes. A rectangle forced over their cut corner reads as a foreign
control inside their shell.

## State

`yarn vault:check assay` is clean except for one blocking issue, and it is a deployment blocker,
not a design one:

```
manifest-binding/invalid-erc20-token: match.bindings[0].tokenAddresses[0] must be a real deployed
ERC20 token on chainId 97
```

The checker resolves the manifest's binding against the real chain, not against a fork. The
addresses in `manifest.json` are from a fork rehearsal and must be replaced with the real factory
and the real `…7777` tax token once the launch happens. `vault:e2e` needs the same thing.

## Reproducing the preview

```bash
git clone --depth 1 https://github.com/flap-sh/flap-vault-component-template
cd flap-vault-component-template && yarn install
yarn vault:scaffold assay --name "ASSAY Vault UI" --chain 97 \
  --factory 0xYourFactory --token 0xYourReal7777Token --locales en,zh
cp /path/to/assay/flap-ui/* src/vaults/assay/
yarn vault:check assay && yarn dev
```

To preview against a fork, point the template at it with
`NEXT_PUBLIC_BSC_TESTNET_RPC_URL=http://127.0.0.1:8546` in `.env.local`, run
`tools/rehearse.sh` in this repo, and open
`/assay?chainId=97&factoryAddress=…&tokenAddress=…&vaultAddress=…` with the addresses the
rehearsal leaves in `deployments/97-fork-rehearsal.json`.
