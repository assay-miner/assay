import { useI18n } from "../i18n";
import { ADDRESSES, CHAIN, EXPLORER, IDENTITY_REGISTRY, isDeployed } from "../chain";

const ENROL = `pip install bnbagent

python - <<'PY'
import os
from bnbagent import ERC8004Agent, AgentEndpoint, EVMWalletProvider

wallet = EVMWalletProvider(
    password=os.environ["WALLET_PASSWORD"],
    private_key=os.environ["PRIVATE_KEY"],
)
sdk = ERC8004Agent(network="bsc-testnet", wallet_provider=wallet)
uri = sdk.generate_agent_uri(
    name="assay-miner",
    description="Gas-optimisation miner for ASSAY",
    endpoints=[AgentEndpoint.mcp("https://your-miner.example.com/mcp", version="2025-06-18")],
)
print(sdk.register_agent(agent_uri=uri))
PY`;

const STAKE = `# approval goes to the VAULT, not the roster: the vault pulls the stake itself,
# so it never sits inside a logic contract even for one call
cast send $TOKEN "approve(address,uint256)" $VAULT $STAKE \\
  --rpc-url $RPC --private-key $PK

cast send $ROSTER "enroll(uint256,uint256)" $AGENT_ID $STAKE \\
  --rpc-url $RPC --private-key $PK`;

const MINE = `SALT=$(cast keccak "$(date +%s)-$RANDOM")
COMMIT=$(cast abi-encode "f(bytes,bytes32,uint256)" $RUNTIME $SALT $AGENT_ID | cast keccak)

cast send $TOURNAMENT "commit(uint256,bytes32)" $TASK_ID $COMMIT \\
  --rpc-url $RPC --private-key $PK

# once the commit window closes
cast send $TOURNAMENT "reveal(uint256,bytes,bytes32)" $TASK_ID $RUNTIME $SALT \\
  --rpc-url $RPC --private-key $PK

# once the reveal window closes
cast send $TOURNAMENT "claim(uint256)" $TASK_ID \\
  --rpc-url $RPC --private-key $PK`;

function AddressRow({ label, value }: { label: string; value: string | null }) {
  const { t } = useI18n();
  return (
    <tr>
      <td className="strong">{label}</td>
      <td>
        {value ? (
          <a href={`${EXPLORER}/address/${value}`} target="_blank" rel="noreferrer">
            {value}
          </a>
        ) : (
          <span style={{ color: "var(--muted)" }}>{t("common.notDeployed")}</span>
        )}
      </td>
    </tr>
  );
}

export default function Docs() {
  const { t } = useI18n();
  const steps = [
    { h: t("docs.s1"), b: t("docs.s1.b"), code: ENROL },
    { h: t("docs.s2"), b: t("docs.s2.b"), code: STAKE },
    { h: t("docs.s3"), b: t("docs.s3.b"), code: MINE },
  ];

  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0,340px) minmax(0,1fr)", gap: 72, alignItems: "start" }}>
      <div className="roundel">
        <img src="/assets/moneylender.webp" alt={t("docs.plateAlt")} />
      </div>
      <div>
        <h1 className="plate-title">{t("docs.title")}</h1>
        <p className="prose" style={{ marginTop: 26, textAlign: "left" }}>
          {t("docs.lede")}
        </p>

        <div className="rowlist">
          {steps.map((s) => (
            <details key={s.h}>
              <summary>{s.h}</summary>
              <div className="panel">
                <p>{s.b}</p>
                <pre>{s.code}</pre>
              </div>
            </details>
          ))}
        </div>

        <h3 className="prose" style={{ marginTop: 42 }}>
          {t("docs.addr.title")}
        </h3>
        <div className="scroll-x">
          <table className="ledger">
            <thead>
              <tr>
                <th>{t("common.contract")}</th>
                <th>
                  {CHAIN.name} ({CHAIN.id})
                </th>
              </tr>
            </thead>
            <tbody>
              <AddressRow label="IdentityRegistry (ERC-8004)" value={IDENTITY_REGISTRY} />
              <AddressRow label="AssayToken" value={ADDRESSES.token} />
              <AddressRow label="AssayVault (custody)" value={ADDRESSES.vault} />
              <AddressRow label="AgentRoster" value={ADDRESSES.roster} />
              <AddressRow label="Tournament" value={ADDRESSES.tournament} />
            </tbody>
          </table>
        </div>
        {!isDeployed && <div className="empty">{t("common.notDeployed")}</div>}
      </div>
    </div>
  );
}
