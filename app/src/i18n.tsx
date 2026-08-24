import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";

export type Lang = "zh" | "en";

/**
 * Copy lives here rather than inline so the two languages cannot drift apart silently: a key
 * present in one dictionary and missing from the other is a type error.
 */
const zh = {
  "nav.mining": "机制",
  "nav.tasks": "任务",
  "nav.agents": "矿工",
  "nav.docs": "文档",
  "nav.faq": "问答",
  "nav.enter": "开始挖矿",
  "nav.switchTo": "EN",

  "common.notDeployed": "尚未部署",
  "common.empty": "链上暂无记录",
  "common.loading": "读取链上数据…",
  "common.chain": "网络",
  "common.contract": "合约",
  "common.gas": "GAS",
  "common.score": "得分",
  "common.miner": "矿工",
  "common.agentId": "AGENT ID",
  "common.status": "状态",
  "common.baseline": "基准",
  "common.pot": "奖池",
  "common.task": "任务",
  "common.readMore": "了解机制",

  "home.eyebrow": "可验证的 AGENT 挖矿 · BNB SMART CHAIN",
  "home.title": "把工作交给链去检定",
  "home.lede":
    "ASSAY 是一套完全在链上结算的优化锦标赛。任务固定一组输入和每个输入必须产出的输出哈希,并给出一个 gas 基准。矿工提交原始 EVM 运行时字节码,链把它部署、跑完全部测试向量、读取计量表。跑赢基准的,按赢的幅度分走奖池。",
  "home.ctaPrimary": "开始挖矿",
  "home.ctaSecondary": "阅读机制",

  "home.claim1.label": "工作是难的",
  "home.claim1.body":
    "写出既算对又比参考实现更省 gas 的字节码,是真实的优化劳动。没有预言机、委员会或验证人集合被要求对它发表意见。",
  "home.claim2.label": "验证是便宜的",
  "home.claim2.body":
    "N 次 STATICCALL 加一次比较,没有共识轮次。检定一份提交物的成本,和它值多少钱无关。",
  "home.claim3.label": "作弊是不可用的",
  "home.claim3.body":
    "链上只存输出的哈希,答案无法从存储里抄出来;承诺在任何提交物揭示之前就已封存,答案也无法从对手那里抄。",

  "home.loop.title": "一轮的样子",
  "home.loop.s1.t": "注册身份",
  "home.loop.s1.b": "矿工在 ERC-8004 身份注册表上铸造 agentId,并质押。身份 NFT 可以留在冷钱包——入册检查的是授权,不是持有。",
  "home.loop.s2.t": "封存承诺",
  "home.loop.s2.b": "提交 keccak256(字节码, 盐, agentId)。承诺窗口关闭之前,没有人看得到任何人的解法。",
  "home.loop.s3.t": "揭示与检定",
  "home.loop.s3.b": "揭示原始运行时字节码。合约无构造函数地部署它,逐条跑测试向量,读取 gas 计量。",
  "home.loop.s4.t": "结算",
  "home.loop.s4.b": "得分 = 基准 gas ÷ 实测 gas。没跑赢基准的得零分。奖池按得分份额分配。",

  "home.stats.title": "链上实时",
  "home.stats.tasks": "已发布任务",
  "home.stats.supply": "总量",
  "home.stats.minStake": "最低质押",
  "home.stats.registry": "身份注册表",

  "mining.title": "机制",
  "mining.lede":
    "所有号称 agent 挖矿的设计都死在同一个地方:agent 干的活没法被便宜地验证,于是退化成带故事的排放。ASSAY 的做法是只挖那种「做起来难、验起来便宜」的活。",
  "mining.h.task": "任务由什么构成",
  "mining.p.task":
    "一个任务是三样东西:一组调用数据输入、每个输入对应的输出 keccak256 哈希、以及一个 gas 基准。注意链上存的是输出的哈希而不是输出本身——提交物必须真的算出原像,不能从合约存储里读走答案。",
  "mining.h.crucible": "坩埚",
  "mining.p.crucible":
    "矿工提交的是原始 EVM 运行时字节码。合约把它包进一段固定的 14 字节前导码里部署,这段前导码只做一件事:把载荷复制进返回数据。攻击者因此完全没有部署期的执行窗口。之后提交物只会被带 gas 上限的 STATICCALL 触达,它写不了存储、发不了日志、转不了钱、也自毁不了。",
  "mining.h.meter": "计量",
  "mining.p.meter":
    "gas 数字在 STATICCALL 前后紧贴着读取,在任何记账逻辑运行之前。所以记到矿工头上的,是他那份代码的成本加上一个调用操作码——对同一任务的每个矿工都是同一个常数。",
  "mining.h.score": "记分",
  "mining.p.score":
    "得分 = 基准 gas ÷ 实测 gas,上限 32 倍。基准就是难度旋钮:打平或更差,得零分。奖池按得分占比分配,所以优化得越深,分到的越多。",
  "mining.h.sybil": "抗女巫",
  "mining.p.sybil":
    "两层。ERC-8004 身份让每个矿工成为链上一等公民,在 BNB Chain 自己的 agent 浏览器里可见;质押让「为每次提交换一个新身份」变成真实的资本成本。承诺会把质押锁到该轮结算之后。",
  "mining.h.honest": "这套设计的诚实边界",
  "mining.p.honest":
    "任务由策展方发布。这是当前版本的中心化之处,也是我们不掩饰的地方:验证核心不需要信任任何人,但「挖什么」目前需要。下一步是走 ERC-8183 托管路径,让任何人带赏金发任务,本合约作为交付评估方——验证核心一行都不用改。",

  "tasks.title": "任务",
  "tasks.lede": "链上已发布的全部任务。数据直接读自合约,没有中间层。",
  "tasks.col.id": "编号",
  "tasks.col.vectors": "向量",
  "tasks.col.baseline": "基准 GAS",
  "tasks.col.gascap": "单向量上限",
  "tasks.col.pot": "奖池",
  "tasks.col.phase": "阶段",
  "tasks.phase.commit": "承诺中",
  "tasks.phase.reveal": "揭示中",
  "tasks.phase.settled": "已结算",

  "agents.title": "矿工",
  "agents.lede": "按任务列出的得分提交。得分越高代表用更少的 gas 算出了同样正确的答案。",
  "agents.col.rank": "名次",

  "docs.title": "文档",
  "docs.lede": "接入一共三步。矿工客户端跑在 Binance Agent OS 上,身份走 ERC-8004。",
  "docs.s1": "一 · 注册 ERC-8004 身份",
  "docs.s1.b": "用 BNB Chain 官方的 BNBAgent SDK 铸一个 agentId。这枚 ERC-721 就是你在 ASSAY 里的矿工身份。",
  "docs.s2": "二 · 入册并质押",
  "docs.s2.b": "把 agentId 绑定到你的挖矿地址。身份 NFT 不必和挖矿热钱包在同一个地址——入册检查的是 isAuthorizedOrOwner。",
  "docs.s3": "三 · 承诺、揭示、领取",
  "docs.s3.b": "本地生成候选实现并自测,只把最优的那一份封进承诺;揭示窗口打开后交出原始字节码。",
  "docs.addr.title": "合约地址",

  "faq.title": "问答",
  "faq.q1": "这和别的「AI agent 挖矿」代币有什么不同?",
  "faq.a1":
    "差别只有一条:验证。绝大多数同类项目的代币合约里,根本没有任何 agent 或挖矿逻辑——挖矿只活在文案层。ASSAY 的奖励由链亲自执行你提交的代码后决定,没有人可以代替链形成意见。",
  "faq.q2": "为什么用 gas 优化作为挖矿标的?",
  "faq.a2":
    "因为它是 EVM 上少见的、天然不对称的问题:做出来很难,验起来只要跑一遍读表。而且答案是客观的,不需要预言机,也不会有争议。",
  "faq.q3": "运行别人提交的字节码不危险吗?",
  "faq.a3":
    "提交物没有构造函数执行窗口,且只会被带 gas 上限的 STATICCALL 触达。它无法写存储、发日志、转账或自毁,也烧不掉超过上限的 gas。",
  "faq.q4": "对手能抄我的解法吗?",
  "faq.a4":
    "不能。承诺哈希把 agentId 绑了进去,所以即使他拿到你的字节码和盐,在他自己的 agentId 下也算不出同一个承诺;而那时承诺窗口早就关了。",
  "faq.q5": "代币会增发吗?",
  "faq.a5": "不会。除构造函数外没有任何铸造入口,也没有 owner。奖励来自预先注入的储备,不是通胀。",

  "foot.built": "构建于 BNB Smart Chain · ERC-8004 身份 · Binance Agent OS",
  "foot.disclaimer": "实验性软件。合约未经第三方审计。测试网优先。",
} as const;

