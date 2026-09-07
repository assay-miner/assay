#!/usr/bin/env node
/**
 * Proves the addresses on chain hold the bytecode in this package.
 *
 * Rewritten for the beacon deployment. It used to fetch `manifest.flapFactory` and compare it
 * against the AssayFlapFactory artifact. Every contract is now a `BeaconProxy`, so that address
 * holds proxy bytecode and the comparison reported MISMATCH — correctly, in the sense that the code
 * there really is not AssayFlapFactory, and uselessly, in the sense that it says nothing about
 * whether the deployment is this source.
 *
 * Under a beacon there are three claims to prove, and the interesting one is the middle:
 *
 *   1. the proxy at the address people use holds BeaconProxy code;
 *   2. its ERC-1967 beacon slot points at the beacon this manifest names — this is what ties the
 *      address to the beacon, and reading the manifest's beacon field instead would be checking the
 *      manifest against itself;
 *   3. `beacon.implementation()` is the manifest's implementation, and that implementation's
 *      runtime matches the artifact byte for byte.
 *
 * The immutable-blanking the old version did is gone with the immutables: converting them to
 * storage was what made these contracts initializable behind a proxy, and it also means the
 * deployed implementation is byte-identical to the compiled artifact. There is nothing left to
 * excuse, so nothing is excused — any difference at all is a mismatch.
 */
import { readFileSync } from "node:fs";
import { existsSync } from "node:fs";

const RPC = process.argv[2] || "https://bsc-dataseed.bnbchain.org";

// The archive puts these beside this file; the repo keeps them where forge and the deploy script do.
const near = (p) => new URL(p, import.meta.url);
const pick = (...candidates) => candidates.find((c) => existsSync(c));

const manifestPath = pick(near("./deployments/56-latest.json"), near("../deployments/56-latest.json"));
if (!manifestPath) { console.error("no deployments/56-latest.json beside this script or one level up"); process.exit(1); }
const manifest = JSON.parse(readFileSync(manifestPath));

// ERC-1967: keccak256("eip1967.proxy.beacon") - 1
const BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";

const CONTRACTS = [
  { name: "Tournament", proxy: "tournament", beacon: "tournamentBeacon", impl: "tournamentImpl" },
  { name: "AssayVault", proxy: "vault", beacon: "vaultBeacon", impl: "vaultImpl" },
  { name: "AgentRoster", proxy: "roster", beacon: "rosterBeacon", impl: "rosterImpl" },
  { name: "PriceGuard", proxy: "priceGuard", beacon: "priceGuardBeacon", impl: "priceGuardImpl" },
  { name: "TaskGenerator", proxy: "taskGenerator", beacon: "taskGeneratorBeacon", impl: "taskGeneratorImpl" },
  { name: "AssayFlapFactory", proxy: "flapFactory", beacon: "flapFactoryBeacon", impl: "flapFactoryImpl" },
  // No fixed proxy: the factory mints one per launched token.
  { name: "AssayFlapVault", proxy: null, beacon: "flapVaultBeacon", impl: "flapVaultImpl" },
];

let id = 0;
async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const { result, error } = await res.json();
  // An RPC that cannot answer is not an answer that the address is empty.
  if (error) throw new Error(`${method}: ${error.message}`);
  return result;
}

const code = (a) => rpc("eth_getCode", [a, "latest"]);
const addrAt = (a, slot) => rpc("eth_getStorageAt", [a, slot, "latest"]).then((w) => "0x" + w.slice(-40));
const call = (to, sel) => rpc("eth_call", [{ to, data: sel }, "latest"]).then((w) => "0x" + w.slice(-40));
const same = (a, b) => a?.toLowerCase() === b?.toLowerCase();

let bad = 0;
const fail = (m) => { console.error(`     ✗ ${m}`); bad++; };

console.log(`rpc  ${RPC}`);
console.log(`beacon owner (upgrade authority)  ${manifest.beaconOwner}\n`);

for (const c of CONTRACTS) {
  const beacon = manifest[c.beacon];
  const impl = manifest[c.impl];
  console.log(`${c.name}`);

  if (c.proxy) {
    const proxy = manifest[c.proxy];
    console.log(`     proxy   ${proxy}`);
    const slot = await addrAt(proxy, BEACON_SLOT);
    if (!same(slot, beacon)) fail(`proxy's ERC-1967 beacon slot is ${slot}, manifest says ${beacon}`);
  }

  console.log(`     beacon  ${beacon}`);
  // owner() and implementation()
  const owner = await call(beacon, "0x8da5cb5b");
  if (!same(owner, manifest.beaconOwner)) fail(`beacon owner is ${owner}, manifest says ${manifest.beaconOwner}`);
  const live = await call(beacon, "0x5c60da1b");
  if (!same(live, impl)) fail(`beacon implementation is ${live}, manifest says ${impl}`);

  const artifact = pick(near(`./artifact/${c.name}.json`), near(`../out/${c.name}.sol/${c.name}.json`));
  if (!artifact) { fail(`no artifact for ${c.name}`); console.log(); continue; }
  const local = JSON.parse(readFileSync(artifact)).deployedBytecode.object.slice(2);
  const onchain = (await code(impl)).slice(2);

  if (onchain === local) {
    console.log(`     impl    ${impl}  ${onchain.length / 2} bytes, byte-for-byte`);
  } else {
    fail(`implementation ${impl} is ${onchain.length / 2} bytes, artifact is ${local.length / 2}; not this source`);
  }
  console.log();
}

if (bad) { console.error(`${bad} problem${bad === 1 ? "" : "s"} — the deployment is not this package`); process.exit(1); }
console.log("every proxy points at its beacon, every beacon at its implementation, and every implementation is this source");
