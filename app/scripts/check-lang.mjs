#!/usr/bin/env node
/**
 * Language-default gate.
 *
 * The case this exists for: a returning visitor. An earlier build persisted the language on
 * mount rather than on a click, so everyone who had ever loaded the site carried a stored value
 * that outranked the default — and changing the default did nothing for them. Testing with a
 * fresh browser profile is precisely the one situation that does not reproduce it, which is how
 * the bug shipped while a green check said otherwise.
 *
 * So this seeds the old key before loading, the way a real returning browser would.
 *
 * Local-only gate: needs $ASSAY_URL and a Playwright browser.
 */
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const URL = process.env.ASSAY_URL || "http://127.0.0.1:8794";
const b = await chromium.launch();
let bad = 0;
const check = (name, got, want) => {
  const ok = got === want;
  if (!ok) bad++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}  -> ${JSON.stringify(got)}`);
};

const open = async (seed, path = "/") => {
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const p = await ctx.newPage();
  if (seed !== null) await p.addInitScript((s) => localStorage.setItem(s.k, s.v), seed);
  await p.goto(URL + path, { waitUntil: "networkidle" });
  return p;
};

// 1. The owner's exact case: an old value left behind by the previous build.
check("returning visitor (old key = zh)",
  await (await open({ k: "assay.lang", v: "zh" })).getAttribute("html", "lang"), "en");

// 2. Same, but on a deep link.
check("returning visitor, deep link /docs",
  await (await open({ k: "assay.lang", v: "zh" }, "/docs")).getAttribute("html", "lang"), "en");

// 3. Brand new visitor.
const fresh = await open(null);
check("fresh visitor", await fresh.getAttribute("html", "lang"), "en");
check("fresh visitor writes nothing",
  await fresh.evaluate(() => localStorage.getItem("assay.lang.v2")), null);

// 4. A real click must still stick, across a reload.
await fresh.click(".lang-toggle");
await fresh.waitForTimeout(400);
check("after clicking the toggle", await fresh.getAttribute("html", "lang"), "zh");
check("the click is written down",
  await fresh.evaluate(() => localStorage.getItem("assay.lang.v2")), "zh");
await fresh.reload({ waitUntil: "networkidle" });
check("chosen language survives reload", await fresh.getAttribute("html", "lang"), "zh");

// 5. And switching back returns to English and sticks.
await fresh.click(".lang-toggle");
await fresh.waitForTimeout(400);
await fresh.reload({ waitUntil: "networkidle" });
check("switched back, survives reload", await fresh.getAttribute("html", "lang"), "en");

await b.close();
console.log(bad ? `\nlanguage gate: ${bad} failing case(s)` : "\nlanguage gate: clean");
process.exit(bad ? 1 : 0);
