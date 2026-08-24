#!/usr/bin/env node
/**
 * Generates `public/hero.svg` — the 2000x1080 plate the home page is built on.
 *
 * The whole desktop layout is pinned to this plate's coordinate system: the SVG is drawn at
 * `object-fit: cover` across the viewport, and CSS positions every HTML overlay with
 * `--u = max(.05vw, .0925926vh)`, which is exactly one SVG unit on screen. So a mark at SVG
 * (1873, 143) is placed with `top: calc(50vh + (143 - 540) * var(--u))`.
 *
 * The "code rain" is not decoration for its own sake: it is the actual subject matter of the
 * protocol rendered as texture — Yul and Solidity for the assay path, laid out one character
 * at a time so the animation can retype individual glyphs later.
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, "..", "src", "generated", "hero.svg");

import { SOURCE } from "../src/plateSource.js";

let cursor = 0;
const nextChar = () => SOURCE[cursor++ % SOURCE.length];

/** Deterministic PRNG — the plate must be byte-identical on every regeneration. */
let seed = 0x9e3779b9;
function rand() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return ((seed >>> 0) % 100000) / 100000;
}

const TIERS = ["#7C7A6E", "#9E9C8C", "#C2BFAE", "#E8E5D6"];

/**
 * Lays a run of characters along a horizontal line, dropping some so the line reads as a
 * decayed printout rather than a solid block. Returns one bucket of glyphs per brightness tier.
 */
function rainRow(y, x0, x1, step, density, tiers, buckets) {
  for (let x = x0; x <= x1; x += step) {
    if (rand() > density) continue;
    const tier = Math.min(tiers - 1, Math.floor(rand() * tiers));
    buckets[tier].push({ x: Math.round(x), y, c: nextChar() });
  }
}

function emit(buckets, fontSize, cls, transform) {
  const groups = buckets
    .map((glyphs, i) => {
      if (!glyphs.length) return "";
      // Group by row so each <text> holds a whole line with per-character x offsets, exactly
      // as the reference plate does — this is what lets the retype animation address a line.
      const byRow = new Map();
      for (const g of glyphs) {
        if (!byRow.has(g.y)) byRow.set(g.y, []);
        byRow.get(g.y).push(g);
      }
      const texts = [...byRow.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([y, gs]) => {
          gs.sort((a, b) => a.x - b.x);
          const xs = gs.map((g) => g.x).join(" ");
          const chars = gs
            .map((g) => g.c)
            .join("")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
          return `<text y="${y}" x="${xs}">${chars}</text>`;
        })
        .join("");
      return `<g fill="${TIERS[i]}">${texts}</g>`;
    })
    .join("");
  const t = transform ? ` transform="${transform}"` : "";
  return `<g class="${cls}" font-family="IBM Plex Mono, monospace" font-size="${fontSize}" text-anchor="middle"${t}>${groups}</g>`;
}

// --- the border bands ----------------------------------------------------------------------
const border = [[], [], [], []];
for (let y = 18; y <= 128; y += 10) rainRow(y, 25, 1975, 10, 0.62, 4, border);
for (let y = 962; y <= 1072; y += 10) rainRow(y, 25, 1975, 10, 0.62, 4, border);
// thin vertical rails down the left and right edges
for (let y = 138; y <= 952; y += 10) {
  rainRow(y, 25, 95, 10, 0.5, 4, border);
  rainRow(y, 1905, 1975, 10, 0.5, 4, border);
}

// --- the oval ------------------------------------------------------------------------------
// A ring of rain around the medallion. Drawn as a circle and squashed vertically by the group
// transform, matching the reference plate's `scale(1 0.82)` about y=640.
const oval = [[], [], []];
for (let ring = 0; ring < 7; ring++) {
  const r = 300 + ring * 9;
  const steps = Math.round(2 * Math.PI * r / 9);
  for (let i = 0; i < steps; i++) {
    if (rand() > 0.55) continue;
    const a = (i / steps) * Math.PI * 2;
    const tier = Math.min(2, Math.floor(rand() * 3));
    oval[tier].push({
      x: Math.round(1000 + Math.cos(a) * r),
      y: Math.round(640 + Math.sin(a) * r),
      c: nextChar(),
    });
  }
}

// --- a chip coin ---------------------------------------------------------------------------
/** The etched silicon die that stands in for the thing being assayed. */
const chip = (id, x, y, size) => `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="0 0 100 100" class="chipcoin">
<defs><pattern id="${id}" patternUnits="userSpaceOnUse" width="56" height="56"><image href="/assets/gold-etch.webp" width="56" height="56" preserveAspectRatio="xMidYMid slice"/></pattern></defs>
<rect x="35" y="35" width="30" height="30" rx="2.5" fill="url(#${id})" stroke="rgba(234,198,82,.85)" stroke-width="1"/>
<g fill="none" stroke="rgba(234,198,82,.72)" stroke-width="1">
<rect x="43" y="43" width="14" height="14" rx="1"/>
<path d="M41,35 L41,29 M50,35 L50,29 M59,35 L59,29"/>
<path d="M41,65 L41,71 M50,65 L50,71 M59,65 L59,71"/>
<path d="M35,41 L29,41 M35,50 L29,50 M35,59 L29,59"/>
<path d="M65,41 L71,41 M65,50 L71,50 M65,59 L71,59"/>
</g></svg>`;

const svg = `<svg viewBox="0 0 2000 1080" preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="ASSAY">
<rect width="2000" height="1080" fill="#000000"/>
<image href="/assets/paper.webp" x="0" y="0" width="2000" height="1080" preserveAspectRatio="xMidYMid slice"/>
${emit(border, 9.8, "border")}
${emit(oval, 7.8, "oval", "translate(0 -75) translate(0 640) scale(1 0.82) translate(0 -640)")}
${chip("coinEtchA", 290, 475, 190)}
${chip("coinEtchB", 1520, 475, 190)}
</svg>
`;

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, svg);
const rows = border.flat().length + oval.flat().length;
console.log(`wrote ${out} — ${rows} glyphs, ${(svg.length / 1024).toFixed(1)}KB`);
