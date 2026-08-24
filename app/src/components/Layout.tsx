import { NavLink, Link, Outlet } from "react-router-dom";
import { useI18n } from "../i18n";
import { CHAIN } from "../chain";

/**
 * The hallmark. An assay office stamps a mark into metal it has tested; this is that mark —
 * a shield around a crucible, drawn once and reused at every size.
 */
export function Hallmark({ size = 22 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d="M16 2.2 28 7v9.4c0 6.4-4.9 11.4-12 13.4C8.9 27.8 4 22.8 4 16.4V7l12-4.8Z"
        stroke="var(--gold)"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
      <path d="M10.4 11h11.2l-2 7.6a3.8 3.8 0 0 1-3.6 2.8h0a3.8 3.8 0 0 1-3.6-2.8L10.4 11Z" stroke="var(--gold-bright)" strokeWidth="1.1" strokeLinejoin="round" />
      <path d="M13.4 7.4V10M16 6.2V10M18.6 7.4V10" stroke="var(--gold-deep)" strokeWidth="1.1" strokeLinecap="round" />
    </svg>
  );
}

const NAV = [
  { to: "/mining", key: "nav.mining" },
  { to: "/tasks", key: "nav.tasks" },
  { to: "/agents", key: "nav.agents" },
  { to: "/docs", key: "nav.docs" },
  { to: "/faq", key: "nav.faq" },
] as const;

export default function Layout() {
  const { t, lang, toggle } = useI18n();

  return (
    <div className="field">
      <header className="bar">
        <div className="shell bar-inner">
          <Link to="/" className="wordmark">
            <Hallmark />
            Assay
          </Link>
          <nav className="nav">
            {NAV.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                className={({ isActive }) => (isActive ? "active" : undefined)}
              >
                {t(item.key)}
              </NavLink>
            ))}
            <button className="lang" onClick={toggle} aria-label="Switch language">
              {lang === "zh" ? "EN" : "中文"}
            </button>
          </nav>
        </div>
      </header>

      <main>
        <Outlet />
      </main>

      <footer className="foot">
        <div className="shell stack">
          <div className="grid-2">
            <div className="stack">
              <span className="wordmark" style={{ color: "var(--text-2)" }}>
                <Hallmark size={18} />
                Assay
              </span>
              <p className="label label-muted" style={{ letterSpacing: "0.14em" }}>
                {t("foot.built")}
              </p>
            </div>
            <div className="stack">
              <span className="label label-muted">
                {t("common.chain")} · {CHAIN.name} ({CHAIN.id})
              </span>
              <span className="label label-muted" style={{ letterSpacing: "0.1em" }}>
                {t("foot.disclaimer")}
              </span>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}
