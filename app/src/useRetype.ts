import { useEffect } from "react";
import { SOURCE } from "./plateSource";

/**
 * Re-types individual lines of the plate's code rain.
 *
 * Every 800ms one line that is not already animating is picked (at most three at a time). It
 * turns gold, then its glyphs are replaced one at a time from the protocol source, with a short
 * run of garbage characters riding the leading edge, before settling and fading back to ink.
 *
 * The plate is an <img>, so the animation runs against an inlined copy of the SVG instead —
 * `svgRoot` is that element, mounted by the Hero.
 */
const GARBAGE = "0123456789*+-/=<>[]{}()#$%&";
const GOLD = "#EAC652";

export function useRetype(svgRoot: SVGSVGElement | null) {
  useEffect(() => {
    if (!svgRoot) return;
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const lines = [...svgRoot.querySelectorAll<SVGTextElement>("g.border text, g.oval text")].filter(
      (n) => (n.textContent ?? "").length >= 10,
    );
    if (!lines.length) return;

    const busy = new Set<SVGTextElement>();
    let cursor = 0;
    let timer: number | null = null;

    const retype = (node: SVGTextElement) => {
      busy.add(node);
      const final = node.textContent ?? "";
      const n = final.length;
      const duration = 700 + n * 6;
      const target = Array.from({ length: n }, () => SOURCE[cursor++ % SOURCE.length]);

      node.style.transition = "fill 350ms ease";
      node.style.fill = GOLD;

      const started = performance.now();
      const LEAD = 7;
      const step = (now: number) => {
        const settled = Math.min(n, Math.floor(((now - started) / duration) * n));
        let out = target.slice(0, settled).join("");
        for (let i = settled; i < Math.min(n, settled + LEAD); i++) {
          out += GARBAGE[(Math.random() * GARBAGE.length) | 0];
        }
        out += final.slice(out.length);
        node.textContent = out;

        if (settled < n) {
          requestAnimationFrame(step);
        } else {
          node.textContent = target.join("");
          node.style.fill = "";
          setTimeout(() => {
            node.style.transition = "";
            busy.delete(node);
          }, 400);
        }
      };
      requestAnimationFrame(step);
    };

    const start = () => {
      if (timer !== null || document.hidden) return;
      timer = window.setInterval(() => {
        if (busy.size >= 3) return;
        const idle = lines.filter((l) => !busy.has(l));
        if (idle.length) retype(idle[(Math.random() * idle.length) | 0]);
      }, 800);
    };
    const stop = () => {
      if (timer !== null) clearInterval(timer);
      timer = null;
    };

    const onVisibility = () => (document.hidden ? stop() : start());
    document.addEventListener("visibilitychange", onVisibility);
    start();

    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      stop();
    };
  }, [svgRoot]);
}
