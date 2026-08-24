import { Link } from "react-router-dom";
import { useI18n } from "../i18n";

export default function NotFound() {
  const { t } = useI18n();
  return (
    <section className="section">
      <div className="shell stack">
        <span className="label">404</span>
        <h1 className="display display-l">{t("common.empty")}</h1>
        <Link className="btn btn-quiet" to="/">
          Assay
        </Link>
      </div>
    </section>
  );
}
