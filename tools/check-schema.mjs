#!/usr/bin/env node
/**
 * Compares every self-describing schema against the compiled ABI, and checks that every label a
 * user reads is really bilingual.
 *
 * The schema is what a generic UI builds its forms from, and the contracts never read it — only a
 * UI does. So nothing in the test suite can catch it drifting, and it has now drifted three times:
 *
 *   1. postTask's third input said baselineGas/uint256 for a whole version after the function
 *      started taking referenceRuntime/bytes. A reviewer building a UI found it. That is why this
 *      file exists.
 *   2. This file then only compared NAMES. postTask declared `inputs` as "bytes" where the function
 *      takes bytes[], `gasCap` as "uint256" against uint32, `pot` as "uint256" against uint128, and
 *      commitEnd/revealEnd as "time" — which IVaultSchemasV1 defines as an alias for uint256 —
 *      against uint64. Every name matched, so this gate stayed green while a schema-following caller
 *      computed a selector for a function that does not exist. Types are compared now.
 *   3. Labels were English-only in places, and elsewhere "BTCB / BTCB" — the same word on both sides
 *      of the separator, which the multilingual rule treats as non-compliant. Checked here too,
 *      because the same blind spot produced both: nothing executes a label either.
 */
import { readFileSync } from "node:fs";

const TARGETS = [
  { source: "src/Tournament.sol", artifact: "out/Tournament.sol/Tournament.json" },
  { source: "src/AssayFlapVault.sol", artifact: "out/AssayFlapVault.sol/AssayFlapVault.json" },
];

// IVaultSchemasV1: "time" is a display hint whose ABI encoding is identical to uint256. Every other
// fieldType is the ABI type string itself. A UI derives the selector from these, so this mapping is
// the whole reason a wrong type is not cosmetic.
const abiTypeOf = (fieldType) => (fieldType === "time" ? "uint256" : fieldType);

let failed = 0;
const fail = (m) => { console.error(`  MISMATCH ${m}`); failed++; };

// A label is bilingual when it carries both halves and they actually differ. "BTCB / BTCB" passes a
// naive `includes(" / ")` and is exactly what the rule prohibits.
const CJK = /[㐀-鿿豈-﫿]/;
function checkLabel(where, label) {
  const parts = label.split(" / ");
  if (parts.length < 2) return fail(`${where}: label ${JSON.stringify(label)} is single-language`);
  const [en, zh] = [parts[0].trim(), parts.slice(1).join(" / ").trim()];
  if (en === zh) return fail(`${where}: label ${JSON.stringify(label)} is the same on both sides`);
  if (!CJK.test(zh)) fail(`${where}: label ${JSON.stringify(label)} has no Chinese after the separator`);
}

// FieldDescriptor("name", "type", unicode"Label / 标签", decimals) — the label may wrap onto its own
// line, so match across newlines and stop at the closing quote.
const FIELD = /m\.(inputs|outputs)\[(\d+)\] = FieldDescriptor\(\s*"(\w+)"\s*,\s*"([\w\[\]]+)"\s*,\s*unicode"((?:[^"\\]|\\.)*)"/gs;

for (const { source, artifact } of TARGETS) {
  const src = readFileSync(source, "utf8");
  const abi = JSON.parse(readFileSync(artifact, "utf8")).abi;

  const blocks = [...src.matchAll(/m\.name = "(\w+)";/g)];
  for (let b = 0; b < blocks.length; b++) {
    const method = blocks[b][1];
    const from = blocks[b].index;
    const to = b + 1 < blocks.length ? blocks[b + 1].index : src.length;
    const body = src.slice(from, to);

    const fields = [...body.matchAll(FIELD)];
    for (const [, side, idx, name, type, label] of fields) {
      checkLabel(`${source} ${method} ${side}[${idx}] "${name}"`, label);
    }

    // The method's own description is a label too.
    const desc = body.match(/m\.description = unicode"((?:[^"\\]|\\.)*)"/);
    if (desc) checkLabel(`${source} ${method} description`, desc[1]);

    // Only write methods are ABI-encoded from the schema; reads are rendered, not called this way.
    if (!/m\.isWriteMethod = true/.test(body)) continue;

    const declared = fields
      .filter(([, side]) => side === "inputs")
      .map(([, , , name, type]) => ({ name, type }));

    const fn = abi.find((e) => e.type === "function" && e.name === method);
    if (!fn) { fail(`${source}: schema describes ${method}, which the ABI does not have`); continue; }

    if (declared.length !== fn.inputs.length) {
      fail(`${method}: schema declares ${declared.length} inputs, the ABI has ${fn.inputs.length}`);
      continue;
    }

    let bad = false;
    declared.forEach(({ name, type }, i) => {
      const real = fn.inputs[i];
      if (name !== real.name) {
        fail(`${method} input ${i}: schema names it "${name}", the ABI says "${real.name}"`);
        bad = true;
      }
      if (abiTypeOf(type) !== real.type) {
        fail(
          `${method} input ${i} "${name}": schema type "${type}"` +
            (type === "time" ? ' (encodes as uint256)' : "") +
            ` vs ABI "${real.type}" — a UI would compute the wrong selector`
        );
        bad = true;
      }
    });

    // What a schema-following UI would actually call, so a mismatch is visible as the wrong function.
    const selectorish = `${method}(${declared.map((d) => abiTypeOf(d.type)).join(",")})`;
    const truth = `${method}(${fn.inputs.map((i) => i.type).join(",")})`;
    if (!bad) console.log(`  ok   ${truth}`);
    else console.error(`       schema would call ${selectorish}`);
  }
}

if (failed) {
  console.error(`\n${failed} problem(s): a generic UI would build the wrong form, call the wrong`);
  console.error(`selector, or show a label somebody cannot read`);
  process.exit(1);
}
console.log("\nevery schema field matches its ABI type, and every label is bilingual");
