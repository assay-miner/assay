#!/usr/bin/env node
/**
 * Layout collision gate for the home plate.
 *
 * The plate pins overlays to a 2000x1080 coordinate system, so a copy change, a font swap or a
 * language switch can silently push two blocks through each other — and a screenshot at one
 * size will not show it. This walks several viewport sizes in both languages and fails on any
 * overlap between leaf elements, or on anything leaving the window.
 *
 * Leaves, not containers: comparing a wrapper's box hides every collision between its own
 * children, which is exactly where they happen. That mistake was in the first version of this
 * file and it reported a clean run on a layout that was visibly broken.
 *
 * Local-only gate — it needs a built `dist/` served at $ASSAY_URL and a Playwright browser,
 * which is not a dependency of this app because its browser download is heavy.
 */
const PW = process.env.PLAYWRIGHT_MODULE || "playwright";
const { chromium } = await import(PW);

const URL = process.env.ASSAY_URL || "http://127.0.0.1:8794/";

/** Every element that is positioned against the plate and must stay clear of the others. */
const LEAVES = [
  ".hero-mark",
  ".hero-word",
  ".hero-tagline",
  ".bond-nav a",
  ".hero-actions .demo-cta",
  ".hero-actions .lang-toggle",
  ".endorsements",
  ".seals .seal",
  ".hero-foot",
];

const SIZES = [
  [1280, 800],
  [1440, 900],
  [1600, 1000],
  [1920, 1080],
  [2560, 1440],
];

const browser = await chromium.launch();
let failed = 0;

for (const lang of ["zh", "en"]) {
  for (const [width, height] of SIZES) {
    const page = await browser.newPage({ viewport: { width, height } });
    // The key is versioned. Seeding the old one silently ran both passes in English, so
    // every "zh" line below was a duplicate of the "en" line above it and the Han layout
    // — the one that actually breaks, since the tagline is set larger — went unmeasured.
    await page.addInitScript((l) => localStorage.setItem("assay.lang.v2", l), lang);
    await page.goto(URL, { waitUntil: "networkidle" });

    const bad = await page.evaluate((sel) => {
      const boxes = sel
        .flatMap((s) => [...document.querySelectorAll(s)].map((e) => ({ s, r: e.getBoundingClientRect() })))
        .filter((o) => o.r.width > 0 && o.r.height > 0);

      const hits = [];
      for (let i = 0; i < boxes.length; i++) {
        for (let j = i + 1; j < boxes.length; j++) {
          const a = boxes[i];
          const c = boxes[j];
          if (a.s === c.s) continue;
          const overlaps = !(
            a.r.right <= c.r.left ||
            c.r.right <= a.r.left ||
            a.r.bottom <= c.r.top ||
            c.r.bottom <= a.r.top
          );
          if (overlaps) hits.push(`${a.s} x ${c.s}`);
        }
      }

      const off = boxes
        .filter(
          (o) =>
            o.r.left < -2 ||
            o.r.top < -2 ||
            o.r.right > window.innerWidth + 2 ||
            o.r.bottom > window.innerHeight + 2,
        )
        .map((o) => o.s);

      return { hits: [...new Set(hits)], off: [...new Set(off)] };
    }, LEAVES);

    // An SVG id is document-global. Inlining the same artwork twice silently points the
    // second copy's clip-paths at the first copy's — which is how a clipped crucible became
    // a solid gold square on phones while every desktop check stayed green.
    const dupes = await page.evaluate(() => {
      const seen = new Map();
      for (const el of document.querySelectorAll("svg [id], svg[id]")) {
        seen.set(el.id, (seen.get(el.id) ?? 0) + 1);
      }
      return [...seen].filter(([, n]) => n > 1).map(([id]) => id);
    });

    const tag = `${lang} ${width}x${height}`;
    if (dupes.length) {
      failed++;
      console.log(`  FAIL ${tag}  duplicate svg ids=${JSON.stringify(dupes)}`);
      await page.close();
      continue;
    }
    if (bad.hits.length || bad.off.length) {
      failed++;
      console.log(
        `  FAIL ${tag}  overlap=${JSON.stringify(bad.hits)} offscreen=${JSON.stringify(bad.off)}`,
      );
    } else {
      console.log(`  ok   ${tag}`);
    }
    await page.close();
  }
}

await browser.close();

if (failed) {
  console.error(`\nlayout gate: ${failed} failing combination(s)`);
  process.exit(1);
}
console.log("layout gate: clean");
