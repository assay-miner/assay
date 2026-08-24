import medallionSvg from "../generated/medallion.svg?raw";
import { useI18n } from "../i18n";

/** Static enquiry form. Nothing is wired to a backend yet, so it does not pretend to submit. */
export default function Contact() {
  const { t } = useI18n();

  const field = (label: string, req: boolean, node: React.ReactNode, hint?: string) => (
    <div className="field">
      <label>
        {label}
        {req && <span className="req">*</span>}
      </label>
      {node}
      {hint && <p className="hint">{hint}</p>}
    </div>
  );

  const select = (options: string[]) => (
    <select defaultValue="">
      <option value="">{t("contact.select")}</option>
      {options.map((o) => (
        <option key={o} value={o}>
          {o}
        </option>
      ))}
    </select>
  );

  return (
    <div className="cols-2" style={{ marginTop: 12, gap: 90 }}>
      <div>
        <p className="eyebrow">{t("contact.eyebrow1")}</p>
        <p className="eyebrow">{t("contact.eyebrow2")}</p>
        <h1 className="plate-title" style={{ marginTop: 32 }}>
          {t("contact.title")}
        </h1>

        <table className="ledger" style={{ marginTop: 44, maxWidth: 420 }}>
          <tbody>
            <tr>
              <td style={{ color: "var(--text-3)" }}>{t("contact.email")}</td>
              <td>
                <a href="mailto:assay@assay.build">assay@assay.build</a>
              </td>
            </tr>
            <tr>
              <td style={{ color: "var(--text-3)" }}>{t("contact.repo")}</td>
              <td>
                <a href="https://github.com/bnb-chain/bnbagent-sdk" target="_blank" rel="noreferrer">
                  bnb-chain/bnbagent-sdk
                </a>
              </td>
            </tr>
          </tbody>
        </table>

        <div
          style={{ width: 210, height: 210, marginTop: 56 }}
          dangerouslySetInnerHTML={{ __html: medallionSvg }}
        />
      </div>

      <form onSubmit={(e) => e.preventDefault()}>
        <div className="field-grid">
          {field(t("contact.f.first"), true, <input type="text" autoComplete="given-name" />)}
          {field(t("contact.f.last"), true, <input type="text" autoComplete="family-name" />)}
          {field(t("contact.f.org"), true, <input type="text" autoComplete="organization" />)}
          {field(t("contact.f.role"), true, <input type="text" />)}
          {field(t("contact.f.kind"), true, select([t("contact.k1"), t("contact.k2"), t("contact.k3")]))}
          {field(t("contact.f.interest"), true, select([t("contact.i1"), t("contact.i2"), t("contact.i3")]))}
          {field(t("contact.f.email"), true, <input type="email" autoComplete="email" />)}
          {field(t("contact.f.agent"), false, <input type="text" placeholder="agentId" />, t("contact.f.agentHint"))}
        </div>

        <label className="consent">
          <input type="checkbox" />
          {t("contact.consent")}
        </label>

        <button className="aureus-btn" type="submit" style={{ marginTop: 34 }}>
          {t("contact.submit")} →
        </button>
      </form>
    </div>
  );
}
