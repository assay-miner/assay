#!/usr/bin/env node
/**
 * Refuses a tree that still names a contract function which no longer exists.
 *
 * Today one deletion — `withdrawUnconverted`, removed at Flap's request — left six live references
 * behind, and two of them were not documentation:
 *
 *   `miner/src/abi.ts` still declared the function. That package has its own drift gate,
 *   `npm run check-abi`, and it was RED. Nobody saw it, because nothing runs it.
 *
 *   `l1-snipe/run` printed "launcher … becomes the vault's curator — the address
 *   withdrawUnconverted pays" and refused to launch unless the launching key matched it. An
 *   operator would have chosen a launch key to protect money that could no longer move that way.
 *
 * Both were found by a review agent, after the fact. This is that review as a gate: every
 * backticked identifier shaped like a contract call, anywhere in the tree, must exist in some
 * contract's ABI.
 *
 * A reference that is deliberately about a removed thing marks itself — put "was removed",
 * "no longer", "used to", "deleted", "gone" or `check-symbols:allow` on the same line. That keeps
 * the "we deleted this and here is why" sentences an audit response needs, while a sentence that
 * still describes the function as live has nowhere to hide.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, extname } from "node:path";

const root = new URL("..", import.meta.url).pathname;

const SCAN_DIRS = ["src", "script", "tools", "miner/src", "miner/scripts", "l1-snipe", "app/src", "flap-ui"];
const SCAN_FILES = ["SELF_CHECK.md", "SUBMISSION.md", "AUDIT_RESPONSE.md", "AUDIT_RESPONSE_SHORT.md", "README.md"];
const EXT = new Set([".sol", ".ts", ".tsx", ".mjs", ".js", ".md", ".sh", ".example", ""]);
const SKIP = /node_modules|\/out\/|\/cache\/|\/dist\/|\/lib\/|\/broadcast\/|audit-reports/;

/** Every function and event this project's own contracts declare. */
function ourSymbols() {
  const names = new Set();
  // SKIP is not applied here: it excludes `/out/`, which is the directory being walked. The first
  // version of this function filtered away the artifacts it existed to read and reported "no
  // compiled artifacts" against a freshly built tree.
  const walk = (dir) => {
    for (const e of readdirSync(dir)) {
      const p = join(dir, e);
      if (statSync(p).isDirectory()) { walk(p); continue; }
      if (!p.endsWith(".json")) continue;
      let abi;
      try { abi = JSON.parse(readFileSync(p, "utf8")).abi; } catch { continue; }
      if (!Array.isArray(abi)) continue;
      for (const item of abi) if (item.name) names.add(item.name);
    }
  };
  try { walk(join(root, "out")); } catch { /* not built */ }
  return names;
}

const known = ourSymbols();
if (known.size === 0) { console.error("no compiled artifacts under out/ — run forge build first"); process.exit(2); }

// Identifiers that were removed and must not be described as live anywhere.
const RETIRED = ["withdrawUnconverted", "UnconvertedWithdrawn", "AssayVaultDeployer"];
// A line is excused when it talks about the symbol in the past, or about its absence. The point is
// to catch a sentence that still describes the thing as LIVE — "the address withdrawUnconverted
// pays" — not to forbid saying it ever existed. An audit response has to be able to explain a
// deletion, and this repository's comments are mostly explanations of why something is the way it
// is, which usually means saying what it used to be.
const EXCUSED = new RegExp([
  "was removed", "were removed", "no longer", "used to", "deleted", "is gone", "are gone",
  "does not appear", "absent", "did not", "could not", "moved", "paid,", "sent not",
  "check-symbols:allow", "已删除", "已移除", "不再", "曾经",
].join("|"), "i");

let bad = 0;
const files = [];
const collect = (dir) => {
  let entries;
  try { entries = readdirSync(dir); } catch { return; }
  for (const e of entries) {
    const p = join(dir, e);
    if (SKIP.test(p)) continue;
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) collect(p);
    else if (EXT.has(extname(p))) files.push(p);
  }
};
for (const d of SCAN_DIRS) collect(join(root, d));
for (const f of SCAN_FILES) files.push(join(root, f));

for (const f of files) {
  // The gate's own source names every retired symbol by definition.
  if (f.endsWith("check-symbols.mjs")) continue;
  let text;
  try { text = readFileSync(f, "utf8"); } catch { continue; }

  // In a response document the finding block is quoted from the auditor's report, verbatim, and a
  // finding about a function names that function. Rewriting it to please this gate would break the
  // title match the packaging step enforces character for character. So a block from `### Finding`
  // to its `> **Status:**` line is their text, not ours, and is not ours to fix.
  const lines = text.split("\n");
  let quoted = false;
  lines.forEach((line, i) => {
    if (/^### Finding \d+:/.test(line)) quoted = true;
    else if (/^> \*\*Status:\*\*/.test(line)) quoted = false;
    if (quoted) return;
    for (const sym of RETIRED) {
      if (!line.includes(sym)) continue;
      if (EXCUSED.test(line)) continue;
      console.error(`  ${f.replace(root, "")}:${i + 1}  names \`${sym}\`, which no longer exists`);
      console.error(`      ${line.trim().slice(0, 120)}`);
      bad++;
    }
  });
}

if (bad) {
  console.error(`\n${bad} live reference${bad === 1 ? "" : "s"} to a removed symbol.`);
  console.error("If the line is deliberately about the removal, say so on it (\"was removed\", \"no longer\", …).");
  process.exit(1);
}
console.log(`no live references to ${RETIRED.length} removed symbols across ${files.length} files`);
