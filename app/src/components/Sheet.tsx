import { NavLink, Link, Outlet } from "react-router-dom";
import type { ReactNode } from "react";
import medallionSvg from "../generated/medallion.svg?raw";
import { useI18n } from "../i18n";

/** The hallmark reduced to a glyph, for the inner-page bar. */
function Glyph() {
  return (
    <Link to="/" className="sheet-glyph" aria-label="Assay">
      <span dangerouslySetInnerHTML={{ __html: medallionSvg }} />
    </Link>
  );
}

const NAV = [
  { to: "/mechanism", key: "nav.mechanism" },
  { to: "/tasks", key: "nav.tasks" },
  { to: "/docs", key: "nav.docs" },
  { to: "/contact", key: "nav.contact" },
] as const;

/** Inner-page chrome: hairline frame inset from the viewport, glyph left, nav right. */
export default function Sheet({ children }: { children?: ReactNode }) {
  const { t, toggle } = useI18n();
  return (
    <div className="sheet">
      <div className="sheet-frame" />
      <header className="sheet-bar">
        <Glyph />
        <nav className="sheet-nav">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} className={({ isActive }) => (isActive ? "active" : "")}>
              {t(n.key)}
            </NavLink>
          ))}
          <button className="lang-toggle" style={{ position: "static" }} onClick={toggle}>
            {t("nav.switchTo")}
          </button>
        </nav>
      </header>
      <main className="sheet-body">{children ?? <Outlet />}</main>
    </div>
  );
}
