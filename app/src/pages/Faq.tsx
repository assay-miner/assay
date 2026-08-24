import { useI18n } from "../i18n";

export default function Faq() {
  const { t } = useI18n();
  const qa = [
    { q: t("faq.q1"), a: t("faq.a1") },
    { q: t("faq.q2"), a: t("faq.a2") },
    { q: t("faq.q3"), a: t("faq.a3") },
    { q: t("faq.q4"), a: t("faq.a4") },
    { q: t("faq.q5"), a: t("faq.a5") },
  ];
  return (
    <>
      <section className="section">
        <div className="shell stack rise">
          <span className="label">{t("nav.faq")}</span>
          <h1 className="display display-xl">{t("faq.title")}</h1>
        </div>
      </section>
      <hr className="rule rule-gold" />
      <section className="section">
        <div className="shell stack-l">
          {qa.map((item) => (
            <div key={item.q} className="stack" style={{ gap: 10 }}>
              <h2 className="display display-m">{item.q}</h2>
              <p style={{ margin: 0 }}>{item.a}</p>
            </div>
          ))}
        </div>
      </section>
    </>
  );
}
