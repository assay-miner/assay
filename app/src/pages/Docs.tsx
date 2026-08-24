import { useI18n } from "../i18n";
import { ADDRESSES, CHAIN, EXPLORER, IDENTITY_REGISTRY, isDeployed } from "../chain";

function Code({ children }: { children: string }) {
  return (
    <pre
      className="plate mono scroll-x"
      style={{
        margin: 0,
        fontSize: "0.82em",
        lineHeight: 1.75,
        color: "var(--text-2)",
        whiteSpace: "pre",
      }}
    >
      {children}
    </pre>
  );
}

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

  const enrol = `# 1. mint an ERC-8004 identity with BNB Chain's own SDK
pip install bnbagent

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

  const stake = `# 2. bind that agentId to your mining address and stake
cast send $TOKEN "approve(address,uint256)" $ROSTER $STAKE \\
  --rpc-url $RPC --private-key $PK

cast send $ROSTER "enroll(uint256,uint256)" $AGENT_ID $STAKE \\
  --rpc-url $RPC --private-key $PK`;

  const mine = `# 3. seal the best implementation you found, then reveal it
SALT=$(cast keccak "$(date +%s)-$RANDOM")
COMMIT=$(cast abi-encode "f(bytes,bytes32,uint256)" $RUNTIME $SALT $AGENT_ID | cast keccak)

cast send $TOURNAMENT "commit(uint256,bytes32)" $TASK_ID $COMMIT \\
  --rpc-url $RPC --private-key $PK

# ... once the commit window closes ...
cast send $TOURNAMENT "reveal(uint256,bytes,bytes32)" $TASK_ID $RUNTIME $SALT \\
  --rpc-url $RPC --private-key $PK

# ... once the reveal window closes ...
cast send $TOURNAMENT "claim(uint256)" $TASK_ID \\
  --rpc-url $RPC --private-key $PK`;

  const steps = [
    { h: t("docs.s1"), b: t("docs.s1.b"), code: enrol },
    { h: t("docs.s2"), b: t("docs.s2.b"), code: stake },
    { h: t("docs.s3"), b: t("docs.s3.b"), code: mine },
  ];

  return (
    <>
      <section className="section">
        <div className="shell stack rise">
          <span className="label">{t("nav.docs")}</span>
          <h1 className="display display-xl">{t("docs.title")}</h1>
          <p className="lede">{t("docs.lede")}</p>
        </div>
      </section>

      <hr className="rule rule-gold" />

      <section className="section">
        <div className="shell stack-l">
          {steps.map((s) => (
            <div key={s.h} className="stack" style={{ gap: 14 }}>
              <h2 className="display display-m">{s.h}</h2>
              <p style={{ margin: 0 }}>{s.b}</p>
              <Code>{s.code}</Code>
            </div>
          ))}

          <hr className="rule" />

          <div className="stack" style={{ gap: 14 }}>
            <h2 className="display display-m">{t("docs.addr.title")}</h2>
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
                  <AddressRow label="AgentRoster" value={ADDRESSES.roster} />
                  <AddressRow label="Tournament" value={ADDRESSES.tournament} />
                </tbody>
              </table>
            </div>
            {!isDeployed && <div className="empty">{t("common.notDeployed")}</div>}
          </div>
        </div>
      </section>
    </>
  );
}
