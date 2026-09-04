#!/usr/bin/env node
/**
 * Refuses to send an archive in which any contract address is presented as current while not being
 * the current deployment.
 *
 * Written because a grep for the addresses I remembered came back clean and I concluded the archive
 * had no stale ones. It had four, one generation older than the pair I was looking for, sitting in
 * a superseded response document that nothing kept in sync — next to a sentence claiming the
 * deployed bytecode matched the package byte for byte. Scoping the search to the addresses you
 * already know about can only ever find those.
 *
 * So this runs the other way round: enumerate EVERY address in the archive's prose and require each
 * one to be either a current deployment, a known third-party address, or explicitly marked as
 * historical on its own line.
 */
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) { console.error("usage: check-package-addresses.mjs <archive-root>"); process.exit(2); }

const current = new Set();
const depDir = join(root, "deployments");
if (existsSync(depDir)) {
  for (const f of readdirSync(depDir).filter((n) => n.endsWith(".json"))) {
    const m = JSON.parse(readFileSync(join(depDir, f), "utf8"));
    for (const v of Object.values(m)) {
      if (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v)) current.add(v.toLowerCase());
    }
  }
}
if (current.size === 0) { console.error("no deployment manifests found — cannot judge addresses"); process.exit(2); }

// Addresses that are correctly in the package but belong to somebody else: Flap's Guardian and
// portal, Pancake's router, the identity registry, the rehearsal token the deposit-parity test
// forks against. Each is named where it is used and is not ours to keep current.
const THIRD_PARTY = new Set([
  "0x9e27098dcd8844bcc6287a557e0b4d09c86b8a4b", // Flap Guardian, mainnet
  "0x76fa8c526f8bc27ba6958b76deef92a0dbe46950", // Flap Guardian, testnet
  "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432", // identity registry
  "0x769efabefc18317a846a1e2bdeb831ba659f7777", // testnet rehearsal token, named in the response
  "0x0000000000000000000000000000000000000000",
]);

const HISTORICAL = /previous|superseded|earlier (round|revision|deploy)|historical|no longer|old(er)? deployment/i;

const PROSE = [".md"];
let bad = 0;
for (const name of readdirSync(root)) {
  if (!PROSE.some((e) => name.endsWith(e))) continue;
  const lines = readFileSync(join(root, name), "utf8").split("\n");
  lines.forEach((line, i) => {
    for (const a of line.match(/0x[0-9a-fA-F]{40}/g) ?? []) {
      const k = a.toLowerCase();
      if (current.has(k) || THIRD_PARTY.has(k)) continue;
      if (HISTORICAL.test(line)) continue;
      console.error(`${name}:${i + 1}  ${a} is not a current deployment and is not marked historical`);
      console.error(`  ${line.trim().slice(0, 120)}`);
      bad++;
    }
  });
}

if (bad) { console.error(`\n${bad} stale address${bad > 1 ? "es" : ""} presented as current`); process.exit(1); }
console.log("every address in the archive's prose is current, third-party, or marked historical");
