# Security And Approvals

## 1. 安全审阅的职责

安全审阅可以输出：

- 风险
- 触发条件
- 后果
- 证据
- 可选修复方案
- 建议补充的测试

安全审阅不能直接输出：

- 新的产品需求
- 未经确认的业务规则改写
- “必须这样设计”的产品结论

## 2. 明确禁止

以下行为一律禁止：

- 以 review 名义修改产品需求
- 把“审阅建议”直接写成仓库规则
- 在没有人工确认的情况下改变资金流约束
- 在没有人工确认的情况下改变权限边界
- 在没有人工确认的情况下扩大 keeper、treasury、admin 或其他 privileged role 的职责

## 3. 必须升级为决策点的改动

如果某个建议会改变以下任一项，必须先由 `main-orchestrator` 或人工确认：

- 业务语义
- 资金流约束
- claim / settlement / queue / liquidity 等产品规则
- 收益归属或收益领取规则
- 权限边界
- 升级模型
- 外部协议依赖边界

在确认前，reviewer 只能把它写成：

- 风险描述
- 原因
- 后果
- 可选方案
- 待确认决策点

## 4. 常见判定示例

### 4.1 允许直接修复

- 明确的算术错误
- 明确的访问控制漏洞
- 与既有 spec / 当前实现明显冲突的行为错误
- 存储布局冲突
- 事件缺失导致既有对外行为不可观测

### 4.2 不允许直接落地

- “为了更安全，把协议规则改成更保守的资金流约束”
- “为了未来扩展，先预留一套新的状态机”
- “为了用户体验，把延迟路径改成即时路径”
- “为了统一实现，顺手扩大 keeper / treasury / admin 职责”

这些都属于产品规则变化，不是纯安全修复。

### 4.3 GenesisCredit 安全边界

GenesisCredit 是 per-uAsset ERC20+OFT 凭证（`leveragedGenesisWithCredit` 用它抵扣杠杆利息），其权限模型与跨链拓扑是安全敏感面，任何改动触及以下任一项都必须先经人工确认（§3 规则同样适用）。以下均为已批准产品规则，规则本体见各 canonical home，此处只记录审阅判定边界：

