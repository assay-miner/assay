import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";

export type Lang = "zh" | "en";

/**
 * Copy lives here rather than inline so the two languages cannot drift apart silently: a key
 * present in one dictionary and missing from the other is a type error, and `scripts/check-i18n`
 * fails the build on any user-visible string that never went through `t()`.
 */
const zh = {
  "nav.mechanism": "机制",
  "nav.tasks": "任务",
  "nav.docs": "接入",
  "nav.contact": "联系",
  "nav.switchTo": "EN",

  "common.notDeployed": "尚未部署",
  "common.empty": "链上暂无记录",
  "common.loading": "读取链上数据…",
  "common.contract": "合约",
  "common.miner": "矿工",
  "common.agentId": "AGENT ID",
  "common.task": "任务",
  "common.gas": "GAS",
  "common.score": "得分",

  "home.cta": "开始挖矿",
  "home.tagline": "为智能的产物做检定",
  "home.builtOn": "构建于",
  "home.seal1.name": "坩埚",
  "home.seal1.role": "链上执行提交物",
  "home.seal2.name": "计量",
  "home.seal2.role": "读取 GAS 表",
  "home.seal3.name": "印记",
  "home.seal3.role": "按幅度分配奖池",

  "foot.legal": "ASSAY PROTOCOL · BNB SMART CHAIN · 2026",

  "mech.coin1": "黄金",
  "mech.coin2": "石油",
  "mech.coin3": "GAS",

  "mech.s1.title": "工作必须能被便宜地验证",
  "mech.s1.left":
    "每一场工业革命都始于技术突破,成熟于金融市场。铁路从蒸汽机、轨道和时刻表开始,终于伦敦城里交易的债券。石油从井架开始,终于期货、租船合同和当时世界上最大的保险市场。它们成熟,不是因为有人造了更好的仓库,而是因为金融基础设施追上了实物资产——标准化的风险、指数、对冲,以及一个「出问题值多少钱」的价格。",
  "mech.s1.right":
    "所有自称 agent 挖矿的设计都死在同一个地方:agent 干的活没法被便宜地验证,于是退化成带故事的排放。ASSAY 只挖那种「做起来难、验起来便宜」的活。任务固定一组输入、每个输出的 keccak256、以及一个 gas 基准。矿工提交原始 EVM 运行时字节码,链把它部署、逐条跑完测试向量、读取计量表。没有预言机,没有委员会,没有验证人集合被要求发表意见。",
  "mech.s1.sub": "GAS 是下一个",

  "mech.s2.title": "坩埚",
  "mech.s2.left":
    "矿工提交的是原始 EVM 运行时字节码。合约把它包进一段固定的 14 字节前导码里部署,这段前导码只做一件事:把载荷复制进返回数据。攻击者因此完全没有部署期的执行窗口。之后提交物只会被带 gas 上限的 STATICCALL 触达。",
  "mech.s2.right":
    "它写不了存储、发不了日志、转不了钱、也自毁不了,更烧不掉超过上限的 gas。链上只存输出的哈希而不是输出本身,所以提交物无法从合约存储里读走答案——它必须真的算出原像。",
  "mech.s2.sub": "运行对手的代码是安全的",

  "mech.s3.title": "计量",
  "mech.s3.left":
    "gas 数字在 STATICCALL 前后紧贴着读取,在任何记账逻辑运行之前。所以记到矿工头上的,是他那份代码的成本加上一个调用操作码——对同一任务的每个矿工都是同一个常数。",
  "mech.s3.right":
    "得分 = 基准 gas ÷ 实测 gas,上限 32 倍。基准就是难度旋钮:打平或更差,得零分。奖池按得分占比分配,所以优化得越深,分到的越多。实测:6 个测试向量的一次链上检定花费 189,683 gas。",
  "mech.s3.sub": "得分 = 基准 ÷ 实测",

  "mech.s4.title": "印记",
  "mech.s4.left":
    "承诺哈希把 agentId 绑了进去。即使对手拿到你的字节码和盐,在他自己的身份下也算不出同一个承诺;而那时承诺窗口早就关了。抗女巫是两层的:ERC-8004 身份让每个矿工成为链上一等公民,在 BNB Chain 自己的 agent 浏览器里可见;质押让「为每次提交换一个新身份」变成真实的资本成本。",
  "mech.s4.right":
    "这套设计的诚实边界:任务由策展方发布。这是当前版本的中心化之处,我们不掩饰。验证核心不需要信任任何人,但「挖什么」目前需要。下一步是走 ERC-8183 托管路径,让任何人带赏金发任务,本合约作为交付评估方——验证核心一行都不用改。",
  "mech.s4.sub": "抄不走的解法",

  "tasks.title": "任务与矿工",
  "tasks.lede": "链上已发布的全部任务与得分提交。数据直接读自合约,没有中间层。空就是空,不做样例数据兜底。",
  "tasks.col.id": "编号",
  "tasks.col.vectors": "向量",
  "tasks.col.baseline": "基准 GAS",
  "tasks.col.gascap": "单向量上限",
  "tasks.col.pot": "奖池",
  "tasks.col.phase": "阶段",
  "tasks.col.rank": "名次",
  "tasks.phase.commit": "承诺中",
  "tasks.phase.reveal": "揭示中",
  "tasks.phase.settled": "已结算",
  "tasks.miners": "得分提交",

  "docs.title": "接入一共三步",
  "docs.lede":
    "矿工客户端跑在 Binance Agent OS 上,身份走 ERC-8004。身份 NFT 不必和挖矿热钱包在同一个地址——入册检查的是 isAuthorizedOrOwner,所以 NFT 可以留在冷钱包里。",
  "docs.plateAlt": "昆丁·马西斯《放债人与妻子》,1514 年",
  "docs.s1": "一 · 注册 ERC-8004 身份",
  "docs.s1.b": "用 BNB Chain 官方的 BNBAgent SDK 铸一个 agentId。这枚 ERC-721 就是你在 ASSAY 里的矿工身份。",
  "docs.s2": "二 · 入册并质押",
  "docs.s2.b": "把 agentId 绑定到你的挖矿地址。承诺会把质押锁到该轮结算之后,所以女巫成本是真实的。",
  "docs.s3": "三 · 承诺、揭示、领取",
  "docs.s3.b": "本地生成候选实现并自测,只把最优的那一份封进承诺;揭示窗口打开后交出原始字节码。",
  "docs.addr.title": "合约地址",

  "nav.vault": "金库",
  "vault.title": "自描述金库",
  "vault.eyebrow": "本页完全由链上 SCHEMA 生成",
  "vault.lede": "这一页没有一行是为 ASSAY 写的。它读取合约的 vaultUISchema(),然后照它说的渲染:返回数组的视图变成卡片列表,写方法变成卡片上的按钮。把它指向任何实现同一套 schema 的合约,它就渲染那一个。",
  "vault.readFrom": "读自",
  "vault.methods": "个方法",
  "vault.views": "读取项",
  "vault.actions": "写入动作",
  "vault.actionsNote": "输入框和按钮由 schema 的 inputs 逐字生成;字段类型决定控件形态。此处为只读预览,不连接钱包。",
  "vault.autoApprove": "UI 会先自动发起授权:",
  "vault.noSchema": "该合约没有暴露 vaultUISchema()",
  "vault.query": "查询",
  "vault.needsInput": "这个视图需要参数——填好上面的字段再查询",

  "contact.eyebrow1": "有一段字节码想被检定?",
  "contact.eyebrow2": "想发一道题?",
  "contact.title": "联系检定所",
  "contact.email": "邮件",
  "contact.repo": "SDK",
  "contact.select": "请选择",
  "contact.f.first": "名",
  "contact.f.last": "姓",
  "contact.f.org": "组织",
  "contact.f.role": "职务",
  "contact.f.kind": "身份",
  "contact.f.interest": "意向",
  "contact.f.email": "邮箱地址",
  "contact.f.agent": "AGENT ID",
  "contact.f.agentHint": "若已注册 ERC-8004 身份请填写",
  "contact.k1": "矿工 / 独立开发者",
  "contact.k2": "协议 / 团队",
  "contact.k3": "研究机构",
  "contact.i1": "参与挖矿",
  "contact.i2": "发布任务",
  "contact.i3": "集成对接",
  "contact.consent": "我同意 ASSAY 就检定与任务事宜与我联系。",
  "contact.submit": "提交",
} as const;

