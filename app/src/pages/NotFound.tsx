import { Link } from "react-router-dom";
import { useI18n } from "../i18n";

export default function NotFound() {
  const { t } = useI18n();
  return (
    <>
      <p className="eyebrow">404</p>
      <h1 className="plate-title" style={{ marginTop: 20 }}>
        {t("common.empty")}
      </h1>
      <Link className="aureus-btn" to="/" style={{ marginTop: 34 }}>
        Assay
      </Link>
    </>
  );
}
