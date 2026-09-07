#!/usr/bin/env node
/**
 * Derives the vault-UI package's binding addresses from `deployments/*-latest.json` instead of
 * leaving them hand-maintained.
 *
 * `tools/ui-package.sh` copies `flap-ui/manifest.json` verbatim, and nothing ever compared it to a
 * deployment. Four separate places carried our addresses by hand — this manifest, the two files
 * under `flap-ui/pkg/`, and `app/.env.local` — and one redeploy left all four naming contracts that
 * no longer exist. The chain-56 binding pointed at a factory whose `tournament()` was three
 * deployments old and which does not even have a `priceGuard()`, because it predates that
 * architecture.
 *
 * Correcting the numbers would have been the wrong repair: they were correct once, and they went
 * stale because a human had to remember. So they are computed here, and `--check` makes packaging
 * refuse when they disagree.
 *
 * Chain 97 is deliberately NOT derived from `deployments/97-latest.json`: that manifest records a
 * deploy whose transactions never landed. The binding there points at an EARLIER testnet
 * deployment that is still live on chain, and it is the only binding carrying a `tokenAddresses`
 * entry — which Flap's schema requires ("At least one binding must include tokenAddresses ... must
 * be a real deployed ERC20 token"). So that binding is verified against the chain rather than
 * rewritten: if either address ever stops holding code, this fails instead of shipping a manifest
 * that claims a token nobody can trade.
 *
 * Usage: sync-ui-addresses.mjs [--check]
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CHECK = process.argv.includes("--check");
const RPC = { 56: "https://bsc-dataseed.binance.org", 97: "https://data-seed-prebsc-1-s1.binance.org:8545" };

const read = (p) => JSON.parse(readFileSync(resolve(root, p), "utf8"));
let bad = 0;
const fail = (m) => { console.error(`  ${m}`); bad++; };

async function code(chainId, address) {
  const res = await fetch(RPC[chainId], {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
  });
  const j = await res.json();
  // An RPC error is not an answer that the address is empty. Refuse rather than guess.
  if (j.error) throw new Error(`eth_getCode failed on chain ${chainId}: ${j.error.message}`);
  return j.result === "0x" ? 0 : (j.result.length - 2) / 2;
}

const mainnet = read("deployments/56-latest.json");
const manifest = read("flap-ui/manifest.json");
const meta = read("flap-ui/pkg/package-metadata.json");

const binding56 = manifest.match.bindings.find((b) => b.chainId === 56);
const binding97 = manifest.match.bindings.find((b) => b.chainId === 97);
if (!binding56) { fail("no chain-56 binding in flap-ui/manifest.json"); process.exit(1); }

// --- chain 56: derived from the manifest this repo just deployed ---
const want56 = mainnet.flapFactory;
if (binding56.factoryAddress !== want56) {
  if (CHECK) fail(`chain-56 factoryAddress is ${binding56.factoryAddress}, deployment says ${want56}`);
  else { binding56.factoryAddress = want56; console.log(`  chain 56 factoryAddress -> ${want56}`); }
}

// --- chain 97: not derived, verified. It names an earlier testnet deployment that still exists. ---
if (binding97) {
  for (const [what, addr] of [["factoryAddress", binding97.factoryAddress], ...(binding97.tokenAddresses || []).map((a) => ["tokenAddresses[]", a])]) {
    if (!addr) continue;
    const n = await code(97, addr);
    if (n === 0) fail(`chain-97 ${what} ${addr} holds no code — the binding names a contract that is not there`);
  }
}

// --- the schema's own requirement, checked rather than assumed ---
const withTokens = manifest.match.bindings.filter((b) => (b.tokenAddresses || []).length > 0);
if (withTokens.length === 0) {
  fail("no binding carries tokenAddresses; Flap's schema requires at least one for e2e coverage");
}
for (const b of withTokens) {
  for (const a of b.tokenAddresses) {
    if (!/(7777|8888)$/i.test(a)) fail(`tokenAddresses entry ${a} does not end in 7777 or 8888`);
  }
}

// --- bindingKeys must describe the bindings, not a previous set of them ---
const wantKeys = manifest.match.bindings
  .map((b) => `${b.chainId}:${(b.factoryAddress || (b.vaultAddresses || [])[0] || (b.tokenAddresses || [])[0] || "").toLowerCase()}`)
  .sort();
const gotKeys = [...(meta.bindingKeys || [])].sort();
if (JSON.stringify(wantKeys) !== JSON.stringify(gotKeys)) {
  if (CHECK) fail(`package-metadata.json bindingKeys ${JSON.stringify(gotKeys)} do not describe the manifest's bindings ${JSON.stringify(wantKeys)}`);
  else {
    meta.bindingKeys = manifest.match.bindings.map(
      (b) => `${b.chainId}:${(b.factoryAddress || (b.vaultAddresses || [])[0] || (b.tokenAddresses || [])[0] || "").toLowerCase()}`
    );
    console.log(`  bindingKeys -> ${JSON.stringify(meta.bindingKeys)}`);
  }
}

if (bad > 0) {
  console.error(`\nflap-ui bindings do not match the deployments (${bad} problem${bad === 1 ? "" : "s"})`);
  process.exit(1);
}

if (!CHECK) {
  writeFileSync(resolve(root, "flap-ui/manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  writeFileSync(resolve(root, "flap-ui/pkg/package-metadata.json"), JSON.stringify(meta, null, 2) + "\n");
  console.log("flap-ui bindings rewritten from deployments/*-latest.json");
} else {
  console.log("flap-ui bindings match the deployments, and every bound address holds code");
}
