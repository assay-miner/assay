#!/usr/bin/env node
/**
 * Regenerates flap-ui/VaultABI.ts from the compiled AssayFlapVault artifact.
 *
 * The Flap package lives outside this repo's build, so nothing else would catch a signature
 * change. A hand-written frontend ABI drifts the moment one happens, and the drift is silent:
 * calls just start reverting or decoding to nonsense. `--check` fails when the committed copy
 * no longer matches what the contracts compile to.
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifact = resolve(repo, "out/AssayFlapVault.sol/AssayFlapVault.json");
const target = resolve(repo, "flap-ui/VaultABI.ts");

// Which functions to ship was a hand-kept list, which drifts exactly the way a hand-kept ABI
// does: four methods added to the vault over two weeks never reached the package, `maxConvertible`
// and `scheduleEndow` among them. Flap's renderer calls whatever `vaultUISchema()` declares, so
// that is the list — read out of the contract source — plus whatever the component calls itself.
const vaultSource = readFileSync(resolve(repo, "src/AssayFlapVault.sol"), "utf8");
const schemaBody = vaultSource.slice(vaultSource.indexOf("function vaultUISchema"));
const declared = [...schemaBody.matchAll(/m\.name = "([A-Za-z0-9_]+)"/g)].map((m) => m[1]);
if (declared.length === 0) {
  console.error("found no methods in vaultUISchema() — the pattern it is read with has changed");
  process.exit(1);
}

const component = readFileSync(resolve(repo, "flap-ui/Component.tsx"), "utf8");
const called = [...component.matchAll(/functionName: *"([A-Za-z0-9_]+)"/g)].map((m) => m[1]);

// Reads the component derives from rather than calls by name, and the ledger fields a reviewer
// checks solvency against.
const SUPPORTING = ["bounty", "collected", "endowed", "payouts", "reward", "taxToken",
  "totalPaid", "unassigned", "reserved", "freeTax", "description"];

const WANT = new Set([...declared, ...called, ...SUPPORTING]);

if (!existsSync(artifact)) {
  console.error(`missing artifact: ${artifact}\nrun \`forge build\` first`);
  process.exit(1);
}

const abi = JSON.parse(readFileSync(artifact, "utf8")).abi;
const keep = abi.filter((e) => e.type === "function" && WANT.has(e.name)).sort((a, b) => a.name.localeCompare(b.name));
const missing = [...WANT].filter((n) => !keep.some((e) => e.name === n));
if (missing.length) {
  console.error(`the contract no longer exposes: ${missing.join(", ")}`);
  process.exit(1);
}

const next = `/**
 * The slice of AssayFlapVault the Flap vault UI calls.
 *
 * Generated from the compiled artifact rather than typed out. Regenerate with
 * \`node tools/sync-flap-ui-abi.mjs\` after changing the vault.
 */
export const vaultAbi = ${JSON.stringify(keep, null, 2)} as const;
`;

if (process.argv.includes("--check")) {
  const current = existsSync(target) ? readFileSync(target, "utf8") : "";
  if (current !== next) {
    console.error("flap-ui/VaultABI.ts is out of date with the compiled contracts.");
    process.exit(1);
  }
  console.log("flap ui abi in sync");
  process.exit(0);
}
writeFileSync(target, next);
console.log(`wrote ${target} (${keep.length} functions)`);