type Dict = Record<keyof typeof zh, string>;

const en: Dict = {
  "nav.mining": "Mechanism",
  "nav.tasks": "Tasks",
  "nav.agents": "Miners",
  "nav.docs": "Docs",
  "nav.faq": "FAQ",
  "nav.enter": "Start mining",
  "nav.switchTo": "中文",

  "common.notDeployed": "Not deployed",
  "common.empty": "Nothing on chain yet",
  "common.loading": "Reading chain…",
  "common.chain": "Network",
  "common.contract": "Contract",
  "common.gas": "GAS",
  "common.score": "Score",
  "common.miner": "Miner",
  "common.agentId": "Agent ID",
  "common.status": "Status",
  "common.baseline": "Baseline",
  "common.pot": "Pot",
  "common.task": "Task",
  "common.readMore": "Read the mechanism",

  "home.eyebrow": "Verifiable agent mining · BNB Smart Chain",
  "home.title": "Let the chain assay the work",
  "home.lede":
    "ASSAY is an optimisation tournament settled entirely on chain. A task fixes a set of inputs, the hash of the output each must produce, and a gas baseline. Miners submit raw EVM runtime bytecode; the chain deploys it, runs every vector, and reads the meter. Beating the baseline earns a share of the pot in proportion to how far it was beaten.",
  "home.ctaPrimary": "Start mining",
  "home.ctaSecondary": "Read the mechanism",

  "home.claim1.label": "The work is hard",
  "home.claim1.body":
    "Writing bytecode that computes the right answer in less gas than the reference is genuine optimisation effort. No oracle, committee, or validator set is asked to have an opinion about it.",
  "home.claim2.label": "Verification is cheap",
  "home.claim2.body":
    "N STATICCALLs and a comparison — no consensus round. What it costs to assay a submission has nothing to do with what that submission is worth.",
  "home.claim3.label": "Cheating is not available",
  "home.claim3.body":
    "Only output hashes live on chain, so an answer cannot be copied out of storage; and commitments are sealed before any submission is revealed, so it cannot be copied off a competitor either.",

  "home.loop.title": "What one round looks like",
  "home.loop.s1.t": "Register an identity",
  "home.loop.s1.b":
    "Mint an agentId on the ERC-8004 Identity Registry and stake. The identity NFT can stay in cold storage — enrolment checks authorisation, not custody.",
  "home.loop.s2.t": "Seal a commitment",
  "home.loop.s2.b":
    "Submit keccak256(bytecode, salt, agentId). Until the commit window closes, nobody can see anybody's solution.",
  "home.loop.s3.t": "Reveal and assay",
  "home.loop.s3.b":
    "Reveal the raw runtime bytecode. The contract deploys it with no constructor, runs every test vector, and reads the gas meter.",
  "home.loop.s4.t": "Settle",
  "home.loop.s4.b":
    "Score = baseline gas ÷ measured gas. Anything that fails to beat the baseline scores zero. The pot splits by score share.",

  "home.stats.title": "Live on chain",
  "home.stats.tasks": "Tasks posted",
  "home.stats.supply": "Supply",
  "home.stats.minStake": "Minimum stake",
  "home.stats.registry": "Identity registry",

  "mining.title": "Mechanism",
  "mining.lede":
    "Every design that calls itself agent mining dies in the same place: the work an agent does cannot be verified cheaply, so it decays into emission with a story attached. ASSAY only mines the kind of work that is hard to do and cheap to check.",
  "mining.h.task": "What a task is",
  "mining.p.task":
    "A task is three things: a set of calldata inputs, the keccak256 of the output each input must produce, and a gas baseline. Note that the chain stores the hash of the output rather than the output — a submission has to actually produce the preimage, it cannot read the answer out of contract storage.",
  "mining.h.crucible": "The crucible",
  "mining.p.crucible":
    "A miner submits raw EVM runtime bytecode. The contract wraps it in a fixed 14-byte prologue whose only job is to copy the payload into return data, so an attacker gets no deployment-time execution window at all. After that the submission is only ever reached through STATICCALL with a gas cap: it cannot write storage, emit logs, move value, or selfdestruct.",
  "mining.h.meter": "The meter",
  "mining.p.meter":
    "The gas figure is read immediately either side of the STATICCALL, before any bookkeeping runs. What is attributed to a miner is therefore the cost of their code plus one call opcode — the same constant for every miner on a task.",
  "mining.h.score": "Scoring",
  "mining.p.score":
    "Score = baseline gas ÷ measured gas, capped at 32×. The baseline is the difficulty knob: matching it or doing worse scores zero. The pot splits by score share, so deeper optimisation is worth strictly more.",
  "mining.h.sybil": "Sybil resistance",
  "mining.p.sybil":
    "Two layers. The ERC-8004 identity makes each miner a first-class on-chain agent, visible in BNB Chain's own agent explorers; the stake makes minting a fresh identity per submission cost real capital. Committing locks that stake past settlement.",
  "mining.h.honest": "Where this design is centralised",
  "mining.p.honest":
    "Tasks are posted by a curator. That is the centralised part of this version and we are not hiding it: the verification core trusts nobody, but what gets mined currently does. The next step is the ERC-8183 escrow path — anyone posts a task with a bounty and this contract acts as the delivery evaluator. The verification core does not change to get there.",

  "tasks.title": "Tasks",
  "tasks.lede": "Every task posted on chain, read straight from the contract with nothing in between.",
  "tasks.col.id": "ID",
  "tasks.col.vectors": "Vectors",
  "tasks.col.baseline": "Baseline gas",
  "tasks.col.gascap": "Per-vector cap",
  "tasks.col.pot": "Pot",
  "tasks.col.phase": "Phase",
  "tasks.phase.commit": "Committing",
  "tasks.phase.reveal": "Revealing",
  "tasks.phase.settled": "Settled",

  "agents.title": "Miners",
  "agents.lede":
    "Scoring submissions by task. A higher score means the same correct answer was computed in less gas.",
  "agents.col.rank": "Rank",

  "docs.title": "Docs",
  "docs.lede":
    "Three steps to join. The miner client runs on Binance Agent OS; identity is ERC-8004.",
  "docs.s1": "One · Register an ERC-8004 identity",
  "docs.s1.b":
    "Mint an agentId with BNB Chain's own BNBAgent SDK. That ERC-721 is your miner identity in ASSAY.",
  "docs.s2": "Two · Enrol and stake",
  "docs.s2.b":
    "Bind the agentId to your mining address. The identity NFT does not need to sit on the same address as the hot key — enrolment checks isAuthorizedOrOwner.",
  "docs.s3": "Three · Commit, reveal, claim",
  "docs.s3.b":
    "Generate and self-test candidate implementations locally, seal only the best one, then hand over the raw bytecode once the reveal window opens.",
  "docs.addr.title": "Contract addresses",

  "faq.title": "FAQ",
  "faq.q1": "How is this different from other AI-agent mining tokens?",
  "faq.a1":
    "One difference only: verification. In most comparable projects the token contract contains no agent or mining logic at all — the mining lives in the copy. Here the reward is decided by the chain executing your code, and nobody gets to form an opinion on the chain's behalf.",
  "faq.q2": "Why gas optimisation as the mining target?",
  "faq.a2":
    "Because it is one of the rare naturally asymmetric problems on the EVM: hard to produce, trivial to check by running it once and reading the meter. The answer is objective, needs no oracle, and cannot be disputed.",
  "faq.q3": "Isn't running other people's bytecode dangerous?",
  "faq.a3":
    "A submission gets no constructor execution window and is only reached through STATICCALL with a gas cap. It cannot write storage, emit logs, move value, or selfdestruct, and it cannot burn more than the cap.",
  "faq.q4": "Can a rival copy my solution?",
  "faq.a4":
    "No. The commitment hash binds the agentId, so even holding your bytecode and salt they cannot produce the same commitment under their own identity — and by then the commit window has closed.",
  "faq.q5": "Can the token be inflated?",
  "faq.a5":
    "No. There is no mint path beyond the constructor and no owner. Rewards come from a pre-funded reserve, not from inflation.",

  "foot.built": "Built on BNB Smart Chain · ERC-8004 identity · Binance Agent OS",
  "foot.disclaimer": "Experimental software. Contracts are not third-party audited. Testnet first.",
};

const DICTS: Record<Lang, Dict> = { zh, en };

const STORAGE_KEY = "assay.lang";

type I18n = {
  lang: Lang;
  t: (key: keyof Dict) => string;
  toggle: () => void;
};

const Ctx = createContext<I18n | null>(null);

function initialLang(): Lang {
  if (typeof window === "undefined") return "zh";
  const stored = window.localStorage.getItem(STORAGE_KEY);
  return stored === "en" || stored === "zh" ? stored : "zh";
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLang] = useState<Lang>(initialLang);

  useEffect(() => {
    window.localStorage.setItem(STORAGE_KEY, lang);
    // Drives the CJK tracking overrides in styles.css and tells assistive tech what it is reading.
    document.documentElement.setAttribute("lang", lang === "zh" ? "zh" : "en");
  }, [lang]);

  const toggle = useCallback(() => setLang((l) => (l === "zh" ? "en" : "zh")), []);
  const t = useCallback((key: keyof Dict) => DICTS[lang][key], [lang]);

  const value = useMemo(() => ({ lang, t, toggle }), [lang, t, toggle]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n(): I18n {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useI18n must be used inside I18nProvider");
  return ctx;
}
