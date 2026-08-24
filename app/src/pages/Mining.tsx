import { useI18n } from "../i18n";

export default function Mining() {
  const { t } = useI18n();
  const sections = [
    { h: t("mining.h.task"), p: t("mining.p.task") },
    { h: t("mining.h.crucible"), p: t("mining.p.crucible") },
    { h: t("mining.h.meter"), p: t("mining.p.meter") },
    { h: t("mining.h.score"), p: t("mining.p.score") },
    { h: t("mining.h.sybil"), p: t("mining.p.sybil") },
  ];
  return (
    <>
      <section className="section">
        <div className="shell stack-l">
          <div className="stack rise">
            <span className="label">{t("nav.mining")}</span>
            <h1 className="display display-xl">{t("mining.title")}</h1>
          </div>
          <p className="lede rise rise-2">{t("mining.lede")}</p>
        </div>
      </section>

      <hr className="rule rule-gold" />

      <section className="section">
        <div className="shell stack-l">
          {sections.map((s) => (
            <div key={s.h} className="stack" style={{ gap: 12 }}>
              <h2 className="display display-m">{s.h}</h2>
              <p style={{ margin: 0 }}>{s.p}</p>
            </div>
          ))}

          <div className="plate plate-gold">
            <div className="stack" style={{ gap: 12 }}>
              <span className="label">score = baseline ÷ measured</span>
              <p className="mono" style={{ margin: 0, fontSize: "0.9em", color: "var(--text-3)" }}>
                {"score = min(baselineGas * 1e18 / gasUsed, 32e18)   // gasUsed >= baselineGas -> 0"}
              </p>
            </div>
          </div>

          <hr className="rule" />

          <div className="stack" style={{ gap: 12 }}>
            <h2 className="display display-m">{t("mining.h.honest")}</h2>
            <p style={{ margin: 0 }}>{t("mining.p.honest")}</p>
          </div>
        </div>
      </section>
    </>
  );
}
