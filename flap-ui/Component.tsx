"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Flame, Gavel, Hammer } from "lucide-react";
import type { Address, VaultComponentProps } from "@/src/sdk";
import { formatTokenAmount, handleTxError, readTaxVaultHostContext, useFlapSdk } from "@/src/sdk";
import { AddressLink, Alert, Card, CardContent, CardHeader, StatusBadge, TxButton, type TxButtonState } from "@/src/ui";
import { vaultAbi } from "./VaultABI";

/**
 * ASSAY's own vault surface.
 *
 * The palette, the mono-uppercase labelling, the hairline rules and the struck-plate button are
 * assaymine.cash's, carried across as CSS. Two things could not come with them and are not
 * pretended at: the site's display faces are loaded from a font host this runtime does not reach,
 * and its paper and gold-etch textures are image files, which are only admissible here through a
 * pinned IPFS CID. The gold is a gradient instead of a photograph of one, and the crucible is
 * drawn rather than placed.
 */

type StatsTuple = readonly [
  tasks: bigint,
  openTasks: bigint,
  unassignedBnb: bigint,
  committedBtcb: bigint,
  paidBtcb: bigint,
  minersPaid: bigint,
];

interface BountyRow {
  taskId: bigint;
  baselineGas: bigint;
  bountyBtcb: bigint;
  paidBtcb: bigint;
  entrants: bigint;
  phase: bigint;
  endsAt: bigint;
  yourScore: bigint;
  yourBtcb: bigint;
}

const GOLD = "#cea64a";
const GOLD_BRIGHT = "#eac652";
const RULE = "#322f27";
const INK = "#f2efe2";
const INK_3 = "#8d8a80";
const MUTED = "#5f5c55";

/**
 * A readout in the site's own palette.
 *
 * Not the host `Metric`: its tones are the host's accents (lime, cyan, amber), and a headline
 * number in someone else's accent is the one place the borrowed identity would show.
 */
function Readout({ label, value, hint, lead }: { label: string; value: string; hint?: string; lead?: boolean }) {
  return (
    <div className={`border p-3 ${lead ? "border-[#8a6e22] bg-[rgba(206,166,74,0.06)]" : "border-[#1c1b17] bg-[#0d0d10]"}`}>
      <div className="font-mono text-[9px] uppercase leading-none tracking-[0.2em] text-[#8d8a80]">{label}</div>
      <div className={`mt-2 font-mono text-xl tabular-nums leading-none ${lead ? "text-[#eac652]" : "text-[#f2efe2]"}`}>{value}</div>
      {hint ? <div className="mt-2 font-mono text-[9px] uppercase tracking-[0.16em] text-[#5f5c55]">{hint}</div> : null}
    </div>
  );
}

/** Uppercase mono caption — the site's label voice. */
function Label({ children }: { children: React.ReactNode }) {
  return <span className="font-mono text-[9.5px] uppercase leading-none tracking-[0.28em] text-[#cea64a]">{children}</span>;
}

/**
 * The crucible, drawn.
 *
 * Static graphic nodes and one local gradient. The site fills this with a scanned gold-leaf
 * texture; a repeating linear gradient stands in for the hatching, which is the honest
 * substitution rather than an approximation of the file.
 */
function CrucibleArtwork() {
  return (
    <svg viewBox="0 0 120 120" role="img" aria-label="ASSAY crucible" className="h-14 w-14 shrink-0 sm:h-16 sm:w-16">
      <defs>
        <linearGradient id="assayLeaf" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#8a6e22" />
          <stop offset="38%" stopColor="#eac652" />
          <stop offset="62%" stopColor="#a5822c" />
          <stop offset="100%" stopColor="#eac652" />
        </linearGradient>
        <radialGradient id="assayMelt" cx="50%" cy="72%" r="46%">
          <stop offset="0%" stopColor="#eac652" stopOpacity="0.55" />
          <stop offset="100%" stopColor="#eac652" stopOpacity="0" />
        </radialGradient>
      </defs>
      <circle cx="60" cy="60" r="57" fill="none" stroke="#8a6e22" strokeWidth="1" />
      <circle cx="60" cy="60" r="52" fill="none" stroke="#322f27" strokeWidth="1" strokeDasharray="1 4" />
      <circle cx="60" cy="76" r="26" fill="url(#assayMelt)" />
      <path d="M38 40 L82 40 L81 47 L74 47 L66 88 Q60 94 54 88 L46 47 L39 47 Z" fill="url(#assayLeaf)" stroke="#8a6e22" strokeWidth="0.8" />
      <path d="M44 53 L76 53" stroke="#3a2f12" strokeWidth="0.9" opacity="0.55" />
      <path d="M52 26 Q56 20 52 14" fill="none" stroke={GOLD} strokeWidth="1.1" opacity="0.75" />
      <path d="M60 24 Q64 17 60 10" fill="none" stroke={GOLD} strokeWidth="1.1" opacity="0.9" />
      <path d="M68 26 Q72 20 68 14" fill="none" stroke={GOLD} strokeWidth="1.1" opacity="0.75" />
      <circle cx="53" cy="99" r="2" fill={GOLD_BRIGHT} />
      <circle cx="60" cy="101" r="2.4" fill={GOLD_BRIGHT} />
      <circle cx="67" cy="99" r="2" fill={GOLD_BRIGHT} />
    </svg>
  );
}

