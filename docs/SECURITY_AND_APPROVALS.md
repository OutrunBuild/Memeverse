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

GenesisCredit 是 per-uAsset ERC20+OFT 凭证（`leveragedGenesisWithCredit` 用它抵扣杠杆利息），其权限模型与跨链拓扑是安全敏感面，任何改动触及以下任一项都必须先经人工确认（§3 规则同样适用）：

- **mint 权限（permissionless merkle claim）**：`GenesisCredit.claim(...)` 无白名单、无 caller 限制，任何地址凭 merkle proof 领取——这是有意的冷启动设计，不是漏洞，安全依赖 merkle root 的正确性而非 caller 准入。把 claim 改为白名单 / 受限 caller 属于产品规则变化，必须先经人工确认。详见 [docs/operations.md §3.12](operations.md)。
- **无本地供应封顶（owner 信任假设）**：`claim()` 铸造路径没有本地供应 cap，可铸总量由 owner 经 `setMerkleRoot` 写入的叶分配之和决定（owner 信任假设；OFT 跨链为 burn-on-src / mint-on-dst，净供应只在 home 链 claim 时增长，无跨链旁路）。协议资金敞口仍由 `debtCap` + aggregate `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 封顶。重新引入本地供应 cap、添加链下供应监控、或限制单叶分配上限，属于产品规则变化，必须先经人工确认。残余风险：GenesisCredit 在二级市场或外部集成中的供应无上界（依赖有界供应的集成可能被 grief）。
- **burn 路径（标准自烧）**：`GenesisCredit.burn(uint256)` 是持币人标准 ERC20 自烧路径（无 burner 权限模型），`POLendUpgradeable.finalizeLeveragedGenesis` 烧毁自己托管的 GenesisCredit 余额也走该路径。引入 burner 白名单或把 burn 改为 owner-only 属于产品规则变化，必须先经人工确认。详见 [docs/spec/polend/genesis.md §4.1](spec/polend/genesis.md)。
- **merkle root 单点写入 home 链防跨链重复领**：merkle root 只在 home 链（Ethereum 主网）由对应 GenesisCredit 的 owner 经 `setMerkleRoot` 写入，非 home 链 `claim` 直接 revert——这是防止同一份 credit 跨链重复领取的核心规则，改为多链写入 root 或允许目标链 claim 必须先经人工确认。门控正确性依赖 factory 构造时 `homeChainEid_` 传规范 home eid（immutable，部署后无法修正；远程链误传本地 eid 会让门控在远程成立，脚本无法自动判定），护栏为部署时单一来源 + 部署后日志人工对照，见 [docs/operations.md](operations.md) §3.12 `homeChainEid 部署参数护栏`。
- **GenesisCreditFactory / GenesisCredit owner-only 入口**：`GenesisCreditFactory.deployCredit(uAsset, name, symbol, delegate)` 是 factory owner-only（`delegate` 成为对应 GenesisCredit 初始 owner），`GenesisCredit.setMerkleRoot(root)` 是该 GenesisCredit owner-only，`creditOf(uAsset)` 为公开 view。放开 `deployCredit` / `setMerkleRoot` 到 permissionless 属于权限边界变化，必须先经人工确认。详见 [docs/operations.md §3.12](operations.md)。
- **地址确定性边界**：`deployCredit` 由 factory 直接执行 CREATE3（`salt = keccak256(abi.encode(uAsset))`），保证本链 per-uAsset 地址确定。跨链同址是条件性假设、非合约保证（需 `factory` 与 `uAsset` 均跨链同址）；地址跨链漂移的后果与 `setPeer` 逐链核验要求见 [docs/operations.md §3.12](operations.md)。
- **credit / uAsset decimals 一致性**：GenesisCredit 固定 18 decimals，credit path 要求与 `uAsset` 同 raw-unit 口径，否则 debt / launch gate / YT / residual 按错误数量级计算（`deployCredit` 对非 18-dec `uAsset` revert `InvalidUAssetDecimals`；`leveragedGenesisWithCredit` 缓存 credit token 前校验并 revert `CreditDecimalsMismatch`）。放开 credit path 到非 18-dec `uAsset`、或改 GenesisCredit 为可变 decimals，属于产品规则变化，必须先经人工确认。详见 [docs/spec/polend/genesis.md §4.1](spec/polend/genesis.md)。
- **pause 应急开关（owner 全量冻结）**：`GenesisCredit.sol::pause` / `GenesisCredit.sol::unpause` 是 owner-only 应急开关（OZ `ERC20Pausable`，不新增角色），pause 期间全挡该链 GenesisCredit 的全部 ERC20 状态变更（含 `transfer` / `transferFrom` / `claim` / `burn` / OFT 桥接，revert `EnforcedPause`），每个链上部署的 pause 状态互相独立。把 pause / unpause 放开为 permissionless、引入独立 pauser 角色、或缩小全挡范围，属于权限边界变化，必须先经人工确认；约束见 [docs/spec/invariants.md INV-27](spec/invariants.md) 与 [docs/operations.md](operations.md) §3.12。

### 4.4 普通 Swap 动态费与 v4 费用边界 `[代码已证]`

已批准的普通单池动态 Swap 规则是：对原始 exact-input 输入或原始 exact-output 净输出选费一次；不得用变换后的核心目标、费用、本笔 fee-induced flow、协议费币腿或用户原始价格限制再次选费。审阅不得把 fee-on-fee、自递归或多轮估算作为安全修复重新引入。

安全审阅必须区分实际核心 delta 和最终用户 delta：前者用于成交完整性、状态更新和 Hook 结算；后者才是 Router 的最小输出/最大输入保护依据。不同币种的金额不得相加形成虚假的总费用；referral rebate 不得超过该笔实际 protocol fee。普通动态费的四条请求/协议费币腿路径属于产品规则，固定费路径继续使用 `FeeMath.feeOnAmount`，两者不能互相替代。

原始价格限制仅决定交易是否可完整执行，不能影响已选 `feeBps`。全范围端点 equality 必须拒绝：它会耗尽唯一仓位并可能令活跃流动性归零。exact-output 仍是支持的公开请求类型；非零 100% exact-output、不可完整成交或不可表示的金额必须拒绝，不能返回部分成交或无穷大哨兵金额。

v4 LP fee 的源码结构事实是：新池初始化为零、当前没有 `updateDynamicLPFee`、普通 `beforeSwap` 不返回 fee override。本任务不为这些事实增加 runtime、首次发布、持续治理或运维控制。PoolManager protocol fee 是外部 controller 的行为，不受 Memeverse 权限或保证，也不属于本任务的 protocol fee 模型。

### 4.5 Smart EOA transient session 审阅边界 `[代码已证]`

以下约束 Smart EOA session 实现与审阅边界，适用于当前普通 Swap 动态费与 v4 费用路径中已实现的 session lifecycle / ABI。

- `DynamicFeeFacet.addressBatchState[trader][poolId]` 的执行 trader 必须是 Hook 捕获的 session principal，绝不得使用 `tx.origin` 或 outer submitter。审阅必须核验 principal 在 `beginAccountSession()` 时只由直接 `msg.sender` 确定；begin 写入前同时要求 `activePrincipal == address(0)` 与 `swapContextDepth() == 0`，任一不满足均拒绝，不能覆盖或继承残留 context。
- 后续实现必须审阅整个 `begin -> Router -> end` frame 的不可 catch、全成全败边界，并逐项覆盖 missing session、nested session、missing end 与 unauthorized end 的拒绝或回滚。`beforeSwap` 验证 active session principal 并写入带 principal 的 context；`afterSwap` 验证 active session principal 和匹配的非零 `SwapContext.principal`，再消费 context；principal mismatch、wrong-pool 或 missing context 不能通过减小 depth 恢复。
- Router identity、`hookData`、Universal Router `msgSender`、签名、EIP-712、ERC-1271 与 Router allowlist 都不是本方案的一部分，也不引入 persistent state 或 Event。多用户 batch Router 及漏掉 end 后的 bypass 调用不受支持。

### 4.6 YT Flash Swap 审阅边界 `[目标规范]`

以下约束 YT Flash Swap（POL↔YT 复用 PT/POL 池，详见 [docs/spec/swap/yt-flash-swap.md](spec/swap/yt-flash-swap.md)）的审阅边界。这些是**已批准的产品规则**，审阅不得改写：

- **产品规则（不是审阅可改写的）**：无 Permit2、无 quote 入参、无 Lens/搜索参数、无管理员、无退款循环；付款只用 allowance + transferFrom，买入只拉 `actualPOLIn`、不预拉 `maxPOLIn`；SDK 负责固定 EIP-1898 `blockHash` 报价与 headroom，Router 不接收也不信任历史 quote。审阅不得把「为了更安全，让 Router 接收并校验 quote」「引入 Permit2」「预拉 maxPOLIn 再退款」「加管理员审批 flash」「把求根/二分搬上链」作为安全修复重新提出——这些都属于产品规则变化（§3），必须先经人工确认。
- **真实 BalanceDelta 是唯一结算依据**：`FlashDeltaMismatch` 只校验真实 delta 的币种、符号与完整成交结构，绝不比较历史 quote。审阅不得要求 Router 与离线 quote 相等、或把「真实结果偏离历史报价」当作 revert 条件。
- **principal 绑定与 canonical dependency 在资金动作前**：每个用户入口在任何转账、take、settle、split、merge 前，必须同时通过 `hook.activeAccountSessionPrincipal() == msg.sender` 与当前 launcher 的 `getLauncherContracts()` 一致性校验。principal 失配回滚 Router 自身接口 `src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol` 定义的 `AccountSessionPrincipalMismatch`（与 Hook 同名 afterSwap error 的区分见 [yt-flash-swap.md §11](spec/swap/yt-flash-swap.md)）。审阅不得把它们后置到 callback 内或移除。
- **dust 不可消费、baseline 必须恢复**：PT/YT/POL 三个 baseline 在 `unlock` 返回后必须精确恢复；预存 dust 不可消费；`recipient` 为 Router 被禁止。审阅不得把「用 Router 自有余额补差」或「消费 dust 容忍误差」作为修复建议。
- **买入 Splitter POL allowance residual 必须为 0**：买入成功路径 split 后 Router→Splitter 的 POL allowance 必须归零（split 恰好消耗 `y`，成功路径不调 `approve(0)`）；卖出的 `merge` 直接 burn PT/YT 不经 ERC20 approval。审阅不得引入残留 allowance 或第二次 approve。
- **失败原子回滚**：capacity 不足、价格限制、partial fill、恶意 callback、token/Splitter 重入、int128/uint256 边界、过期 deadline、principal/dependency 失配、非法成本（`R_actual` 零或负）/非法债务（`Q_actual` 零或 ≥ y）、`minPOLOut`/`maxPOLIn` 违反、baseline/allowance 未恢复都必须原子回滚，用户不会因失败交易被保留预拉资产。审阅可以补充具体失败路径的测试，但不得放宽这些 fail-closed 语义。
- **与普通 swap 共享费率规则**：YT Flash Swap 底层 PT/POL 腿就是一次普通动态 swap，§4.4 的费率/容量/价格限制/referral 审阅边界完全适用；审阅不得要求 Router 重复收费、二次「修正 swap」或第二套 fee/referral 状态机。

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