type Dict = Record<keyof typeof zh, string>;

const en: Dict = {
  "nav.mechanism": "Mechanism",
  "nav.tasks": "Tasks",
  "nav.docs": "Join",
  "nav.contact": "Contact",
  "nav.switchTo": "中文",

  "common.notDeployed": "Not deployed",
  "common.empty": "Nothing on chain yet",
  "common.loading": "Reading chain…",
  "common.contract": "Contract",
  "common.miner": "Miner",
  "common.agentId": "Agent ID",
  "common.task": "Task",
  "common.gas": "Gas",
  "common.score": "Score",

  "home.cta": "Start mining",
  "home.tagline": "Assaying the output of intelligence",
  "home.builtOn": "Built on",
  "home.seal1.name": "Crucible",
  "home.seal1.role": "Runs the submission on chain",
  "home.seal2.name": "Meter",
  "home.seal2.role": "Reads the gas",
  "home.seal3.name": "Hallmark",
  "home.seal3.role": "Splits the pot by margin",

  "foot.legal": "ASSAY PROTOCOL · BNB SMART CHAIN · 2026",

  "mech.coin1": "Gold",
  "mech.coin2": "Oil",
  "mech.coin3": "Gas",

  "mech.s1.title": "Work has to be cheap to check",
  "mech.s1.left":
    "Every industrial revolution starts with a technical breakthrough and matures inside financial markets. Rail began with steam engines, tracks and timetables and ended as bonds traded in the City of London. Oil began with derricks and ended as futures, charters, and the largest insurance market the world had seen. Neither matured because someone built a better warehouse. They matured when the financial infrastructure caught up with the physical asset: standardised risk, indices, hedges, a price for what could go wrong.",
  "mech.s1.right":
    "Every design that calls itself agent mining dies in the same place: the work an agent does cannot be verified cheaply, so it decays into emission with a story attached. ASSAY only mines work that is hard to do and cheap to check. A task fixes a set of inputs, the keccak256 of each output, and a gas baseline. Miners submit raw EVM runtime bytecode; the chain deploys it, runs every vector, and reads the meter. No oracle, no committee, no validator set is asked to have an opinion.",
  "mech.s1.sub": "Gas is next",

  "mech.s2.title": "The crucible",
  "mech.s2.left":
    "A miner submits raw EVM runtime bytecode. The contract wraps it in a fixed 14-byte prologue whose only job is to copy the payload into return data, so an attacker gets no deployment-time execution window at all. After that the submission is only ever reached through STATICCALL with a gas cap.",
  "mech.s2.right":
    "It cannot write storage, emit logs, move value or selfdestruct, and it cannot burn more than the cap. Only output hashes live on chain, never the outputs, so a submission cannot read the answer out of contract storage — it has to produce the preimage.",
  "mech.s2.sub": "Running a rival's code is safe",

  "mech.s3.title": "The meter",
  "mech.s3.left":
    "The gas figure is read immediately either side of the STATICCALL, before any bookkeeping runs. What is attributed to a miner is therefore the cost of their code plus one call opcode — the same constant for every miner on a task.",
  "mech.s3.right":
    "Score = baseline gas ÷ measured gas, capped at 32×. The baseline is the difficulty knob: matching it or doing worse scores zero. The pot splits by score share, so deeper optimisation is worth strictly more. Measured: one on-chain assay across six test vectors costs 189,683 gas.",
  "mech.s3.sub": "Score = baseline ÷ measured",

  "mech.s4.title": "The hallmark",
  "mech.s4.left":
    "The commitment hash binds the agentId. Even holding your bytecode and salt, a rival cannot produce the same commitment under their own identity — and by then the commit window has closed. Sybil resistance is two-layered: the ERC-8004 identity makes each miner a first-class on-chain agent, visible in BNB Chain's own agent explorers, and the stake makes minting a fresh identity per submission cost real capital.",
  "mech.s4.right":
    "Where this design is centralised: tasks are posted by a curator. That is the centralised part of this version and we are not hiding it. The verification core trusts nobody, but what gets mined currently does. The next step is the ERC-8183 escrow path — anyone posts a task with a bounty and this contract acts as the delivery evaluator. The verification core does not change to get there.",
  "mech.s4.sub": "A solution nobody can copy",

  "tasks.title": "Tasks and miners",
  "tasks.lede":
    "Every task posted on chain and every scoring submission, read straight from the contract with nothing in between. Empty means empty — there is no sample data standing in for it.",
  "tasks.col.id": "ID",
  "tasks.col.vectors": "Vectors",
  "tasks.col.baseline": "Baseline gas",
  "tasks.col.gascap": "Per-vector cap",
  "tasks.col.pot": "Pot",
  "tasks.col.phase": "Phase",
  "tasks.col.rank": "Rank",
  "tasks.phase.commit": "Committing",
  "tasks.phase.reveal": "Revealing",
  "tasks.phase.settled": "Settled",
  "tasks.miners": "Scoring submissions",

  "docs.title": "Three steps to join",
  "docs.lede":
    "The miner client runs on Binance Agent OS; identity is ERC-8004. The identity NFT does not need to sit on the same address as the mining hot key — enrolment checks isAuthorizedOrOwner, so the NFT can stay in cold storage.",
  "docs.plateAlt": "Quentin Matsys, The Moneylender and His Wife, 1514",
  "docs.s1": "One · Register an ERC-8004 identity",
  "docs.s1.b":
    "Mint an agentId with BNB Chain's own BNBAgent SDK. That ERC-721 is your miner identity in ASSAY.",
  "docs.s2": "Two · Enrol and stake",
  "docs.s2.b":
    "Bind the agentId to your mining address. Committing locks that stake past settlement, so the sybil cost is real.",
  "docs.s3": "Three · Commit, reveal, claim",
  "docs.s3.b":
    "Generate and self-test candidate implementations locally, seal only the best one, then hand over the raw bytecode once the reveal window opens.",
  "docs.addr.title": "Contract addresses",

  "nav.vault": "Vault",
  "vault.title": "Self-describing vault",
  "vault.eyebrow": "This page is generated from an on-chain schema",
  "vault.lede": "Not a line of this page was written for ASSAY. It reads the contract's vaultUISchema() and renders what it finds: a view that returns an array becomes a list of cards, and the write methods become the buttons on them. Point it at any contract implementing the same schema and it renders that one instead.",
  "vault.readFrom": "Read from",
  "vault.methods": "methods",
  "vault.views": "Readouts",
  "vault.actions": "Actions",
  "vault.actionsNote": "The fields and buttons come verbatim from the schema's inputs; the field type decides the widget. Read-only preview here — no wallet is connected.",
  "vault.autoApprove": "The UI sends this approve first:",
  "vault.noSchema": "This contract exposes no vaultUISchema()",
  "vault.query": "Query",
  "vault.needsInput": "This view takes an argument — fill the field above and query",

  "contact.eyebrow1": "Have bytecode to assay?",
  "contact.eyebrow2": "Want to post a task?",
  "contact.title": "Talk to the assay office",
  "contact.email": "Email",
  "contact.repo": "SDK",
  "contact.select": "Please select",
  "contact.f.first": "First name",
  "contact.f.last": "Last name",
  "contact.f.org": "Organisation",
  "contact.f.role": "Role",
  "contact.f.kind": "You are",
  "contact.f.interest": "Interest",
  "contact.f.email": "Email address",
  "contact.f.agent": "Agent ID",
  "contact.f.agentHint": "If you already hold an ERC-8004 identity",
  "contact.k1": "Miner / independent developer",
  "contact.k2": "Protocol / team",
  "contact.k3": "Research group",
  "contact.i1": "Mining",
  "contact.i2": "Posting tasks",
  "contact.i3": "Integration",
  "contact.consent": "I agree that ASSAY may contact me about assays and tasks.",
  "contact.submit": "Submit",
};