function phaseLabel(phase: bigint, t: (k: string) => string) {
  return phase === 0n ? t("states.committing") : phase === 1n ? t("states.revealing") : t("states.settled");
}

export default function AssayVaultUi(_props: VaultComponentProps) {
  const sdk = useFlapSdk();
  const { context, i18n } = sdk;
  const t = i18n.t;
  const host = readTaxVaultHostContext(context.host);

  const [banner, setBanner] = useState<string | null>(null);
  const [stats, setStats] = useState<StatsTuple | null>(null);
  const [rows, setRows] = useState<BountyRow[]>([]);
  const [reward, setReward] = useState<Address | null>(null);
  const [selected, setSelected] = useState<bigint | null>(null);
  const [txState, setTxState] = useState<TxButtonState>("idle");
  const [error, setError] = useState<string | null>(null);

  const riskLevel = host.vaultInfo?.riskLevel ?? host.taxInfo?.vaultInfo?.riskLevel ?? null;
  const riskLabel =
    riskLevel === 1
      ? t("states.riskLow")
      : riskLevel === 2
        ? t("states.riskLowMedium")
        : riskLevel === 3
          ? t("states.riskMedium")
          : riskLevel === 4
            ? t("states.riskHigh")
            : riskLevel === 0
              ? t("states.riskUnverified")
              : t("states.riskMissing");
  const riskTone = riskLevel === null || riskLevel === 0 || riskLevel >= 4 ? "danger" : riskLevel >= 3 ? "warning" : "success";
  const marketPhase = host.marketPhase;
  const marketLabel =
    marketPhase === "internal-market"
      ? t("states.marketPhaseInternal")
      : marketPhase === "dex-listed"
        ? t("states.marketPhaseDexListed")
        : t("states.marketPhaseUnknown");

  const txErrorMessages = useMemo(
    () => ({
      userRejected: t("errors.userRejected"),
      walletDisconnected: t("errors.walletDisconnected"),
      fallback: t("errors.generic"),
    }),
    [t],
  );

  const read = useCallback(async () => {
    // A visitor with no wallet should still see the bounties, and `getBounties` needs an address
    // to answer "yours" for. The vault's own address is the honest stand-in: it can never hold a
    // score, so every "yours" comes back zero, which is exactly the truth for a disconnected
    // visitor — and it keeps a literal address out of this source.
    const viewer = (context.userAddress ?? context.vaultAddress) as Address;
    const [nextBanner, nextStats, nextRows, nextReward] = await Promise.all([
      sdk.readContract<string>({ contract: "vault", address: context.vaultAddress, abi: vaultAbi, functionName: "description" }),
      sdk.readContract<StatsTuple>({ contract: "vault", address: context.vaultAddress, abi: vaultAbi, functionName: "stats" }),
      sdk.readContract<readonly BountyRow[]>({
        contract: "vault",
        address: context.vaultAddress,
        abi: vaultAbi,
        functionName: "getBounties",
        args: [viewer, 0n, 4n],
      }),
      sdk.readContract<Address>({ contract: "vault", address: context.vaultAddress, abi: vaultAbi, functionName: "reward" }),
    ]);
    setBanner(nextBanner);
    setStats(nextStats);
    setRows([...nextRows]);
    setReward(nextReward);
    setSelected((current) => current ?? nextRows.find((r) => r.yourBtcb > 0n)?.taskId ?? nextRows[0]?.taskId ?? null);
  }, [sdk, context.vaultAddress, context.userAddress]);

  // Polled, not read once: a tournament changes phase while somebody is looking at it, and a
  // panel frozen at first paint would show a closed window as still open.
  useEffect(() => {
    let alive = true;
    const run = () => {
      read().catch(() => {
        if (alive) setStats(null);
      });
    };
    run();
    const timer = setInterval(run, 12_000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [read]);

  const chosen = rows.find((r) => r.taskId === selected) ?? null;
  const collectable = chosen?.yourBtcb ?? 0n;

  const onCollect = useCallback(async () => {
    if (!chosen) return;
    setError(null);
    setTxState("writing");
    try {
      const hash = await sdk.writeContract({
        contract: "vault",
        address: context.vaultAddress,
        abi: vaultAbi,
        functionName: "collect",
        args: [chosen.taskId],
      });
      setTxState("confirming");
      await sdk.waitForTransaction(hash);
      setTxState("success");
      await read();
    } catch (e) {
      setError(handleTxError(e, txErrorMessages));
      setTxState("failed");
    }
  }, [sdk, chosen, context.vaultAddress, read, txErrorMessages]);

  const btcb = (v: bigint) => formatTokenAmount(v, 18, 6);

  return (
    <div className="w-full">
      <Card className="overflow-hidden rounded-none border-[#322f27] bg-[#08080a] shadow-[0_24px_80px_-40px_rgba(206,166,74,0.35)]">
        <CardHeader className="border-b border-[#1c1b17] p-4 sm:p-6">
          {/* Risk status leads the panel. On an unverified Vault it is the first thing a visitor
              needs, so it is placed above the lockup rather than beside it. */}
          <div className="flex flex-wrap items-center gap-2 border-b border-[#1c1b17] pb-4">
            <StatusBadge tone={riskTone}>{riskLabel}</StatusBadge>
            <StatusBadge tone="neutral">{marketLabel}</StatusBadge>
          </div>

          <div className="flex flex-wrap items-start justify-between gap-4 pt-4">
            <div className="flex min-w-0 items-center gap-4">
              <CrucibleArtwork />
              <div className="min-w-0">
                <div className="animate-shimmer bg-gradient-to-r from-[#8a6e22] via-[#eac652] to-[#8a6e22] bg-[length:200%_auto] bg-clip-text font-mono text-2xl uppercase leading-none tracking-[0.42em] text-transparent sm:text-3xl">
                  {t("title")}
                </div>
                <div className="mt-2 font-mono text-[10px] uppercase tracking-[0.3em] text-[#8d8a80] sm:text-[11px]">{t("subtitle")}</div>
              </div>
            </div>
          </div>

          {banner ? (
            <div className="mt-5 border-l-2 border-[#8a6e22] py-1.5 pl-4 font-mono text-[11px] leading-relaxed text-[#eac652]">{banner}</div>
          ) : null}
          <p className="mt-4 max-w-[68ch] text-[13px] leading-[1.85] text-[#b6b2a5]">{t("lede")}</p>
        </CardHeader>

        <CardContent className="space-y-5 p-4 sm:p-6">
          {riskLevel === null ? <Alert tone="danger">{t("notices.riskMissing")}</Alert> : null}

          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 sm:gap-3">
            <Readout lead label={t("labels.behind")} value={stats ? btcb(stats[3]) : "—"} hint="BTCB" />
            <Readout label={t("labels.paid")} value={stats ? btcb(stats[4]) : "—"} hint={`${stats ? String(stats[5]) : "—"} · ${t("labels.payouts")}`} />
            <Readout label={t("labels.open")} value={stats ? `${String(stats[1])} / ${String(stats[0])}` : "—"} hint={t("labels.tasks")} />
          </div>

          <div className="border border-[#1c1b17]">
            <div className="flex items-center gap-2 border-b border-[#1c1b17] bg-[#0d0d10] px-3 py-2.5">
              <Flame className="h-3.5 w-3.5" style={{ color: GOLD }} />
              <Label>{t("sections.bounties")}</Label>
            </div>

            {rows.length === 0 ? (
              <div className="px-3 py-6 text-center font-mono text-[11px] tracking-[0.14em] text-[#5f5c55]">
                {stats ? t("states.noTasks") : t("states.loading")}
              </div>
            ) : (
              rows.map((row) => {
                const active = row.taskId === selected;
                return (
                  <button
                    key={String(row.taskId)}
                    type="button"
                    onClick={() => setSelected(row.taskId)}
                    className={`flex w-full flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-[#1c1b17] px-3 py-3 text-left transition-colors last:border-b-0 ${
                      active ? "bg-[rgba(206,166,74,0.07)]" : "hover:bg-[rgba(206,166,74,0.04)]"
                    }`}
                  >
                    <span className="flex items-baseline gap-3">
                      <span className="font-mono text-base tabular-nums" style={{ color: active ? GOLD_BRIGHT : INK }}>
                        #{String(row.taskId)}
                      </span>
                      <span className="font-mono text-[9.5px] uppercase tracking-[0.18em]" style={{ color: INK_3 }}>
                        {phaseLabel(row.phase, t)} · {String(row.baselineGas)} {t("units.gas")} · {String(row.entrants)} {t("labels.entrants")}
                      </span>
                    </span>
                    <span className="flex items-baseline gap-4 font-mono text-[12px] tabular-nums">
                      <span style={{ color: GOLD_BRIGHT }}>{btcb(row.bountyBtcb)}</span>
                      <span style={{ color: row.yourBtcb > 0n ? "#8fae62" : MUTED }}>{btcb(row.yourBtcb)}</span>
                    </span>
                  </button>
                );
              })
            )}
          </div>

          <div className="border border-[#322f27] bg-[#0d0d10] p-4">
            <div className="flex flex-wrap items-end justify-between gap-4">
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <Gavel className="h-3.5 w-3.5" style={{ color: GOLD }} />
                  <Label>{t("sections.primaryAction")}</Label>
                </div>
                <div className="mt-3 font-mono text-2xl tabular-nums" style={{ color: collectable > 0n ? GOLD_BRIGHT : MUTED }}>
                  {btcb(collectable)}
                </div>
                <p className="mt-2 max-w-[52ch] font-mono text-[10px] leading-[1.7] tracking-[0.06em] text-[#5f5c55]">
                  {!context.userAddress ? t("states.walletRequired") : collectable > 0n ? t("hints.collect") : t("states.nothingToCollect")}
                </p>
              </div>

              {/* The host draws its buttons as a chamfered plate through two CSS custom
                  properties. Those are the extension point, so this carries our gold in and
                  leaves their geometry alone — a rectangle forced over the cut corner would
                  read as a foreign control inside their shell, and the chamfer is theirs. */}
              <TxButton
                type="button"
                variant="outline"
                state={txState}
                idleLabel={t("actions.collect")}
                disabled={collectable === 0n || txState === "writing" || txState === "confirming"}
                onClick={onCollect}
                className="h-11 px-7 font-mono text-[10.5px] uppercase tracking-[0.24em] text-[#eac652] [--ui20-chamfer-bg:#0d0d10] [--ui20-chamfer-border:#cea64a] hover:text-[#f2efe2] hover:[--ui20-chamfer-bg:#3a2f12] hover:[--ui20-chamfer-border:#eac652]"
              >
                <Hammer className="h-3.5 w-3.5" />
                <span>{txState === "writing" || txState === "confirming" ? t("actions.collecting") : t("actions.collect")}</span>
              </TxButton>
            </div>
            {error ? (
              <div className="mt-3">
                <Alert tone="danger">{error}</Alert>
              </div>
            ) : null}
          </div>

          <div className="grid gap-x-6 gap-y-2 border-t border-[#1c1b17] pt-4 sm:grid-cols-3">
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <Label>{t("labels.vault")}</Label>
              <div className="mt-1 min-w-0 font-mono text-[11px] text-[#b6b2a5]">
                <AddressLink address={context.vaultAddress} explorerBaseUrl={context.explorerBaseUrl} />
              </div>
            </div>
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <Label>{t("labels.token")}</Label>
              <div className="mt-1 min-w-0 font-mono text-[11px] text-[#b6b2a5]">
                <AddressLink address={context.tokenAddress} explorerBaseUrl={context.explorerBaseUrl} label={context.tokenSymbol} />
              </div>
            </div>
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <Label>{t("labels.reward")}</Label>
              <div className="mt-1 min-w-0 font-mono text-[11px] text-[#b6b2a5]">
                {reward ? <AddressLink address={reward} explorerBaseUrl={context.explorerBaseUrl} label="BTCB" /> : "—"}
              </div>
            </div>
          </div>

          <p className="font-mono text-[9.5px] uppercase leading-[1.9] tracking-[0.16em] text-[#5f5c55]">{t("hints.score")}</p>
        </CardContent>
      </Card>
    </div>
  );
}
