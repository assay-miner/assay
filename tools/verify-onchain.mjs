#!/usr/bin/env node
/**
 * Proves the address on chain holds the bytecode in this package.
 *
 * The immutable slots are blanked before the comparison. A factory's immutables — here the
 * tournament address — are written into the runtime at deploy time, so the artifact carries
 * placeholder zeros there and a raw comparison always differs at exactly those offsets and
 * nowhere else. Reporting that as a mismatch would be wrong; not checking the rest would be
 * worse. This does both: it prints what each immutable actually holds, then requires everything
 * else to match byte for byte.
 */
import { readFileSync } from "node:fs";

const RPC = process.argv[2] || "https://bsc-dataseed.bnbchain.org";
const manifest = JSON.parse(readFileSync(new URL("./deployments/56-latest.json", import.meta.url)));
const address = manifest.flapFactory;

const artifactPath = new URL("./artifact/AssayFlapFactory.json", import.meta.url);
let artifact;
try {
  artifact = JSON.parse(readFileSync(artifactPath));
} catch {
  console.error("no artifact/AssayFlapFactory.json — run `forge build` and copy out/ in, or");
  console.error("recompile standard-json/AssayFlapFactory.json with solc and compare by hand.");
  process.exit(1);
}

const res = await fetch(RPC, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
});
const { result, error } = await res.json();
if (error) { console.error("rpc:", error.message); process.exit(1); }

const onchain = result.slice(2);
const local = artifact.deployedBytecode.object.slice(2);
const refs = artifact.deployedBytecode.immutableReferences ?? {};

console.log(`address   ${address}`);
console.log(`on chain  ${onchain.length / 2} bytes`);
console.log(`artifact  ${local.length / 2} bytes`);

const blanked = onchain.split("");
for (const slots of Object.values(refs)) {
  for (const { start, length } of slots) {
    const s = start * 2, l = length * 2;
    console.log(`immutable @${start} (${length}B) = 0x${onchain.slice(s, s + l).slice(-40)}`);
    blanked.splice(s, l, ...Array(l).fill("0"));
  }
}

if (blanked.join("") === local) {
  console.log("\nmatch — identical outside the immutable slots");
} else {
  console.error("\nMISMATCH — the deployed code is not this source");
  process.exit(1);
}
