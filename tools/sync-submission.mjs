#!/usr/bin/env node
// Rewrites SUBMISSION.md's deployment tables from deployments/*-latest.json.
//
// They used to be typed in. A redeploy then moved the contracts and left the document naming the
// previous ones — which is how an archive ends up asking an auditor to look at addresses that do
// not hold the code under review. Derived, it cannot drift; the check mode fails the packaging
// script rather than shipping a stale table.
import { readFileSync, writeFileSync } from "node:fs";

const START = "<!-- deployments:start -->";
const M_START = "<!-- measured:start -->";
const M_END = "<!-- measured:end -->";
const END = "<!-- deployments:end -->";
const check = process.argv.includes("--check");

const LABELS = [
  ["flapFactory", "Factory (the contract Flap audits)"],
  ["flapVault", "Flap vault"],
  ["taxToken", "Tax token"],
  ["tournament", "Tournament"],
  ["vault", "Custody ledger"],
  ["roster", "Roster"],
  ["deployer", "Deployer"],
  ["curator", "Curator (posts the tournament's curated lane; paid nothing; same key as the deployer)"],
];
const ZERO = "0x0000000000000000000000000000000000000000";

const RPCS = {
  56: "https://bsc-dataseed.binance.org",
  97: "https://bsc-testnet-rpc.publicnode.com",
};

/**
 * Whether an address has code, asked of the chain rather than assumed from the manifest.
 *
 * This exists because both halves of that gap shipped. SUBMISSION.md called chain 97 "the proof
 * deployment" and listed four addresses, every one of which returns 0x — a testnet deploy failed and
 * forge wrote the manifest anyway. Then a mainnet deploy ran out of gas mid-broadcast and wrote a
 * manifest recording six addresses of which two had code. A manifest records what a script INTENDED
 * to deploy; only the chain records what it did.
 *
 * Returns null when the chain cannot be reached, and a null is never reported as "no code" — an
 * unreachable endpoint is not evidence of an empty address.
 */
async function hasCode(chainId, address) {
  const rpc = RPCS[chainId];
  if (!rpc) return null;
  try {
    const res = await fetch(rpc, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
      signal: AbortSignal.timeout(8000),
    });
    const j = await res.json();
    if (typeof j?.result !== "string") return null;
    return j.result.length > 2;
  } catch {
    return null;
  }
}

async function table(chainId, name) {
  let m;
  try {
    m = JSON.parse(readFileSync(`deployments/${chainId}-latest.json`, "utf8"));
  } catch {
    return `## ${name}\n\nNot deployed.\n`;
  }

  const entries = LABELS.filter(([k]) => m[k]);
  const codes = await Promise.all(
    entries.map(([k]) => (m[k] === ZERO || k === "deployer" || k === "curator" || k === "salvage"
      ? Promise.resolve(null)
      : hasCode(chainId, m[k]))),
  );

  let live = 0;
  let unknown = 0;
  const rows = entries.map(([k, label], i) => {
    const v = m[k];
    if (v === ZERO) {
      return k === "taxToken"
        ? `| ${label} | not launched — the factory is what Flap audits, and a launch claims an address permanently |`
        : `| ${label} | not deployed |`;
    }
    const code = codes[i];
    if (code === true) live++;
    if (code === null && k !== "deployer" && k !== "curator" && k !== "salvage") unknown++;
    const note = code === false ? " — **no code at this address**" : "";
    return `| ${label} | \`${v}\`${note} |`;
  });

  const anyContract = codes.some((c) => c !== null);
  const title = anyContract && live === 0
    ? `${name} — NOT deployed: every address below is empty on chain`
    : name;
  const caveat = unknown > 0
    ? `\n_Code presence could not be checked for ${unknown} address(es); the endpoint did not answer._\n`
    : "";
  return `## ${title}\n\n| | |\n|---|---|\n${rows.join("\n")}\n${caveat}`;
}

const body = (await Promise.all([
  table(56, "BNB Smart Chain mainnet (56)"),
  table(97, "BNB Smart Chain testnet (97)"),
])).join("\n");

/**
 * The facts SUBMISSION.md states under "Measured, not estimated" — derived here rather than typed.
 *
 * They were typed, and every one of them was wrong: the vault's runtime was quoted at 16,464 bytes
 * against a real 22,062, the factory at 19,526 against a real 2,637 (the AssayVaultDeployer split
 * moved the vault's creation code out of it and the figure never followed), and the schema was said
 * to declare 8 methods against a real 12. A heading that asserts the numbers were measured is the
 * worst place to keep numbers nothing measures.
 */
function measured() {
  const runtime = (name) => {
    const art = JSON.parse(readFileSync(`out/${name}.sol/${name}.json`, "utf8"));
    const hex = art.deployedBytecode.object.replace(/^0x/, "");
    return (hex.length / 2).toLocaleString("en-US");
  };
  const vaultSrc = readFileSync("src/AssayFlapVault.sol", "utf8");
  const methods = (vaultSrc.match(/m\.name = "/g) ?? []).length;

  return [
    "| | |",
    "|---|---|",
    "| `receive()` gas | measured by `test_ReceiveStaysUnderTheGasCeiling`, which asserts the Rule 005 ceiling rather than restating a figure |",
    `| \`AssayFlapVault\` runtime | ${runtime("AssayFlapVault")} bytes |`,
    `| \`AssayFlapFactory\` runtime | ${runtime("AssayFlapFactory")} bytes |`,
    `| \`vaultUISchema()\` methods | ${methods} |`,
  ].join("\n");
}

const doc = readFileSync("SUBMISSION.md", "utf8");
const i = doc.indexOf(START);
const j = doc.indexOf(END);
if (i < 0 || j < 0) {
  console.error(`SUBMISSION.md is missing the ${START} / ${END} markers`);
  process.exit(1);
}
let next = `${doc.slice(0, i + START.length)}\n\n${body}\n${doc.slice(j)}`;

const mi = next.indexOf(M_START);
const mj = next.indexOf(M_END);
if (mi < 0 || mj < 0) {
  console.error(`SUBMISSION.md is missing the ${M_START} / ${M_END} markers`);
  process.exit(1);
}
next = `${next.slice(0, mi + M_START.length)}\n\n${measured()}\n${next.slice(mj)}`;

if (check) {
  if (next !== doc) {
    console.error("SUBMISSION.md is stale (deployments or measured facts) — run tools/sync-submission.mjs");
    process.exit(1);
  }
  console.log("SUBMISSION.md matches the manifests");
} else {
  writeFileSync("SUBMISSION.md", next);
  console.log("SUBMISSION.md deployment tables rewritten from the manifests");
}
