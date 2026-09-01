# Flap Vault Interaction Risk Report — response / 审计意见回复

**Project / 项目:** ASSAY (`AssayFlapVault`)
**Report generated / 报告生成:** 2026-09-01 10:05:41 UTC
**Response / 回复:** 2026-09-01 · commit `21378a7`

Both findings are accepted. Both are fixed in the archive accompanying this response.
两条意见均确认属实，随本回复提交的压缩包中均已修复。

---

## Finding 1 — SYS-REQ-LITERAL-ERRORS

**Severity:** High **Status:** `[x] TP` `[ ] FP` `[ ] By Design` `[ ] Acknowledged`

### Why this was our mistake / 问题成因

We had read the rule as applying to the vault contract only, on the reasoning that the vault is
what Flap's UI renders. That reading is wrong. The rule is about any revert a user can reach, and
every contract listed in the finding is on a user path: a miner enrolling calls `AgentRoster`,
committing and revealing call `Tournament`, and both returned a 4-byte selector the renderer
cannot decode.

我们此前把该规则理解为只适用于金库合约，理由是金库才是 Flap UI 渲染的对象。这个理解是错的。规则针对
的是**用户能触达的任何 revert**，而意见中列出的每个合约都在用户路径上：矿工注册走 `AgentRoster`，
提交承诺与揭示走 `Tournament`，两者都会返回渲染器无法解码的 4 字节 selector。

### What changed / 修改内容

Every custom error is removed and every revert site is now `require(condition, "English / 中文")`.

所有自定义错误已删除，每处 revert 改为 `require(条件, "English / 中文")`。

| Contract | Errors removed | Revert sites converted |
|---|---|---|
| `src/Tournament.sol` | 20 | 25 |
| `src/AgentRoster.sol` | 10 | 13 |
| `src/AssayVault.sol` | 10 | 19 |
| `src/Crucible.sol` | 4 | 4 |
| `src/TaskGenerator.sol` | 2 | 2 |
| `src/PriceGuard.sol` | 1 | 1 |
| `src/AssayFlapVault.sol` | 0 | 1 standalone `revert(unicode"…")` |
| **Total** | **47** | **65** |

The standalone `revert(unicode"Unsupported chain / 不支持该链")` in the `AssayFlapVault` constructor
became a positive assertion placed after the chain branch, which is both the form the rule asks for
and smaller bytecode than the `if/else` it replaced.

`AssayFlapVault` 构造函数中的独立 `revert(unicode"…")` 改为链分支之后的正向断言，既符合规则要求的
写法，也比原来的 `if/else` 更省字节。

### A consequence we want to state plainly / 需要明确说明的一个取舍

Error arguments are gone. `InsufficientAccount(account, have, want)` is now
`require(have >= amount, unicode"Account is short / 账户余额不足")`, which no longer carries the two
amounts. We read this as what the rule intends — a message the user can read is worth more here
than a value they cannot decode — but it is a real loss of debugging detail and we are flagging it
rather than leaving it for the reviewer to notice.

错误参数丢失了。`InsufficientAccount(account, have, want)` 现在是
`require(have >= amount, unicode"Account is short / 账户余额不足")`，不再携带两个数值。我们认为这
正是规则的用意——**用户能读懂的文字，比他解码不了的数值更有价值**——但这确实损失了调试信息，我们主动
说明，而不是留给审阅者去发现。

---

## Finding 2 — SYS-REQ-MULTILANG

**Severity:** High **Status:** `[x] TP` `[ ] FP` `[ ] By Design` `[ ] Acknowledged`

### What changed / 修改内容

Both `description()` banners were English-only while every `require` string and both UI schemas
were already bilingual. They are bilingual now.

两个 `description()` 状态横幅原为纯英文，而所有 `require` 串和两个 UI schema 本来就是双语。现已改为
双语。

**`src/AssayFlapVault.sol` `description()`**

| Before | After |
|---|---|
| `No task has been posted yet.` | `No task yet / 尚未发布任务` |
| `Tax is waiting to be converted behind a task.` | `Tax unconverted / 税款待兑换` |
| `A bounty is live. Beat the baseline to earn a share.` | `Bounty live / 赏金进行中` |
| `All bounties have been collected.` | `Bounties collected / 赏金已领取` |

