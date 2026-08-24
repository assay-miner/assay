import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import {
  EXPLORER,
  formatScore,
  formatUnits,
  isDeployed,
  phaseOf,
  readScores,
  readTasks,
  shortAddress,
  type ScoreRow,
  type TaskRow,
} from "../chain";

export default function Tasks() {
  const { t } = useI18n();
  const [tasks, setTasks] = useState<TaskRow[] | null>(null);
  const [scores, setScores] = useState<ScoreRow[]>([]);
  const now = Math.floor(Date.now() / 1000);

  useEffect(() => {
    let live = true;
    (async () => {
      const rows = await readTasks();
      if (!live) return;
      setTasks(rows);
      const all = await Promise.all(rows.map((r) => readScores(r.id)));
      if (live) {
        setScores(all.flat().sort((a, b) => (b.score > a.score ? 1 : b.score < a.score ? -1 : 0)));
      }
    })().catch(() => live && setTasks([]));
    return () => {
      live = false;
    };
  }, []);

  const phase = {
    commit: t("tasks.phase.commit"),
    reveal: t("tasks.phase.reveal"),
    settled: t("tasks.phase.settled"),
  } as const;

  const state = !isDeployed
    ? t("common.notDeployed")
    : tasks === null
      ? t("common.loading")
      : tasks.length === 0
        ? t("common.empty")
        : null;

  return (
    <>
      <h1 className="plate-title">{t("tasks.title")}</h1>
      <p className="prose" style={{ marginTop: 26, textAlign: "left", maxWidth: "78ch" }}>
        {t("tasks.lede")}
      </p>

      {state ? (
        <div className="empty">{state}</div>
      ) : (
        <>
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
                </tr>
              </thead>
              <tbody>
                {tasks!.map((r) => (
                  <tr key={r.id.toString()}>
                    <td className="strong">#{r.id.toString()}</td>
                    <td>{r.vectorCount.toString()}</td>
                    <td className="strong">{r.baselineGas.toLocaleString()}</td>
                    <td>{r.gasCap.toLocaleString()}</td>
                    <td className="strong">{formatUnits(r.pot, 0)}</td>
                    <td>{phase[phaseOf(r, now)]}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h3 className="prose" style={{ marginTop: 46 }}>
            {t("tasks.miners")}
          </h3>
          {scores.length === 0 ? (
            <div className="empty">{t("common.empty")}</div>
          ) : (
            <div className="scroll-x">
              <table className="ledger">
                <thead>
                  <tr>
                    <th>{t("tasks.col.rank")}</th>
                    <th>{t("common.miner")}</th>
                    <th>{t("common.agentId")}</th>
                    <th>{t("common.task")}</th>
                    <th>{t("common.gas")}</th>
                    <th>{t("common.score")}</th>
                  </tr>
                </thead>
                <tbody>
                  {scores.map((s, i) => (
                    <tr key={`${s.taskId}-${s.miner}`}>
                      <td className="strong">{String(i + 1).padStart(2, "0")}</td>
                      <td>
                        <a href={`${EXPLORER}/address/${s.miner}`} target="_blank" rel="noreferrer">
                          {shortAddress(s.miner)}
                        </a>
                      </td>
                      <td>#{s.agentId.toString()}</td>
                      <td>#{s.taskId.toString()}</td>
                      <td className="strong">{s.gasUsed.toLocaleString()}</td>
                      <td className="strong">{formatScore(s.score)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}