- **permissionless merkle claim（mint 权限）**：`claim(...)` 无白名单、无 caller 限制，安全依赖 merkle root 的正确性而非 caller 准入；把 claim 改为白名单 / 受限 caller 属于产品规则变化。见 [docs/operations.md §3.12](operations.md)。
- **无本地供应封顶（owner 信任假设）**：可铸总量由 owner 经 `setMerkleRoot` 写入的叶分配之和决定；协议资金敞口仍由 `debtCap` + aggregate `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 封顶。重新引入本地供应 cap、添加链下供应监控、或限制单叶分配上限属于产品规则变化。残余风险：GenesisCredit 在二级市场或外部集成中的供应无上界。
- **burn 路径（标准自烧）**：`burn(uint256)` 是持币人标准 ERC20 自烧路径，`finalizeLeveragedGenesis` 烧毁托管余额走同一路径；引入 burner 白名单或改 owner-only 属于产品规则变化。见 [docs/spec/polend/genesis.md §4.1](spec/polend/genesis.md)。
- **merkle root 单点写入 home 链防跨链重复领**：root 只在 home 链由实例 owner 写入，非 home 链 `claim` 直接 revert；改为多链写入或允许目标链 claim 必须先经人工确认。`homeChainEid` 部署参数护栏（immutable、误配不可修正）见 [docs/operations.md §3.12](operations.md)。
- **owner-only 入口**：`GenesisCreditFactory.deployCredit` 与 `GenesisCredit.setMerkleRoot` 均为 owner-only（`creditOf` 为公开 view）；放开到 permissionless 属于权限边界变化。见 [docs/operations.md §3.12](operations.md)。
- **地址确定性边界**：CREATE3 保证本链 per-uAsset 确定性地址；跨链同址是部署前提、非合约保证，`setPeer` 须逐链按实际地址核验。见 [docs/ARCHITECTURE.md §1.7](ARCHITECTURE.md)。
- **credit / uAsset decimals 一致性**：credit path 仅支持 `uAsset.decimals() == 18`（`InvalidUAssetDecimals` / `CreditDecimalsMismatch`）；放开到非 18-dec `uAsset` 或改可变 decimals 属于产品规则变化。见 [docs/spec/polend/genesis.md §4.1](spec/polend/genesis.md)。
- **pause 应急开关（owner 全量冻结）**：`pause` / `unpause` 是 owner-only 全挡开关（OZ `ERC20Pausable`，每链独立）；放开为 permissionless、引入独立 pauser 角色、或缩小全挡范围属于权限边界变化。约束见 [docs/spec/invariants.md INV-27](spec/invariants.md) 与 [docs/operations.md §3.12](operations.md)。

### 4.4 普通 Swap 动态费与 v4 费用边界 `[代码已证]`

已批准规则本体见 [docs/spec/swap/uniswap-v4.md §3.1–§3.2](spec/swap/uniswap-v4.md)（唯一 canonical）与 [INV-22](spec/invariants.md)。审阅判定边界：一次选费只以原始用户请求为输入；必须区分实际核心 delta 与最终用户 delta；跨币种金额不得相加；返佣不得超过本笔实际 protocol fee；四条请求/协议费币腿路径属产品规则；原始价格限制仅决定可执行性、不影响已选 `feeBps`；全范围端点 equality 必须拒绝。审阅不得把 fee-on-fee、自递归、多轮估算或部分成交作为安全修复重新引入；固定费路径与动态路径不能互相替代。v4 LP fee 的源码结构事实（新池初始化为零、当前无 `updateDynamicLPFee`、普通 `beforeSwap` 不返回 fee override）与 PoolManager protocol fee 的外部 controller 边界，不得被“补 runtime / 治理检查”类建议改写。

### 4.5 Smart EOA transient session 审阅边界 `[代码已证]`

已批准规则本体见 [docs/spec/access-control.md §3.1](spec/access-control.md)、[docs/ARCHITECTURE.md §4.6](ARCHITECTURE.md) 与 [INV-23](spec/invariants.md)。审阅判定边界：`DynamicFeeFacet` 的执行 trader 必须是 Hook 捕获的 session principal，绝不得使用 `tx.origin` 或 outer submitter；`begin -> Router -> end` 的不可 catch、全成全败 frame 边界，以及 missing session、nested session、missing end、unauthorized end 的拒绝面必须逐项覆盖。Router identity、`hookData`、Universal Router `msgSender`、签名、EIP-712、ERC-1271 与 Router allowlist 都不是本方案的一部分，也不引入 persistent state 或 session Event——把它们作为“加固”重新提出属产品规则变化。

### 4.6 YT Flash Swap 审阅边界 `[目标规范]`

以下约束 YT Flash Swap（POL↔YT 复用 PT/POL 池，唯一 canonical 见 [docs/spec/swap/yt-flash-swap.md](spec/swap/yt-flash-swap.md)）的审阅边界。这些是**已批准的产品规则**，审阅不得改写：

- **产品规则（不是审阅可改写的）**：无 Permit2、无 quote 入参、无 Lens/搜索参数、无管理员、无退款循环；付款只用 allowance + transferFrom，买入只拉 `actualPOLIn`、不预拉 `maxPOLIn`；SDK 负责固定 EIP-1898 `blockHash` 报价与 headroom。把「Router 接收并校验 quote」「引入 Permit2」「预拉 `maxPOLIn` 再退款」「加管理员审批 flash」「把求根/二分搬上链」作为安全修复重新提出，属产品规则变化（§3），须先经人工确认。
- **真实 `BalanceDelta` 是唯一结算依据**：`FlashDeltaMismatch` 只校验真实 delta 的币种、符号与完整成交结构，绝不比较历史 quote；审阅不得要求 Router 与离线 quote 相等、或把「真实结果偏离历史报价」当 revert 条件。
- **principal 绑定与 canonical dependency 在资金动作前**：每个入口在任何转账、take、settle、split、merge 前须同时通过 `hook.activeAccountSessionPrincipal() == msg.sender` 与 `getLauncherContracts()` 一致性校验（Router 自身接口与 Hook 同名 error 的区分见 yt-flash-swap.md §11）；审阅不得把它们后置到 callback 内或移除。
- **dust 不可消费、baseline 必须精确恢复、买入 Splitter POL allowance 残留必须为 0、失败原子回滚**：完整约束集见 [INV-24](spec/invariants.md)；审阅不得把「用 Router 自有余额补差」「消费 dust 容忍误差」「残留 allowance」作为修复建议，不得放宽 fail-closed 语义。
- **与普通 swap 共享费率规则**：底层 PT/POL 腿就是一次普通动态 swap，§4.4 的费率/容量/价格限制/referral 审阅边界完全适用；审阅不得要求 Router 重复收费、二次「修正 swap」或第二套 fee/referral 状态机。

## 5. 审阅输出格式建议

审阅结论应尽量包含：

- `Finding`
- `Severity`
- `Where`
- `Why`
- `Impact`
- `Evidence`
- `Options`
- `Needs decision`

如果 `Needs decision = yes`，实现型角色不得默认落地。

## 6. 与流程文档的关系

当 [docs/SECURITY_AND_APPROVALS.md](SECURITY_AND_APPROVALS.md) 与某条 review 建议冲突时，以本文件和 [AGENTS.md](../AGENTS.md) 为准，而不是以 review 建议为准。
