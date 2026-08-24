import { useEffect, useRef, useState } from "react";
import type { FieldDescriptor } from "../schema";

/**
 * The live parts of a schema-driven page.
 *
 * None of this knows a single ASSAY field name. It reacts to *types*: a `time` field becomes a
 * running countdown because the schema spec says a time output should render as "a human-readable
 * time string or a countdown clock", and a numeric field animates when its value changes because
 * a number that silently swaps is a number nobody notices moved.
 */

/** One shared second-tick. A timer per countdown would be dozens of intervals on a full page. */
let tickers = 0;
let tickTimer: number | undefined;
const listeners = new Set<() => void>();

function subscribe(fn: () => void) {
  listeners.add(fn);
  if (++tickers === 1) {
    tickTimer = window.setInterval(() => listeners.forEach((l) => l()), 1000);
  }
  return () => {
    listeners.delete(fn);
    if (--tickers === 0 && tickTimer !== undefined) {
      clearInterval(tickTimer);
      tickTimer = undefined;
    }
  };
}

export function useSecond(): number {
  const [n, setN] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => subscribe(() => setN(Math.floor(Date.now() / 1000))), []);
  return n;
}

/** Re-runs `fn` on an interval, and pauses while the tab is hidden. */
export function usePolled<T>(
  fn: () => Promise<T>,
  deps: unknown[],
  ms = 6000,
): { value: T | null; pulse: number } {
  const [value, setValue] = useState<T | null>(null);
  const [pulse, setPulse] = useState(0);
  const fnRef = useRef(fn);
  fnRef.current = fn;

  useEffect(() => {
    let live = true;
    let timer: number | undefined;

    const run = async () => {
      if (document.hidden) return;
      try {
        const v = await fnRef.current();
        if (!live) return;
        setValue(v);
        setPulse((p) => p + 1);
      } catch {
        /* a failed poll is not a reason to blank the page */
      }
    };

    void run();
    timer = window.setInterval(run, ms);
    const onVis = () => {
      if (!document.hidden) void run();
    };
    document.addEventListener("visibilitychange", onVis);

    return () => {
      live = false;
      if (timer) clearInterval(timer);
      document.removeEventListener("visibilitychange", onVis);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, ms]);

  return { value, pulse };
}

/** A live countdown to a unix timestamp, or the elapsed time once it has passed. */
export function Countdown({ at }: { at: bigint }) {
  const now = useSecond();
  const target = Number(at);
  if (!target) return <span className="dim">—</span>;

  const delta = target - now;
  const past = delta < 0;
  let s = Math.abs(delta);
  const d = Math.floor(s / 86400);
  s -= d * 86400;
  const h = Math.floor(s / 3600);
  s -= h * 3600;
  const m = Math.floor(s / 60);
  s -= m * 60;

  const pad = (n: number) => String(n).padStart(2, "0");
  const body = d > 0 ? `${d}d ${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(h)}:${pad(m)}:${pad(s)}`;

  return (
    <span className={past ? "clock is-past" : "clock is-live"}>
      {past ? "−" : ""}
      {body}
    </span>
  );
}

/**
 * A number that animates to its new value, and flashes gold when it changes.
 * Eased over ~700ms — long enough to be seen, short enough not to lie about how current it is.
 */
export function Rolling({ text }: { text: string }) {
  const [shown, setShown] = useState(text);
  const [changed, setChanged] = useState(false);
  const prev = useRef(text);

  useEffect(() => {
    if (text === prev.current) return;

    const from = Number(prev.current.replace(/[^0-9.-]/g, ""));
    const to = Number(text.replace(/[^0-9.-]/g, ""));
    prev.current = text;
    setChanged(true);
    const stop = window.setTimeout(() => setChanged(false), 900);

    // Only interpolate when both ends are plain numbers of the same shape; anything else
    // (an address, a boolean, a clock) simply swaps.
    if (!Number.isFinite(from) || !Number.isFinite(to)) {
      setShown(text);
      return () => clearTimeout(stop);
    }

    const decimals = (text.split(".")[1] ?? "").length;
    const group = text.includes(",");
    const started = performance.now();
    const DURATION = 700;
    let raf = 0;

    const step = (now: number) => {
      const p = Math.min(1, (now - started) / DURATION);
      const eased = 1 - Math.pow(1 - p, 3);
      const v = from + (to - from) * eased;
      let out = v.toFixed(decimals);
      if (group) out = out.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
      setShown(p < 1 ? out : text);
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);

    return () => {
      cancelAnimationFrame(raf);
      clearTimeout(stop);
    };
  }, [text]);

  return <span className={changed ? "rolling is-changed" : "rolling"}>{shown}</span>;
}

/** Chooses the live presentation a field's declared type calls for. */
export function LiveCell({ value, field, text }: { value: unknown; field: FieldDescriptor; text: string }) {
  if (field.fieldType === "time" && (typeof value === "bigint" || typeof value === "number")) {
    return <Countdown at={BigInt(value)} />;
  }
  return <Rolling text={text} />;
}

/** A soft placeholder while a first read is in flight. */
export function Skeleton({ rows = 3 }: { rows?: number }) {
  return (
    <div className="card-grid">
      {Array.from({ length: rows }, (_, i) => (
        <article key={i} className="plate-card is-skeleton" aria-hidden="true">
          <dl>
            {Array.from({ length: 5 }, (_, j) => (
              <div key={j} className="kv">
                <dt>
                  <span className="shimmer" style={{ width: `${52 + ((j * 13) % 30)}px` }} />
                </dt>
                <dd>
                  <span className="shimmer" style={{ width: `${40 + ((j * 17) % 46)}px` }} />
                </dd>
              </div>
            ))}
          </dl>
        </article>
      ))}
    </div>
  );
}
