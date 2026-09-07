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
  ["deployer", "Deployer / curator"],
];
const ZERO = "0x0000000000000000000000000000000000000000";

function table(chainId, title) {
  let m;
  try {
    m = JSON.parse(readFileSync(`deployments/${chainId}-latest.json`, "utf8"));
  } catch {
    return `## ${title}\n\nNot deployed.\n`;
  }
  const rows = LABELS.filter(([k]) => m[k]).map(([k, label]) => {
    const v = m[k];
    if (v === ZERO) {
      return k === "taxToken"
        ? `| ${label} | not launched — the factory is what Flap audits, and a launch claims an address permanently |`
        : `| ${label} | not deployed |`;
    }
    return `| ${label} | \`${v}\` |`;
  });
  return `## ${title}\n\n| | |\n|---|---|\n${rows.join("\n")}\n`;
}

const body = [
  table(56, "BNB Smart Chain mainnet (56)"),
  table(97, "BNB Smart Chain testnet (97) — the proof deployment"),
].join("\n");

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
