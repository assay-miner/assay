import { createPublicClient, http, type Address, type PublicClient } from "viem";
import { bsc, bscTestnet } from "viem/chains";
import { agentrosterAbi, assaytokenAbi, tournamentAbi } from "./abi";

/**
 * Deployment wiring.
 *
 * Addresses come from build-time environment variables rather than a checked-in constant, because
 * the same bundle is deployed against testnet and mainnet. Two things this file is careful about:
 *
 *  - A missing variable and a variable set to the empty string are the same thing here. `??` would
 *    happily hand back "" and every downstream read would fail against address 0x, so the check is
 *    on emptiness, not on nullishness.
 *  - When nothing is configured the app reports "not deployed". It never falls back to sample data:
 *    an empty chain has to look empty, or the fixture becomes the only content anyone ever sees.
 *
 * On a hosted build the host's own environment variables win over any committed .env file, so set
 * these in the hosting dashboard, not only in the repo.
 */

function envAddress(raw: unknown): Address | null {
  if (typeof raw !== "string") return null;
  const v = raw.trim();
  if (v === "") return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) return null;
  return v as Address;
}

const CHAIN_ID = Number(import.meta.env.VITE_CHAIN_ID ?? 97);

export const CHAIN = CHAIN_ID === 56 ? bsc : bscTestnet;

export const EXPLORER = CHAIN_ID === 56 ? "https://bscscan.com" : "https://testnet.bscscan.com";

/** The ERC-8004 Identity Registry. Verified live on both chains at version 2.0.0. */
export const IDENTITY_REGISTRY: Address =
  CHAIN_ID === 56
    ? "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"
    : "0x8004A818BFB912233c491871b3d84c89A494BD9e";

export const ADDRESSES = {
  tournament: envAddress(import.meta.env.VITE_TOURNAMENT),
  roster: envAddress(import.meta.env.VITE_ROSTER),
  token: envAddress(import.meta.env.VITE_TOKEN),
};

export const isDeployed = ADDRESSES.tournament !== null && ADDRESSES.token !== null;

let cached: PublicClient | null = null;

export function client(): PublicClient {
  if (!cached) {
    cached = createPublicClient({
      chain: CHAIN,
      transport: http(import.meta.env.VITE_RPC_URL || undefined),
    });
  }
  return cached;
}

export type TaskRow = {
  id: bigint;
  poster: Address;
  commitEnd: bigint;
  revealEnd: bigint;
  gasCap: number;
  baselineGas: number;
  pot: bigint;
  paidOut: bigint;
  totalScore: bigint;
  reclaimed: boolean;
  vectorCount: bigint;
};

export type ScoreRow = {
  taskId: bigint;
  miner: Address;
  agentId: bigint;
  gasUsed: number;
  score: bigint;
};

export type Protocol = {
  taskCount: bigint;
  totalSupply: bigint;
  minStake: bigint;
  symbol: string;
};

/** Reads the headline protocol numbers. Returns null when nothing is deployed. */
export async function readProtocol(): Promise<Protocol | null> {
  if (!isDeployed) return null;
  const c = client();
  const [taskCount, totalSupply, symbol, minStake] = await Promise.all([
    c.readContract({
      address: ADDRESSES.tournament!,
      abi: tournamentAbi,
      functionName: "taskCount",
    }) as Promise<bigint>,
    c.readContract({
      address: ADDRESSES.token!,
      abi: assaytokenAbi,
      functionName: "totalSupply",
    }) as Promise<bigint>,
    c.readContract({
      address: ADDRESSES.token!,
      abi: assaytokenAbi,
      functionName: "symbol",
    }) as Promise<string>,
    ADDRESSES.roster
      ? (c.readContract({
          address: ADDRESSES.roster,
          abi: agentrosterAbi,
          functionName: "minStake",
        }) as Promise<bigint>)
      : Promise.resolve(0n),
  ]);
  return { taskCount, totalSupply, minStake, symbol };
}

/** Reads every posted task. Task ids are 1..taskCount. */
export async function readTasks(): Promise<TaskRow[]> {
  if (!isDeployed) return [];
  const c = client();
  const count = (await c.readContract({
    address: ADDRESSES.tournament!,
    abi: tournamentAbi,
    functionName: "taskCount",
  })) as bigint;

  const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i + 1));
  return Promise.all(
    ids.map(async (id) => {
      const [task, vectorCount] = await Promise.all([
        c.readContract({
          address: ADDRESSES.tournament!,
          abi: tournamentAbi,
          functionName: "tasks",
          args: [id],
        }) as Promise<readonly unknown[]>,
        c.readContract({
          address: ADDRESSES.tournament!,
          abi: tournamentAbi,
          functionName: "vectorCount",
          args: [id],
        }) as Promise<bigint>,
      ]);
      const [
        poster,
        commitEnd,
        revealEnd,
        gasCap,
        baselineGas,
        pot,
        paidOut,
        totalScore,
        reclaimed,
      ] = task as [Address, bigint, bigint, number, number, bigint, bigint, bigint, boolean];
      return {
        id,
        poster,
        commitEnd,
        revealEnd,
        gasCap,
        baselineGas,
        pot,
        paidOut,
        totalScore,
        reclaimed,
        vectorCount,
      };
    }),
  );
}

/** Reads the scoring submissions for a task, highest score first. */
export async function readScores(taskId: bigint): Promise<ScoreRow[]> {
  if (!isDeployed) return [];
  const c = client();
  const miners = (await c.readContract({
    address: ADDRESSES.tournament!,
    abi: tournamentAbi,
    functionName: "scorers",
    args: [taskId],
  })) as readonly Address[];

  const rows = await Promise.all(
    miners.map(async (miner) => {
      const sub = (await c.readContract({
        address: ADDRESSES.tournament!,
        abi: tournamentAbi,
        functionName: "submissions",
        args: [taskId, miner],
      })) as readonly unknown[];
      const [, agentId, gasUsed, score] = sub as [string, bigint, number, bigint, boolean, boolean];
      return { taskId, miner, agentId, gasUsed, score };
    }),
  );
  return rows.sort((a, b) => (b.score > a.score ? 1 : b.score < a.score ? -1 : 0));
}

export type Phase = "commit" | "reveal" | "settled";

export function phaseOf(task: TaskRow, nowSeconds: number): Phase {
  if (BigInt(nowSeconds) < task.commitEnd) return "commit";
  if (BigInt(nowSeconds) < task.revealEnd) return "reveal";
  return "settled";
}

const DECIMALS = 18n;

/** Formats a token amount with a fixed number of decimal places and no floating point. */
export function formatUnits(value: bigint, places = 2): string {
  const base = 10n ** DECIMALS;
  const whole = value / base;
  const frac = ((value % base) * 10n ** BigInt(places)) / base;
  const grouped = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return places === 0 ? grouped : `${grouped}.${frac.toString().padStart(places, "0")}`;
}

/** Score is fixed point with 18 decimals; shown as a multiple of the baseline. */
export function formatScore(score: bigint): string {
  const whole = score / 10n ** 18n;
  const frac = ((score % 10n ** 18n) * 100n) / 10n ** 18n;
  return `${whole}.${frac.toString().padStart(2, "0")}×`;
}

export function shortAddress(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
