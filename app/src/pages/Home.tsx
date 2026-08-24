import { Link } from "react-router-dom";
import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import {
  IDENTITY_REGISTRY,
  EXPLORER,
  formatUnits,
  isDeployed,
  readProtocol,
  shortAddress,
  type Protocol,
} from "../chain";

function Readout({ label, value, empty }: { label: string; value: string; empty?: boolean }) {
  return (
    <div className="readout">
      <span className="label label-muted">{label}</span>
      <span className={`readout-value${empty ? " is-empty" : ""}`}>{value}</span>
    </div>
  );
}

export default function Home() {
  const { t } = useI18n();
  const [protocol, setProtocol] = useState<Protocol | null>(null);
  const [loading, setLoading] = useState(isDeployed);

  useEffect(() => {
    if (!isDeployed) return;
    let live = true;
    readProtocol()
      .then((p) => live && setProtocol(p))
      .catch(() => live && setProtocol(null))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, []);

  // Nothing deployed means nothing to show. The dash is the honest reading; a placeholder number
  // here would be indistinguishable from a real one.
  const dash = loading ? t("common.loading") : t("common.notDeployed");

  const claims = [
    { label: t("home.claim1.label"), body: t("home.claim1.body") },
    { label: t("home.claim2.label"), body: t("home.claim2.body") },
    { label: t("home.claim3.label"), body: t("home.claim3.body") },
  ];

  const steps = [
    { t: t("home.loop.s1.t"), b: t("home.loop.s1.b") },
    { t: t("home.loop.s2.t"), b: t("home.loop.s2.b") },
    { t: t("home.loop.s3.t"), b: t("home.loop.s3.b") },
    { t: t("home.loop.s4.t"), b: t("home.loop.s4.b") },
  ];

  return (
    <>
      <section className="section">
        <div className="shell stack-l">
          <div className="stack rise">
            <span className="label">{t("home.eyebrow")}</span>
            <h1 className="display display-xl">{t("home.title")}</h1>
          </div>
          <p className="lede rise rise-2">{t("home.lede")}</p>
          <div className="rise rise-3" style={{ display: "flex", gap: 14, flexWrap: "wrap" }}>
            <Link className="btn" to="/docs">
              {t("home.ctaPrimary")}
            </Link>
            <Link className="btn btn-quiet" to="/mining">
              {t("home.ctaSecondary")}
            </Link>
          </div>
        </div>
      </section>

      <hr className="rule rule-gold" />

      <section className="section-tight">
        <div className="shell grid-3">
          {claims.map((c, i) => (
            <div key={c.label} className={`plate rise rise-${i + 2}`}>
              <div className="stack">
                <span className="label">{c.label}</span>
                <p style={{ margin: 0, fontSize: "0.96em" }}>{c.body}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <hr className="rule" />

      <section className="section">
        <div className="shell stack-l">
          <h2 className="display display-l">{t("home.loop.title")}</h2>
          <div className="grid-pair">
            {steps.map((s, i) => (
              <div key={s.t} className="stack" style={{ gap: 10 }}>
                <span className="label mono">{String(i + 1).padStart(2, "0")}</span>
                <h3 className="display display-m">{s.t}</h3>
                <p style={{ margin: 0, fontSize: "0.96em" }}>{s.b}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <hr className="rule" />

      <section className="section">
        <div className="shell stack-l">
          <h2 className="display display-l">{t("home.stats.title")}</h2>
          <div className="grid-3">
            <Readout
              label={t("home.stats.tasks")}
              value={protocol ? protocol.taskCount.toString() : dash}
              empty={!protocol}
            />
            <Readout
              label={t("home.stats.supply")}
              value={protocol ? `${formatUnits(protocol.totalSupply, 0)} ${protocol.symbol}` : dash}
              empty={!protocol}
            />
            <Readout
              label={t("home.stats.minStake")}
              value={protocol ? `${formatUnits(protocol.minStake, 0)} ${protocol.symbol}` : dash}
              empty={!protocol}
            />
          </div>
          <div className="stack" style={{ gap: 8 }}>
            <span className="label label-muted">{t("home.stats.registry")}</span>
            <a
              className="mono"
              style={{ fontSize: "0.9em" }}
              href={`${EXPLORER}/address/${IDENTITY_REGISTRY}`}
              target="_blank"
              rel="noreferrer"
            >
              {shortAddress(IDENTITY_REGISTRY)} · ERC-8004
            </a>
          </div>
        </div>
      </section>
    </>
  );
}
