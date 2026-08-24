#!/usr/bin/env node
/**
 * Translation-coverage gate.
 *
 * Written in reverse on purpose. Scanners that look *for* untranslated strings keep passing a
 * site that is visibly half-translated, because every pass only knows the patterns someone
 * already thought of. So this one deletes everything that is unambiguously code — imports,
 * className/style/href attributes, `t("…")` lookups, technical identifiers — and then treats
 * whatever human-readable text is left over as a violation by default.
 *
 * Two rules:
 *   1. No CJK anywhere outside the dictionary. All Chinese copy comes from i18n.tsx.
 *   2. No bare prose in a JSX text position. It has to arrive through t().
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = resolve(here, "..", "src");
const DICTIONARY = resolve(srcDir, "i18n.tsx");

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (/\.tsx?$/.test(p)) out.push(p);
  }
  return out;
}

/** Strips the parts of a source file that can never be user-visible prose. */
function stripCode(src) {
  return (
    src
      // dictionary lookups — the sanctioned path
      .replace(/\bt\(\s*"[^"]*"\s*\)/g, "")
      // imports and exports of modules
      .replace(/^\s*import[\s\S]*?from\s*"[^"]*";?$/gm, "")
      // comments
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/[^\n]*/g, "")
      // attributes that are never prose
      .replace(/\b(className|style|href|to|rel|target|key|id|aria-hidden|focusable|viewBox|fill|stroke|strokeWidth|strokeLinejoin|strokeLinecap|d|width|height|type|value|name|path)\s*=\s*("[^"]*"|\{[^}]*\})/g, "")
      // template/expression braces holding identifiers
      .replace(/\{`[^`]*`\}/g, "")
      // TypeScript generics. `() => Promise<T>` reads to the JSX-text pattern below as
      // ">" then "Promise" then "<" — indistinguishable from a JSX text node. An identifier
      // immediately followed by angle brackets is a type argument, never JSX (a JSX element
      // opens with the bracket), so strip those. Stripping code keeps the rule's teeth;
      // allow-listing the word "Promise" would have blinded it everywhere that word appears.
      .replace(/\b([A-Za-z_$][\w$.]*)\s*<[^<>;{}]*>/g, "$1")
  );
}

const CJK = /[㐀-䶿一-鿿豈-﫿　-〿＀-￯]/;

/** JSX text nodes: `>some words<` with at least two letters and no interpolation. */
const JSX_TEXT = />\s*([A-Za-z][A-Za-z ,.'’&:%-]{6,})\s*</g;

/** Prose-looking bare text that is nonetheless legitimate: brand and technical tokens. */
const ALLOWED = new Set(["Assay", "ASSAY"]);

const violations = [];

for (const file of walk(srcDir)) {
  if (resolve(file) === DICTIONARY) continue;
  const rel = relative(resolve(here, ".."), file);
  const raw = readFileSync(file, "utf8");
  const stripped = stripCode(raw);

  stripped.split("\n").forEach((line, i) => {
    if (CJK.test(line)) {
      violations.push(`${rel}:${i + 1}  CJK outside the dictionary → ${line.trim().slice(0, 90)}`);
    }
  });

  let m;
  while ((m = JSX_TEXT.exec(stripped)) !== null) {
    const text = m[1].trim();
    if (ALLOWED.has(text)) continue;
    const line = stripped.slice(0, m.index).split("\n").length;
    violations.push(`${rel}:${line}  bare prose in JSX → "${text.slice(0, 70)}"`);
  }
}

if (violations.length > 0) {
  console.error(`translation gate: ${violations.length} violation(s)\n`);
  for (const v of violations) console.error("  " + v);
  console.error("\nEvery user-visible string must come from t() in src/i18n.tsx.");
  process.exit(1);
}

console.log("translation gate: clean — no CJK and no bare prose outside the dictionary");
