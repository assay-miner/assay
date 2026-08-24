import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import heroSvg from "../generated/hero.svg?raw";
import medallionSvg from "../generated/medallion.svg?raw";
import { useI18n } from "../i18n";
import { useRetype } from "../useRetype";

/**
 * One screen, welded to the plate.
 *
 * The engraving underneath is a 2000x1080 SVG drawn at `object-fit: cover`; every element on top
 * of it is positioned in plate coordinates via `--u`, so the lockup keeps sitting inside the
 * engraved oval whatever the window is doing. It is inlined rather than served as an <img>
 * because the retype animation has to reach the individual <text> nodes inside it.
 */

/** Plate x-coordinates for the three seals struck along the bottom of the engraving. */
const SEAL_X = [620, 1000, 1380] as const;

export default function Home() {
  const { t, toggle } = useI18n();
  const plateRef = useRef<HTMLDivElement>(null);
  const [svgEl, setSvgEl] = useState<SVGSVGElement | null>(null);

  useEffect(() => {
    document.body.classList.add("home");
    return () => document.body.classList.remove("home");
  }, []);

  useEffect(() => {
    setSvgEl(plateRef.current?.querySelector("svg") ?? null);
  }, []);

  useRetype(svgEl);

  const nav = (
    <>
      <Link to="/mechanism">{t("nav.mechanism")}</Link>
      <span className="sep">—</span>
      <Link to="/tasks">{t("nav.tasks")}</Link>
      <span className="sep">—</span>
      <Link to="/vault">{t("nav.vault")}</Link>
      <span className="sep">—</span>
      <Link to="/docs">{t("nav.docs")}</Link>
      <span className="sep">—</span>
      <Link to="/contact">{t("nav.contact")}</Link>
    </>
  );

  return (
    <>
      {/* --- desktop: the plate --- */}
      <div
        className="hero"
        aria-hidden="true"
        ref={plateRef}
        dangerouslySetInnerHTML={{ __html: heroSvg }}
      />

      <button className="lang-toggle" onClick={toggle}>
        {t("nav.switchTo")}
      </button>

      <Link className="aureus-btn demo-cta" to="/docs">
        {t("home.cta")}
      </Link>

      <div className="hero-mark" dangerouslySetInnerHTML={{ __html: medallionSvg }} />

      <div className="hero-stack">
        <h1 className="hero-word">Assay</h1>
        <p className="hero-tagline">{t("home.tagline")}</p>
        <nav className="bond-nav">{nav}</nav>
        <div className="endorsements">
        <p className="caption">{t("home.builtOn")}</p>
        <div className="row">
          <span className="chip" title="BNB Smart Chain">
            BNB
          </span>
          <span className="chip" title="ERC-8004 Agent Identity">
            8004
          </span>
          <span className="chip" title="Binance Agent OS">
            MCP
          </span>
          </div>
        </div>
      </div>

      <div className="seals">
        {(
          [
            [t("home.seal1.name"), t("home.seal1.role")],
            [t("home.seal2.name"), t("home.seal2.role")],
            [t("home.seal3.name"), t("home.seal3.role")],
          ] as const
        ).map(([name, role], i) => (
          <div key={name} className="seal" style={{ "--cx": SEAL_X[i] } as React.CSSProperties}>
            <span className="seal-ink">{name}</span>
            <span className="seal-role">{role}</span>
          </div>
        ))}
      </div>

      <p className="hero-foot">{t("foot.legal")}</p>

      {/* --- mobile: its own composition; the plate cannot letterbox onto a phone --- */}
      <div className="mobile-home">
        <div className="m-frame" />
        <div className="m-mark" dangerouslySetInnerHTML={{ __html: medallionSvg }} />
        <h1 className="m-word">Assay</h1>
        <p className="m-tagline">{t("home.tagline")}</p>
        <nav className="m-nav">
          <Link to="/mechanism">{t("nav.mechanism")}</Link>
          <Link to="/tasks">{t("nav.tasks")}</Link>
          <Link to="/vault">{t("nav.vault")}</Link>
          <Link to="/docs">{t("nav.docs")}</Link>
          <Link to="/contact">{t("nav.contact")}</Link>
        </nav>
        <p className="m-foot">{t("foot.legal")}</p>
      </div>
    </>
  );
}
