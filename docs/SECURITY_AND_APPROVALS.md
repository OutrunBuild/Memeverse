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

- **mint 权限（permissionless merkle claim）**：`GenesisCredit.claim(...)` 无白名单、无 caller 限制，任何地址凭 merkle proof 领取分配给它的 credit。这是有意的冷启动设计，不是漏洞——安全依赖于 merkle root 的正确性而非 caller 准入。把 claim 改为白名单 / 受限 caller 属于产品规则变化。
- **无本地供应封顶（owner 信任假设）**：`claim()` 铸造路径**没有本地累计 / 供应 cap**——可铸造总量完全由 owner 通过 `setMerkleRoot` 写入的叶分配之和决定。被攻陷或恶意的 owner 可构造任意大的 merkle 分配，铸造无上限的 GenesisCredit（OFT 跨链是 burn-on-src / mint-on-dst，净全球供应只在 home 链 claim 时增长，故无跨链旁路绕过此假设）。协议内部资金敞口仍由上游 `POLend.leveragedGenesisWithCredit` 的 per-verse `debtCap` + aggregate `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 封顶（credit 抵扣的债务 D 受限，credit 铸造量本身不放大可提取债务）；残余风险是 GenesisCredit 在二级市场或外部集成中的供应无上界（抛售 / 依赖有界供应的集成被 grief）。重新引入本地供应 cap、添加链下供应监控、或限制单叶分配上限，属于产品规则变化，必须先经人工确认。
- **burn 路径（标准自烧）**：`GenesisCredit.burn(uint256)` 是持币人标准 ERC20 自烧路径（无 burner 权限模型）。`POLend.finalizeLeveragedGenesis` 烧毁自己托管的 GenesisCredit 余额也走该路径（POLend 作为持币人自烧）。引入 burner 白名单或把 burn 改为 owner-only 属于产品规则变化。
- **merkle root 单点写入 home 链防跨链重复领**：merkle root 只在 **home 链（Ethereum 主网）** 写入；操作方可先通过 `GenesisCreditFactory.creditOf(uAsset)` 查询对应 GenesisCredit 地址；只有该 GenesisCredit 的 owner（部署时传入 `deployCredit(..., delegate)` 的 `delegate`，或后续 `transferOwnership` 后的新 owner）可以直接调用 `GenesisCredit.setMerkleRoot(root)`。非 home 链的 GenesisCredit 不接受 claim（直接 revert）。这是防止同一份 credit 被跨链重复领取的核心安全机制。若提议改为多链写入 root、或允许目标链 claim，必须先经人工确认，因为会破坏单点写入防重领语义。门控正确性依赖 factory 构造时 `homeChainEid_` 传规范 home eid（immutable，部署后无法修正）；远程链误传本地 eid 会让门控在远程成立。脚本无法自动判定此误配，护栏为部署时单一来源 + 部署后日志人工对照（factory 必须仅经此脚本函数部署，手动部署重引入 R1-F5），见 [docs/operations.md](operations.md) §3.12 `homeChainEid 部署参数护栏`。
- **GenesisCreditFactory / GenesisCredit owner-only 入口**：`GenesisCreditFactory.deployCredit(uAsset, name, symbol, delegate)` 是 factory owner-only；`GenesisCreditFactory.creditOf(uAsset)` 是 view，用于查对应 GenesisCredit 地址；`GenesisCredit.setMerkleRoot(root)` 是该 GenesisCredit owner-only。放开 `deployCredit` / `setMerkleRoot` 到 permissionless 属于权限边界变化。
- **地址确定性边界**：`deployCredit` 由 factory 直接执行 CREATE3，使用 `CREATE3 salt = keccak256(abi.encode(uAsset))` 保证本链 per-uAsset 地址确定，`creditOf / predictCredit` 与本链 factory 部署结果自洽。跨链同址是条件性假设、非合约保证：需 `factory` 与 `uAsset` 都跨链同址（`uAsset` 是外部 Outrun 资产，其跨链同址性非本代码创建/校验）。若 `factory` 或 `uAsset` 跨链不一致，后果是 credit 地址跨链漂移 → `setPeer` 配错 → 跨链 OFT send 投递失败/误投（不影响本链 `creditOf` 解析——本链解析只看本链 factory 本地部署）。部署 / 迁移时必须核验两层同址；`setPeer` 必须逐链查实际 `creditOf(localUAsset)`。
- **credit / uAsset decimals 一致性**：GenesisCredit 固定 18 decimals，credit path 要求 credit 与 `uAsset` 同 raw-unit 口径，否则 `1e18` raw credit 会被当作 `1e18` raw uAsset 利息，导致 debt / launch gate / YT / residual 按错误数量级计算（6-dec `uAsset` 下错位 1e12 倍）。`GenesisCreditFactory.deployCredit` 必须拒绝非 18-dec `uAsset`（revert `InvalidUAssetDecimals`），`POLend.leveragedGenesisWithCredit` 首次缓存 credit token 前也必须校验 18-dec（revert `CreditDecimalsMismatch`，防止可替换 `creditFactory` 指针绕过 factory 边界）。放开 credit path 到非 18-dec `uAsset`、或改 GenesisCredit 为可变 decimals，属于产品规则变化，必须先经人工确认。

### 4.4 普通 Swap 动态费与 v4 费用边界 `[代码已证]`

已批准的普通单池动态 Swap 规则是：对原始 exact-input 输入或原始 exact-output 净输出选费一次；不得用变换后的核心目标、费用、本笔 fee-induced flow、协议费币腿或用户原始价格限制再次选费。审阅不得把 fee-on-fee、自递归或多轮估算作为安全修复重新引入。

安全审阅必须区分实际核心 delta 和最终用户 delta：前者用于成交完整性、状态更新和 Hook 结算；后者才是 Router 的最小输出/最大输入保护依据。不同币种的金额不得相加形成虚假的总费用；referral rebate 不得超过该笔实际 protocol fee。普通动态费的四条请求/协议费币腿路径属于产品规则，固定费路径继续使用 `FeeMath.feeOnAmount`，两者不能互相替代。

原始价格限制仅决定交易是否可完整执行，不能影响已选 `feeBps`。全范围端点 equality 必须拒绝：它会耗尽唯一仓位并可能令活跃流动性归零。exact-output 仍是支持的公开请求类型；非零 100% exact-output、不可完整成交或不可表示的金额必须拒绝，不能返回部分成交或无穷大哨兵金额。

v4 LP fee 的源码结构事实是：新池初始化为零、当前没有 `updateDynamicLPFee`、普通 `beforeSwap` 不返回 fee override。本任务不为这些事实增加 runtime、首次发布、持续治理或运维控制。PoolManager protocol fee 是外部 controller 的行为，不受 Memeverse 权限或保证，也不属于本任务的 protocol fee 模型。

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
