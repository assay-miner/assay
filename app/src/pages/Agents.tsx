import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import {
  EXPLORER,
  formatScore,
  isDeployed,
  readScores,
  readTasks,
  shortAddress,
  type ScoreRow,
} from "../chain";

export default function Agents() {
  const { t } = useI18n();
  const [rows, setRows] = useState<ScoreRow[] | null>(null);

  useEffect(() => {
    let live = true;
    (async () => {
      const tasks = await readTasks();
      const all = await Promise.all(tasks.map((task) => readScores(task.id)));
      // Flatten across tasks, best score first. A miner appears once per task they scored in.
      const flat = all.flat().sort((a, b) => (b.score > a.score ? 1 : b.score < a.score ? -1 : 0));
      if (live) setRows(flat);
    })().catch(() => live && setRows([]));
    return () => {
      live = false;
    };
  }, []);

  return (
    <>
      <section className="section">
        <div className="shell stack rise">
          <span className="label">{t("nav.agents")}</span>
          <h1 className="display display-xl">{t("agents.title")}</h1>
          <p className="lede">{t("agents.lede")}</p>
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
                    <th>{t("agents.col.rank")}</th>
                    <th>{t("common.miner")}</th>
                    <th>{t("common.agentId")}</th>
                    <th>{t("common.task")}</th>
                    <th>{t("common.gas")}</th>
                    <th>{t("common.score")}</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r, i) => (
                    <tr key={`${r.taskId}-${r.miner}`}>
                      <td className="strong">{String(i + 1).padStart(2, "0")}</td>
                      <td>
                        <a href={`${EXPLORER}/address/${r.miner}`} target="_blank" rel="noreferrer">
                          {shortAddress(r.miner)}
                        </a>
                      </td>
                      <td>#{r.agentId.toString()}</td>
                      <td>#{r.taskId.toString()}</td>
                      <td className="strong">{r.gasUsed.toLocaleString()}</td>
                      <td className="strong">{formatScore(r.score)}</td>
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
