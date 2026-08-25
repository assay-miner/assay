import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { LiveCell, Skeleton, usePolled } from "../components/Live";
import { EXPLORER, SCHEMA_TARGET, isDeployed, shortAddress } from "../chain";
import {
  callMethod,
  formatCell,
  readBanner,
  readSchema,
  type MethodSchema,
  type UISchema,
} from "../schema";

/**
 * A page built entirely from what the contract says about itself.
 *
 * Nothing here is written against ASSAY. It reads `vaultUISchema()`, then renders whatever it
 * finds: a view returning an array becomes a list of cards, the write methods become the buttons
 * on them, and a scalar view becomes a readout. Point it at a different contract implementing the
 * same schema and it renders that instead — which is the whole argument for describing an
 * interface on chain rather than shipping a bespoke frontend for every new vault.
 */

/** Inputs the renderer can fill on its own. Anything else has to be asked for. */
const INFERABLE = new Set(["offset", "limit"]);

/** A view whose output is an array — the thing that turns a page into cards. */
function CardList({ method, viewer }: { method: MethodSchema; viewer: string }) {
  const { t } = useI18n();
  const [page, setPage] = useState(0);
  const PER = 4;

  // The spec's rule: a view with inputs the page cannot supply gets input fields and a Query
  // button. Pagination and the viewer's own address are inferable; a task id is not, so it is
  // asked for rather than silently defaulted to zero — which is how this rendered an empty
  // leaderboard over a task that had a miner in it.
  const asked = method.inputs.filter(
    (f) => !INFERABLE.has(f.name) && f.fieldType !== "address",
  );
  const [entered, setEntered] = useState<Record<string, string>>(
    Object.fromEntries(asked.map((f) => [f.name, ""])),
  );
  const [queryKey, setQueryKey] = useState(0);
  const ready = asked.every((f) => entered[f.name]?.trim() !== "");

  const argsFor = (offset: number) =>
    method.inputs.map((f) => {
      if (f.fieldType === "address") return viewer;
      if (f.name === "offset") return BigInt(offset * PER);
      if (f.name === "limit") return BigInt(PER);
      const raw = entered[f.name]?.trim();
      return raw ? BigInt(raw) : 0n;
    });

  // Polled, not read once. A tournament moves between phases while somebody is looking at it,
  // and a page that froze at first paint would quietly show a closed window as still open.
  const { value: rows, pulse } = usePolled(
    async () => (ready ? await callMethod(method, argsFor(page)) : []),
    [method.name, page, viewer, queryKey, ready],
    6000,
  );

  return (
    <section className="schema-block">
      <div className="schema-head">
        <h2 className="display-m">{method.name}</h2>
        <p className="schema-desc">{method.description}</p>
      </div>

      {asked.length > 0 && (
        <div className="query-row">
          {asked.map((f) => (
            <label key={f.name} className="write-field">
              <span title={f.description}>
                {f.name} <em>{f.fieldType}</em>
              </span>
              <input
                type="text"
                inputMode="numeric"
                value={entered[f.name] ?? ""}
                placeholder={f.fieldType}
                onChange={(e) => setEntered((s) => ({ ...s, [f.name]: e.target.value }))}
              />
            </label>
          ))}
          <button
            className="aureus-btn"
            disabled={!ready}
            onClick={() => {
              setPage(0);
              setQueryKey((k) => k + 1);
            }}
          >
            {t("vault.query")}
          </button>
        </div>
      )}

      {!ready ? (
        <div className="empty">{t("vault.needsInput")}</div>
      ) : rows === null ? (
        <Skeleton rows={3} />
      ) : rows.length === 0 ? (
        <div className="empty">{t("common.empty")}</div>
      ) : (
        <div className="card-grid" key={`${page}-${queryKey}`}>
          {rows.map((row, i) => (
            <article
              key={i}
              className="plate-card is-live"
              style={{ animationDelay: `${i * 70}ms` }}
            >
              <span className="live-dot" aria-hidden="true" />
              <dl>
                {method.outputs.map((f, j) => (
                  <div key={f.name} className="kv">
                    <dt title={f.description}>{f.name}</dt>
                    <dd>
                      <LiveCell value={row[j]} field={f} text={formatCell(row[j], f)} />
                    </dd>
                  </div>
                ))}
              </dl>
            </article>
          ))}
        </div>
      )}

      <div className="pager">
        <span className={pulse > 0 ? "poll-mark is-on" : "poll-mark"} aria-hidden="true" />
        <button className="pager-btn" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>
          ‹
        </button>
        <span className="pager-n">{page + 1}</span>
        <button
          className="pager-btn"
          disabled={(rows?.length ?? 0) < PER}
          onClick={() => setPage((p) => p + 1)}
        >
          ›
        </button>
      </div>
    </section>
  );
}

