#!/usr/bin/env node
// Rewrites SUBMISSION.md's deployment tables from deployments/*-latest.json.
//
// They used to be typed in. A redeploy then moved the contracts and left the document naming the
// previous ones — which is how an archive ends up asking an auditor to look at addresses that do
// not hold the code under review. Derived, it cannot drift; the check mode fails the packaging
// script rather than shipping a stale table.
import { readFileSync, writeFileSync } from "node:fs";

const START = "<!-- deployments:start -->";
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

const doc = readFileSync("SUBMISSION.md", "utf8");
const i = doc.indexOf(START);
const j = doc.indexOf(END);
if (i < 0 || j < 0) {
  console.error(`SUBMISSION.md is missing the ${START} / ${END} markers`);
  process.exit(1);
}
const next = `${doc.slice(0, i + START.length)}\n\n${body}\n${doc.slice(j)}`;

if (check) {
  if (next !== doc) {
    console.error("SUBMISSION.md's deployment tables are stale — run tools/sync-submission.mjs");
    process.exit(1);
  }
  console.log("SUBMISSION.md matches the manifests");
} else {
  writeFileSync("SUBMISSION.md", next);
  console.log("SUBMISSION.md deployment tables rewritten from the manifests");
}
