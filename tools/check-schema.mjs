#!/usr/bin/env node
/**
 * Compares every write method's self-describing schema against the compiled ABI.
 *
 * The schema is what a generic UI builds its input forms from. postTask's third input said
 * baselineGas/uint256 for a whole version after the function started taking referenceRuntime/bytes,
 * so a UI rendering straight from it would have built a number field and sent a number where the
 * contract expects bytes. No contract test caught it, because the contracts never read their own
 * schema — only a UI does, and a reviewer building one found it.
 *
 * This reads the FieldDescriptor names out of the source's schema block and the parameter names out
 * of the artifact, and requires them to agree in order.
 */
import { readFileSync } from "node:fs";

const TARGETS = [
  { source: "src/Tournament.sol", artifact: "out/Tournament.sol/Tournament.json" },
  { source: "src/AssayFlapVault.sol", artifact: "out/AssayFlapVault.sol/AssayFlapVault.json" },
];

let failed = 0;
const fail = (m) => { console.error(`  MISMATCH ${m}`); failed++; };

for (const { source, artifact } of TARGETS) {
  const src = readFileSync(source, "utf8");
  const abi = JSON.parse(readFileSync(artifact, "utf8")).abi;

  // Each `m.name = "x";` opens a block whose m.inputs[i] = FieldDescriptor("field", ...) lines
  // describe that method, up to the next `m.name =`.
  const blocks = [...src.matchAll(/m\.name = "(\w+)";/g)];
  for (let b = 0; b < blocks.length; b++) {
    const method = blocks[b][1];
    const from = blocks[b].index;
    const to = b + 1 < blocks.length ? blocks[b + 1].index : src.length;
    const body = src.slice(from, to);
    if (!/m\.isWriteMethod = true/.test(body)) continue;

    const declared = [...body.matchAll(/m\.inputs\[\d+\] = FieldDescriptor\(\s*"(\w+)"/g)].map((m) => m[1]);
    const fn = abi.find((e) => e.type === "function" && e.name === method);
    if (!fn) { fail(`${source}: schema describes ${method}, which the ABI does not have`); continue; }

    const actual = fn.inputs.map((i) => i.name);
    if (declared.length !== actual.length) {
      fail(`${method}: schema declares ${declared.length} inputs, the ABI has ${actual.length}`);
      continue;
    }
    declared.forEach((name, i) => {
      if (name !== actual[i]) fail(`${method} input ${i}: schema says "${name}", the ABI says "${actual[i]}"`);
    });
    console.log(`  ok   ${method}(${actual.join(", ")})`);
  }
}

if (failed) {
  console.error(`\n${failed} schema field(s) disagree with the ABI — a generic UI would build the wrong form`);
  process.exit(1);
}
console.log("\nevery write method's schema matches its ABI");
