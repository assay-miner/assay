#!/usr/bin/env node
/**
 * Runs the two gates that need a real browser against a real server: `check-lang` and
 * `check-layout`.
 *
 * They used to be listed directly in `npm run verify`, ahead of `vite build`, each defaulting to
 * `http://127.0.0.1:8794` and assuming somebody had already started something there. Nobody had.
 * So `check-lang` failed on ERR_CONNECTION_REFUSED every time, `&&` stopped the chain, and
 * `tsc -b && vite build` never ran — which is how a frontend that could not compile at all sat in
 * the repo with a green-looking verify script in front of it.
 *
 * Two things follow from that, and this file exists to make both structural rather than remembered:
 *
 *   The server is started here, from the `dist/` that `verify` has just built, so a gate can never
 *   be measuring a stale build. A gate that needs a build cannot run before one.
 *
 *   Vite's preview binds IPv6 loopback only, so `127.0.0.1` is refused while `localhost` connects.
 *   ASSAY_URL is set explicitly rather than left to each script's default.
 *
 * The server is torn down on every exit path, including a failing gate — a gate that fails should
 * not also leave a port occupied for the next run.
 */
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "..");
const PORT = process.env.ASSAY_PORT || "8794";
const URL = `http://localhost:${PORT}`;

const GATES = ["scripts/check-lang.mjs", "scripts/check-layout.mjs"];

const run = (cmd, args, opts = {}) =>
  new Promise((ok) => {
    const p = spawn(cmd, args, { cwd: app, stdio: "inherit", ...opts });
    p.on("exit", (code) => ok(code ?? 1));
  });

const server = spawn("npx", ["vite", "preview", "--port", PORT, "--strictPort"], {
  cwd: app,
  stdio: ["ignore", "pipe", "pipe"],
});

let stopped = false;
const stop = () => {
  if (stopped) return;
  stopped = true;
  server.kill("SIGTERM");
};
process.on("exit", stop);
process.on("SIGINT", () => { stop(); process.exit(130); });
process.on("SIGTERM", () => { stop(); process.exit(143); });

/** Waits for the port to actually answer rather than sleeping a guessed interval. */
async function ready(timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(URL, { signal: AbortSignal.timeout(1000) });
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  return false;
}

if (!(await ready())) {
  console.error(`preview server never answered on ${URL}`);
  stop();
  process.exit(1);
}

let failed = 0;
for (const gate of GATES) {
  const code = await run("node", [gate], { env: { ...process.env, ASSAY_URL: URL } });
  if (code !== 0) failed++;
}

stop();
process.exit(failed > 0 ? 1 : 0);