/** A write method — rendered as the form and button the schema describes. */
function WriteForm({ method }: { method: MethodSchema }) {
  const { t } = useI18n();
  return (
    <article className="plate-card write-card">
      <div className="schema-head">
        <h3 className="display-m">{method.name}</h3>
        <p className="schema-desc">{method.description}</p>
      </div>
      <div className="write-fields">
        {method.inputs.map((f) => (
          <label key={f.name} className="write-field">
            <span title={f.description}>
              {f.name} <em>{f.fieldType}</em>
            </span>
            <input type="text" placeholder={f.fieldType} disabled />
          </label>
        ))}
      </div>
      {method.approvals.length > 0 && (
        <p className="approve-note">
          {t("vault.autoApprove")} <code>{method.approvals[0].tokenType}</code> ·{" "}
          <code>{method.approvals[0].amountFieldName}</code>
        </p>
      )}
      <button className="aureus-btn" disabled>
        {method.name} →
      </button>
    </article>
  );
}

/** A view with scalar outputs — a plain readout. */
function Readout({ method, viewer }: { method: MethodSchema; viewer: string }) {
  const { value: row } = usePolled(
    async () => {
      const args = method.inputs.map((f) => (f.fieldType === "address" ? viewer : 0n));
      return (await callMethod(method, args))[0] ?? [];
    },
    [method.name, viewer],
    8000,
  );

  return (
    <article className="plate-card is-live">
      <span className="live-dot" aria-hidden="true" />
      <div className="schema-head">
        <h3 className="display-m">{method.name}</h3>
        <p className="schema-desc">{method.description}</p>
      </div>
      <dl>
        {method.outputs.map((f, j) => (
          <div key={f.name} className="kv">
            <dt title={f.description}>{f.name}</dt>
            <dd>
              {row ? <LiveCell value={row[j]} field={f} text={formatCell(row[j], f)} /> : "…"}
            </dd>
          </div>
        ))}
      </dl>
    </article>
  );
}

const ZERO = "0x0000000000000000000000000000000000000000";

export default function Vault() {
  const { t } = useI18n();
  const [schema, setSchema] = useState<UISchema | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let live = true;
    readSchema()
      .then((s) => live && setSchema(s))
      .catch(() => live && setFailed(true));
    return () => {
      live = false;
    };
  }, []);

  // The schema spec asks for description() to be polled as a live status banner, so it is.
  const { value: banner } = usePolled(readBanner, [], 5000);

  if (!isDeployed) {
    return (
      <>
        <h1 className="plate-title">{t("vault.title")}</h1>
        <p className="prose" style={{ marginTop: 26, textAlign: "left", maxWidth: "78ch" }}>
          {t("vault.lede")}
        </p>
        <div className="empty">{t("common.notDeployed")}</div>
      </>
    );
  }

  if (failed) {
    return (
      <>
        <h1 className="plate-title">{t("vault.title")}</h1>
        <div className="empty">{t("vault.noSchema")}</div>
      </>
    );
  }

  if (!schema) {
    return (
      <>
        <h1 className="plate-title">{t("vault.title")}</h1>
        <div className="empty">{t("common.loading")}</div>
      </>
    );
  }

  const arrays = schema.methods.filter((m) => m.isOutputArray);
  const writes = schema.methods.filter((m) => m.isWriteMethod);
  const scalars = schema.methods.filter((m) => !m.isOutputArray && !m.isWriteMethod);

  return (
    <>
      <p className="eyebrow">{t("vault.eyebrow")}</p>
      <h1 className="plate-title" style={{ marginTop: 16 }}>
        {schema.vaultType}
      </h1>
      <p className="prose" style={{ marginTop: 22, textAlign: "left", maxWidth: "86ch" }}>
        {schema.description}
      </p>
      {banner && (
        <p className="banner" key={banner}>
          <span className="banner-pip" aria-hidden="true" />
          {banner}
        </p>
      )}
      <p className="schema-src">
        {t("vault.readFrom")}{" "}
        <a href={`${EXPLORER}/address/${SCHEMA_TARGET}`} target="_blank" rel="noreferrer">
          {shortAddress(SCHEMA_TARGET ?? ZERO)}
        </a>{" "}
        · vaultUISchema() · {schema.methods.length} {t("vault.methods")}
      </p>

      {arrays.map((m) => (
        <CardList key={m.name} method={m} viewer={ZERO} />
      ))}

      {scalars.length > 0 && (
        <section className="schema-block">
          <h2 className="display-m">{t("vault.views")}</h2>
          <div className="card-grid">
            {scalars.map((m) => (
              <Readout key={m.name} method={m} viewer={ZERO} />
            ))}
          </div>
        </section>
      )}

      <section className="schema-block">
        <h2 className="display-m">{t("vault.actions")}</h2>
        <p className="schema-desc">{t("vault.actionsNote")}</p>
        <div className="card-grid">
          {writes.map((m) => (
            <WriteForm key={m.name} method={m} />
          ))}
        </div>
      </section>
    </>
  );
}
