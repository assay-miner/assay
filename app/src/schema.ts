import { decodeFunctionResult, encodeFunctionData, type Abi, type Address } from "viem";
import { ADDRESSES, client } from "./chain";
import { tournamentAbi } from "./abi";

/**
 * The on-chain UI schema, and enough machinery to render a page from it.
 *
 * The contract describes its own interface — method names, argument types, column headers, which
 * views return arrays, which writes need an ERC-20 approve first. A renderer that reads this can
 * build a working page for a contract it has never seen, which is the point: no bespoke frontend
 * has to exist before someone can use a new vault.
 *
 * This module deliberately knows nothing about ASSAY specifically. It takes a schema and a set of
 * decoded values. Whatever the contract says it can do is what appears.
 */

export type FieldDescriptor = {
  name: string;
  fieldType: string;
  description: string;
  decimals: number;
};

export type ApproveAction = { tokenType: string; amountFieldName: string };

export type MethodSchema = {
  name: string;
  description: string;
  inputs: readonly FieldDescriptor[];
  outputs: readonly FieldDescriptor[];
  approvals: readonly ApproveAction[];
  isInputArray: boolean;
  isOutputArray: boolean;
  isWriteMethod: boolean;
};

export type UISchema = {
  vaultType: string;
  description: string;
  methods: readonly MethodSchema[];
};

/** "time" is an alias for uint256 carrying a unix timestamp; everything else is its own ABI type. */
export function abiTypeOf(f: FieldDescriptor): string {
  return f.fieldType === "time" ? "uint256" : f.fieldType;
}

export async function readSchema(): Promise<UISchema | null> {
  if (!ADDRESSES.tournament) return null;
  const raw = (await client().readContract({
    address: ADDRESSES.tournament,
    abi: tournamentAbi,
    functionName: "vaultUISchema",
  })) as UISchema;
  return raw;
}

export async function readBanner(): Promise<string | null> {
  if (!ADDRESSES.tournament) return null;
  try {
    return (await client().readContract({
      address: ADDRESSES.tournament,
      abi: tournamentAbi,
      functionName: "description",
    })) as string;
  } catch {
    return null;
  }
}

/**
 * Calls a schema-described method with `eth_call` and decodes the result against the types the
 * schema declared — not against a hand-written ABI. If the two ever disagree, the schema is the
 * one the generic UI believes, so it is the one used here.
 */
export async function callMethod(
  method: MethodSchema,
  args: readonly unknown[],
): Promise<unknown[][]> {
  if (!ADDRESSES.tournament) return [];

  const inputTypes = method.inputs.map((f) => ({ name: f.name, type: abiTypeOf(f) }));
  const outputTuple = {
    type: method.isOutputArray ? "tuple[]" : "tuple",
    components: method.outputs.map((f) => ({ name: f.name, type: abiTypeOf(f) })),
  };
  const flat = method.outputs.map((f) => ({ name: f.name, type: abiTypeOf(f) }));

  // A method returning several values and a method returning one struct decode differently, and
  // the schema does not distinguish them. Try the struct shape, fall back to the flat one.
  for (const outputs of [[outputTuple], flat]) {
    const abi = [
      {
        type: "function",
        name: method.name,
        stateMutability: method.isWriteMethod ? "nonpayable" : "view",
        inputs: inputTypes,
        outputs,
      },
    ] as unknown as Abi;

    try {
      const data = encodeFunctionData({ abi, functionName: method.name, args: args as never });
      const res = await client().call({ to: ADDRESSES.tournament as Address, data });
      if (!res.data) return [];
      const decoded = decodeFunctionResult({ abi, functionName: method.name, data: res.data });

      if (method.isOutputArray) {
        // viem unwraps a single return value, so `decoded` is already the tuple[] — indexing it
        // once more would hand back the first row and then fail to map over it, which is exactly
        // how this silently rendered an empty list over a chain that had two tasks on it.
        const rows = decoded as unknown as Record<string, unknown>[];
        if (!Array.isArray(rows)) return [];
        return rows.map((r) => method.outputs.map((f) => r[f.name]));
      }
      if (Array.isArray(decoded)) {
        const first = decoded[0];
        if (first && typeof first === "object" && !Array.isArray(first)) {
          const r = first as Record<string, unknown>;
          return [method.outputs.map((f) => r[f.name])];
        }
        return [decoded as unknown[]];
      }
      return [[decoded]];
    } catch {
      // try the next shape
    }
  }
  return [];
}

/** Formats one cell the way the schema asked for it. */
export function formatCell(value: unknown, field: FieldDescriptor): string {
  if (value === undefined || value === null) return "—";

  if (field.fieldType === "bool") return value ? "yes" : "no";
  if (field.fieldType === "address") {
    const a = String(value);
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
  }
  if (field.fieldType === "time") {
    const n = Number(value);
    if (n === 0) return "—";
    return new Date(n * 1000).toISOString().replace("T", " ").slice(0, 16);
  }
  if (typeof value === "bigint" || typeof value === "number") {
    const v = BigInt(value);
    if (field.decimals > 0) {
      const base = 10n ** BigInt(field.decimals);
      const whole = v / base;
      const frac = ((v % base) * 1000n) / base;
      return `${whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${frac
        .toString()
        .padStart(3, "0")}`;
    }
    return v.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }
  return String(value);
}
