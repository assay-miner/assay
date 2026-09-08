#!/usr/bin/env node
/**
 * Writes ADDRESSES.md: which address is which contract, and which standard input verifies it.
 *
 * This exists because of the trap the beacon conversion creates for anyone verifying our
 * deployment. Flap asked for "the factory address and the standard-input.json". The factory
 * address their portal calls holds 291 bytes of `BeaconProxy`; `AssayFlapFactory` is 4,361 bytes
 * and lives at a different address. Pairing the two they were given fails, and it fails looking
 * exactly like our source does not match our deployment.
 *
 * A separate file rather than an inline `node -e` in the packaging script: the first version was
 * inline, and bash ate the backticks in the markdown as command substitution.
 *
 * Usage: write-addresses.mjs <manifest.json> <out.md>
 */
import { readFileSync, writeFileSync } from "node:fs";

const [, , manifestPath, outPath] = process.argv;
const m = JSON.parse(readFileSync(manifestPath, "utf8"));

const ROWS = [
  ["AssayFlapFactory", "flapFactory", "flapFactoryBeacon", "flapFactoryImpl"],
  ["Tournament", "tournament", "tournamentBeacon", "tournamentImpl"],
  ["AssayVault", "vault", "vaultBeacon", "vaultImpl"],
  ["AgentRoster", "roster", "rosterBeacon", "rosterImpl"],
  ["PriceGuard", "priceGuard", "priceGuardBeacon", "priceGuardImpl"],
  ["TaskGenerator", "taskGenerator", "taskGeneratorBeacon", "taskGeneratorImpl"],
  ["AssayFlapVault", null, "flapVaultBeacon", "flapVaultImpl"],
];

const b = (s) => "`" + s + "`";
const out = [];
out.push("# Addresses, and what verifies each one");
out.push("");
out.push("BNB Smart Chain, chain 56. Every contract is an implementation behind an");
out.push("`UpgradeableBeacon` whose owner is Flap's Guardian, " + b(m.beaconOwner) + ".");
out.push("");
out.push("**Read the pairing before verifying.** The address the portal calls holds `BeaconProxy`");
out.push("bytecode, not the contract's — the factory proxy is 291 bytes, `AssayFlapFactory` is 4,361.");
out.push("Verifying a proxy address against its contract's standard input fails, and fails looking like");
out.push("the source does not match. Verify the IMPLEMENTATION address against the contract's input;");
out.push("verify the proxy against `standard-json/BeaconProxy.json` and the beacon against");
out.push("`standard-json/UpgradeableBeacon.json`.");
out.push("");
out.push("| Contract | Proxy (what you call) | Beacon | Implementation (what to verify) | standard-json |");
out.push("|---|---|---|---|---|");
for (const [name, p, bn, i] of ROWS) {
  const proxy = p ? b(m[p]) : "one per token, minted by the factory";
  out.push(`| ${b(name)} | ${proxy} | ${b(m[bn])} | ${b(m[i])} | ${b("standard-json/" + name + ".json")} |`);
}
out.push("");
out.push("Compiler settings are carried inside each standard input, so nothing has to be matched by");
out.push("hand. `verify-onchain.mjs` in this archive checks the whole mapping against the chain:");
out.push("each proxy's ERC-1967 beacon slot, each beacon's owner and implementation, and each");
out.push("implementation's runtime against the artifact byte for byte.");
out.push("");

writeFileSync(outPath, out.join("\n"));
console.log(`wrote ${outPath}`);
