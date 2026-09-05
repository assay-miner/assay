#!/usr/bin/env node
/**
 * Refuses a response the audit validator would reject on shape.
 *
 * Three rounds, three rejections, three times the cause was inferring the format instead of copying
 * it. The last one: the report's title is
 *   "Permissionless generateAndPost has no inter-epoch spacing, letting anyone relocate the
 *    reward-pool funding target and stall the reward flow"
 * and I wrote it up to the first comma. The validator matches titles whole and reported
 * "Confirmed: 0". The same submission also carried TWO Status lines under one finding, because that
 * finding genuinely had two dispositions — the format has one per finding, so the extra line left
 * the finding unconfirmed.
 *
 * Usage: check-response-format.mjs <response.md> <report.md>
 *
 * With a report to compare against, titles are matched character for character. Without one, only
 * the structural rules are checked — which is worth saying, because a green run in that mode does
 * NOT mean the titles are right.
 */
import { readFileSync, existsSync } from "node:fs";

const [, , responsePath, reportPath] = process.argv;
if (!responsePath) { console.error("usage: check-response-format.mjs <response.md> [report.md]"); process.exit(2); }

const res = readFileSync(responsePath, "utf8");
const titlesOf = (s) => [...s.matchAll(/^### Finding \d+: (.+)$/gm)].map((m) => m[1].trim());

const titles = titlesOf(res);
const statuses = [...res.matchAll(/^> \*\*Status:\*\*.*$/gm)].map((m) => m[0]);
const reasons = [...res.matchAll(/^> \*\*Reason\b.*$/gm)].map((m) => m[0]);

let bad = 0;
const fail = (m) => { console.error(`  ${m}`); bad++; };

if (titles.length === 0) fail("no `### Finding N:` headings found");

if (statuses.length !== titles.length) {
  fail(`${statuses.length} Status lines against ${titles.length} findings — the validator pairs them one to one`);
}
if (reasons.length !== titles.length) {
  fail(`${reasons.length} Reason lines against ${titles.length} findings`);
}

statuses.forEach((line, i) => {
  const ticked = (line.match(/`\[x\]`/g) ?? []).length;
  const boxes = (line.match(/`\[[ x]\]`/g) ?? []).length;
  if (ticked !== 1) fail(`Status ${i + 1} has ${ticked} boxes ticked; exactly one is required`);
  if (boxes !== 4) fail(`Status ${i + 1} has ${boxes} boxes; the four are TP / FP / By Design / Acknowledged`);
});

const FIELDS = ["- **Severity:**", "- **Confidence:**", "- **Detected by:**", "- **Description:**", "- **Vulnerable Code:**"];
for (const f of FIELDS) {
  const n = (res.split(f).length - 1);
  if (n !== titles.length) fail(`"${f}" appears ${n} times against ${titles.length} findings`);
}

if (reportPath && existsSync(reportPath)) {
  const want = titlesOf(readFileSync(reportPath, "utf8"));
  if (want.length !== titles.length) {
    fail(`report has ${want.length} findings, response has ${titles.length}`);
  }
  want.forEach((w, i) => {
    if (titles[i] !== w) {
      fail(`Finding ${i + 1} title differs from the report:\n      report:   ${w}\n      response: ${titles[i] ?? "(missing)"}`);
    }
  });
} else {
  console.log("  note: no report given, so TITLES WERE NOT COMPARED — structure only");
}

if (bad) { console.error(`\n${bad} problem${bad > 1 ? "s" : ""} the validator would reject`); process.exit(1); }
console.log("response matches the report's shape: titles, one status per finding, one box each");