**`src/Tournament.sol` `description()`**

| Before | After |
|---|---|
| `No task has been posted yet.` | `No task posted yet. / 尚未发布任务。` |
| `A task is open. Commitments are being taken.` | `A task is open. Commitments are being taken. / 任务进行中，正在接受提交承诺。` |
| `Commitments are closed. Submissions are being revealed and assayed.` | `Commitments are closed. Submissions are being revealed and assayed. / 承诺已截止，正在揭示并计量提交。` |
| `The latest task is settled. Winners may claim.` | `The latest task is settled. Winners may claim. / 最新一期已结算，获胜者可领取。` |

### Why the vault's banners are shorter than the tournament's / 为什么金库的横幅更短

Not an oversight. Adding the Chinese put `AssayFlapFactory` at 861 bytes below the EIP-170 ceiling,
under the one-kilobyte margin our `test/CodeSize.t.sol` requires, because the factory embeds the
vault's creation code.

The obvious remedy — moving `vaultUISchema()` out of the vault, at 7,015 bytes the single largest
item in it — is not available: `VaultBaseV2` declares `vaultUISchema()` as `public pure virtual`,
and a `pure` override cannot call an external contract. So the vault's banners were tightened
instead. Each still names its state in both languages; the instruction that used to ride along in
"beat the baseline" belongs in the UI schema, which already carries it. `Tournament` is deployed
standalone and has room, so its banners keep the full sentences.

Margin after the change: factory **1,055** bytes, `Tournament` **3,034** bytes.

这不是疏忽。加上中文后 `AssayFlapFactory` 距 EIP-170 上限只剩 861 字节，低于
`test/CodeSize.t.sol` 要求的 1KB 余量——因为工厂内嵌了金库的创建码。

最直接的办法是把 `vaultUISchema()` 搬出金库（它占 7,015 字节，是金库里最大的单项），但**做不到**：
`VaultBaseV2` 把 `vaultUISchema()` 声明为 `public pure virtual`，而 `pure` 覆写不能调用外部合约。
因此改为压缩金库的横幅文案。每条仍以双语说明当前状态；原先夹带的"跑赢基准"这句操作提示属于 UI schema，
而那里已经有了。`Tournament` 独立部署、余量充足，其横幅保留完整句子。

修改后余量：工厂 **1,055** 字节，`Tournament` **3,034** 字节。

---

## Verification / 如何验证

```bash
# no custom error and no standalone revert survives anywhere under src/
grep -rn '^\s*error [A-Z]' src/*.sol          # 0 matches
grep -rn 'revert [A-Z]\|revert(' src/*.sol    # 0 matches

forge test          # 215 tests, 32 suites
forge build --sizes # AssayFlapFactory margin 1,055
```

55 test assertions were updated from `vm.expectRevert(Contract.Error.selector)` and
`vm.expectRevert(bytes4(keccak256("Error()")))` to `vm.expectRevert(bytes(unicode"… / …"))`, so
each test now asserts the exact string a user will see rather than a selector.

55 处测试断言已从 `vm.expectRevert(Contract.Error.selector)` 和
`vm.expectRevert(bytes4(keccak256("Error()")))` 改为 `vm.expectRevert(bytes(unicode"… / …"))`，
因此每个测试现在断言的是**用户实际会看到的那串文字**，而不是一个 selector。

## Deployed / 链上部署

Redeployed after these changes so the deployed bytecode matches the source in this archive; the
packaging step verifies that byte for byte. No token has been launched on either chain.

修改后已重新部署，使链上字节码与本压缩包内源码一致；打包环节会逐字节校验。两条链均未发行代币。

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x7aa4BBdc94A69a7cc4924c6E354756731DbFA7bc` | `0x7E94BF3F4a881F1051b2724634E996918579C230` |
| `Tournament` | `0xd0266f3375162B38D810E6E58d4653Ac8a678775` | `0x2be2d3EA801f963eCDb3333D03dd3F5536162482` |
| Tax token | not launched / 未发行 | not launched / 未发行 |