const DICTS: Record<Lang, Dict> = { zh, en };

/**
 * Versioned on purpose. An earlier build wrote the language on mount rather than on a click, so
 * every visitor ended up with a value stored whether or not they ever chose one — which then
 * outranked the site default forever and made changing that default a no-op for anyone who had
 * already loaded the page once. Bumping the key retires those non-choices; only a real click
 * writes to this one.
 */
const STORAGE_KEY = "assay.lang.v2";

type I18n = {
  lang: Lang;
  t: (key: keyof Dict) => string;
  toggle: () => void;
};

const Ctx = createContext<I18n | null>(null);

/** English is the default. Only a language the visitor actually picked outranks it. */
const DEFAULT_LANG: Lang = "en";

function initialLang(): Lang {
  if (typeof window === "undefined") return DEFAULT_LANG;
  const stored = window.localStorage.getItem(STORAGE_KEY);
  return stored === "en" || stored === "zh" ? stored : DEFAULT_LANG;
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLang] = useState<Lang>(initialLang);

  useEffect(() => {
    // Reflect the language, but do NOT persist here. Writing on mount would store a preference
    // nobody expressed, and that stored non-choice would then override the site default for good.
    // Drives the CJK tracking overrides in styles.css and tells assistive tech what it is reading.
    document.documentElement.setAttribute("lang", lang === "zh" ? "zh" : "en");
  }, [lang]);

  /** The only place a language is written down: an actual click. */
  const toggle = useCallback(() => {
    setLang((l) => {
      const next: Lang = l === "zh" ? "en" : "zh";
      window.localStorage.setItem(STORAGE_KEY, next);
      return next;
    });
  }, []);
  const t = useCallback((key: keyof Dict) => DICTS[lang][key], [lang]);

  const value = useMemo(() => ({ lang, t, toggle }), [lang, t, toggle]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n(): I18n {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useI18n must be used inside I18nProvider");
  return ctx;
}
