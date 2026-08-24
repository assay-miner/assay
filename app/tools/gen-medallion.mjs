#!/usr/bin/env node
/**
 * Generates `public/medallion.svg` — the ASSAY hallmark.
 *
 * An assay office tests metal and stamps a mark into it. The mark here is that act: a crucible
 * seen in section, cut in the same fine-line engraving register as a struck coin — dotted rim,
 * hairline field, hatched volumes. It is drawn rather than photographed so it stays crisp at
 * the 230px the plate calls for and at the 148px the mobile layout calls for.
 */
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, "..", "src", "generated", "medallion.svg");

const GOLD = "#C9A227";
const GOLD_LIGHT = "#EAC652";
const GOLD_DEEP = "#8A6E22";

const C = 400; // centre
const R = 386; // outer rim radius

let seed = 0x2545f491;
function rand() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return ((seed >>> 0) % 100000) / 100000;
}

const p = (n) => Math.round(n * 100) / 100;

/** The bead rim: small dots marching round the coin edge, as on a struck medal. */
function beadRim(radius, count, r = 2.1) {
  let d = "";
  for (let i = 0; i < count; i++) {
    const a = (i / count) * Math.PI * 2;
    d += `<circle cx="${p(C + Math.cos(a) * radius)}" cy="${p(C + Math.sin(a) * radius)}" r="${r}"/>`;
  }
  return `<g fill="${GOLD}">${d}</g>`;
}

/**
 * Engraved shading: parallel hairlines clipped to a shape, their length modulated so the form
 * reads as volume. This is what gives a line engraving its tone.
 */
function hatch(clipId, x0, y0, x1, y1, gap, angle, jitter = 0.5) {
  const lines = [];
  const dx = Math.cos(angle);
  const dy = Math.sin(angle);
  const len = Math.hypot(x1 - x0, y1 - y0) * 1.4;
  const steps = Math.ceil(len / gap);
  for (let i = -steps; i < steps * 2; i++) {
    const ox = x0 + -dy * i * gap;
    const oy = y0 + dx * i * gap;
    const j = (rand() - 0.5) * jitter;
    lines.push(
      `M${p(ox - dx * len + j)},${p(oy - dy * len)} L${p(ox + dx * len + j)},${p(oy + dy * len)}`,
    );
  }
  return `<g clip-path="url(#${clipId})" stroke="${GOLD}" stroke-width="1.05" fill="none" opacity=".92"><path d="${lines.join(" ")}"/></g>`;
}

// Crucible section: a tapered vessel with a lip, plus the pour.
const CRUCIBLE =
  "M242,250 L558,250 L556,286 L520,286 L470,566 " +
  "Q400,626 330,566 L280,286 L244,286 Z";
const MELT = "M300,352 L500,352 L462,566 Q400,616 338,566 Z";

const svg = `<svg viewBox="0 0 800 800" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="ASSAY hallmark">
<defs>
  <pattern id="hmEtch" patternUnits="userSpaceOnUse" width="56" height="56">
    <image href="/assets/gold-etch.webp" width="56" height="56" preserveAspectRatio="xMidYMid slice"/>
  </pattern>
  <clipPath id="hmCrucible"><path d="${CRUCIBLE}"/></clipPath>
  <clipPath id="hmMelt"><path d="${MELT}"/></clipPath>
  <radialGradient id="hmGlow" cx="50%" cy="62%" r="42%">
    <stop offset="0%" stop-color="${GOLD_LIGHT}" stop-opacity=".55"/>
    <stop offset="100%" stop-color="${GOLD_LIGHT}" stop-opacity="0"/>
  </radialGradient>
</defs>

<!-- rim: outer hairline, bead ring, inner hairline -->
<circle cx="${C}" cy="${C}" r="${R}" fill="none" stroke="${GOLD}" stroke-width="3"/>
${beadRim(R - 13, 180)}
<circle cx="${C}" cy="${C}" r="${R - 27}" fill="none" stroke="${GOLD}" stroke-width="1.4"/>

<!-- the melt glows through the vessel -->
<ellipse cx="${C}" cy="500" rx="150" ry="120" fill="url(#hmGlow)"/>

<!-- vessel body, etched -->
<path d="${CRUCIBLE}" fill="url(#hmEtch)" opacity=".34"/>
${hatch("hmCrucible", 240, 250, 560, 630, 7, Math.PI / 2.35)}
${hatch("hmCrucible", 240, 250, 560, 630, 15, -Math.PI / 2.9, 1.2)}
<path d="${CRUCIBLE}" fill="none" stroke="${GOLD_LIGHT}" stroke-width="3.4"/>

<!-- molten charge -->
<path d="${MELT}" fill="${GOLD_LIGHT}" opacity=".2"/>
${hatch("hmMelt", 300, 352, 500, 616, 5.5, Math.PI / 2)}
<path d="M300,352 L500,352" stroke="${GOLD_LIGHT}" stroke-width="3.4" fill="none"/>

<!-- three tapped drops below the lip: the assayed result -->
<g fill="${GOLD_LIGHT}">
  <ellipse cx="352" cy="654" rx="9" ry="12"/>
  <ellipse cx="400" cy="676" rx="11" ry="15"/>
  <ellipse cx="448" cy="654" rx="9" ry="12"/>
</g>

<!-- heat rising from the lip -->
<g stroke="${GOLD_DEEP}" stroke-width="2.4" fill="none" opacity=".8" stroke-linecap="round">
  <path d="M330,232 q14,-30 0,-58 q-14,-28 0,-52"/>
  <path d="M400,220 q14,-32 0,-62 q-14,-30 0,-56"/>
  <path d="M470,232 q14,-30 0,-58 q-14,-28 0,-52"/>
</g>
</svg>
`;

writeFileSync(out, svg);
console.log(`wrote ${out} — ${(svg.length / 1024).toFixed(1)}KB`);
