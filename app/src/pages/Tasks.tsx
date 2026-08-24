import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import {
  EXPLORER,
  formatUnits,
  isDeployed,
  phaseOf,
  readTasks,
  shortAddress,
  type TaskRow,
} from "../chain";

export default function Tasks() {
  const { t } = useI18n();
  const [rows, setRows] = useState<TaskRow[] | null>(null);
  const now = Math.floor(Date.now() / 1000);

  useEffect(() => {
    let live = true;
    readTasks()
      .then((r) => live && setRows(r))
      .catch(() => live && setRows([]));
    return () => {
      live = false;
    };
  }, []);

  const phaseLabel = {
    commit: t("tasks.phase.commit"),
    reveal: t("tasks.phase.reveal"),
    settled: t("tasks.phase.settled"),
  } as const;

  return (
    <>
      <section className="section">
        <div className="shell stack rise">
          <span className="label">{t("nav.tasks")}</span>
          <h1 className="display display-xl">{t("tasks.title")}</h1>
          <p className="lede">{t("tasks.lede")}</p>
        </div>
      </section>
      <hr className="rule rule-gold" />
      <section className="section">
        <div className="shell">
          {!isDeployed ? (
            <div className="empty">{t("common.notDeployed")}</div>
          ) : rows === null ? (
            <div className="empty">{t("common.loading")}</div>
          ) : rows.length === 0 ? (
            <div className="empty">{t("common.empty")}</div>
          ) : (
            <div className="scroll-x">
              <table className="ledger">
                <thead>
                  <tr>
                    <th>{t("tasks.col.id")}</th>
                    <th>{t("tasks.col.vectors")}</th>
                    <th>{t("tasks.col.baseline")}</th>
                    <th>{t("tasks.col.gascap")}</th>
                    <th>{t("tasks.col.pot")}</th>
                    <th>{t("tasks.col.phase")}</th>
                    <th>{t("common.contract")}</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id.toString()}>
                      <td className="strong">#{r.id.toString()}</td>
                      <td>{r.vectorCount.toString()}</td>
                      <td className="strong">{r.baselineGas.toLocaleString()}</td>
                      <td>{r.gasCap.toLocaleString()}</td>
                      <td className="strong">{formatUnits(r.pot, 0)}</td>
                      <td>{phaseLabel[phaseOf(r, now)]}</td>
                      <td>
                        <a href={`${EXPLORER}/address/${r.poster}`} target="_blank" rel="noreferrer">
                          {shortAddress(r.poster)}
                        </a>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>
    </>
  );
}
