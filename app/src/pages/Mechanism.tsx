import { useI18n } from "../i18n";
import Deck from "../components/Deck";

/** The three things markets have learned to price, ending on the one we are pricing. */
function CoinRow() {
  const { t } = useI18n();
  const coins = [t("mech.coin1"), t("mech.coin2"), t("mech.coin3")];
  return (
    <div className="coinrow">
      {coins.map((c, i) => (
        <div key={c} style={{ display: "contents" }}>
          {i > 0 && <span className="arrow">→</span>}
          <div className={`coin${i === coins.length - 1 ? " is-live" : ""}`}>
            <span className="disc" />
            <span className="cap">{c}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

export default function Mechanism() {
  const { t } = useI18n();

  const slide = (title: string, left: string, right: string, sub?: string, coins?: boolean) => (
    <>
      <h1 className="plate-title" style={{ textAlign: "center" }}>
        {title}
      </h1>
      {coins && <CoinRow />}
      <div className="cols-2">
        <div className="prose">
          {left}
          {sub && <h3>{sub}</h3>}
        </div>
        <div className="prose">{right}</div>
      </div>
    </>
  );

  return (
    <Deck
      label={t("nav.mechanism")}
      slides={[
        slide(t("mech.s1.title"), t("mech.s1.left"), t("mech.s1.right"), t("mech.s1.sub"), true),
        slide(t("mech.s2.title"), t("mech.s2.left"), t("mech.s2.right"), t("mech.s2.sub")),
        slide(t("mech.s3.title"), t("mech.s3.left"), t("mech.s3.right"), t("mech.s3.sub")),
        slide(t("mech.s4.title"), t("mech.s4.left"), t("mech.s4.right"), t("mech.s4.sub")),
      ]}
    />
  );
}
