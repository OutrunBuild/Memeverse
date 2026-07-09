# MemeverseV2 事件面（用户 / 索引器 / 运维）

## 1. 说明

本文覆盖“对用户、索引器、运维有直接价值”的已发出事件，以及明确标注为目标事件规格的 target-only 条目。
标签说明：

- `[代码已证]`：当前实现直接 `emit`
- `[目标规范]`：目标事件规范，当前实现尚未直接 `emit`
- `[已知缺口]`：业务动作存在，但没有对应事件或难以完整重建
- `[未知]`：需依赖链外系统或外部协议事件

## 2. 用户与索引主事件

### 2.1 注册与生命周期

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `Registration(uint256 indexed uniqueId, RegistrationParam param)` | `MemeverseRegistrationCenter` | 中心链注册成功后 | 跟踪 symbol 占用与参数快照 |
| `RegisterMemeverse(verseId,verse)` | `MemeverseLauncher` | launcher 完成新 verse 写入 | 建立 verse 主索引 |
| `Genesis(verseId,user,...)` | `MemeverseLauncher` | Genesis 入金成功 | 跟踪募资累计 |
| `Preorder(verseId,caller,user,amountInUAsset)` | `MemeverseLauncher` | Preorder 入金成功 | preorder 资金流入与累计索引；区分 caller 与 user 覆盖 relayer 场景 |
| `ChangeStage(verseId,currentStage)` | `MemeverseLauncher` | `changeStage` 每次成功执行 | 生命周期状态索引 |
| `Refund(verseId,receiver,amount)` | `MemeverseLauncher` | Genesis 退款成功 | 退款账本 |
| `RefundPreorder(uint256 indexed verseId,address indexed receiver,uint256 refundAmount)` | `MemeverseLauncher` | Preorder 退款成功 | preorder 退款账本；`[代码已证]` |
| `ClaimNormalYT(...)` | `MemeverseLauncher` | 普通创世初始 YT 领取成功 | 初始 YT claim 索引 |
| `ClaimNormalFees(verseId,receiver,uAssetAmount,ptAmount)` | `MemeverseLauncher` | 普通侧辅助池手续费领取成功 | 普通侧 uAsset/PT fee claim 索引；settled 后 PT 已兑换为 uAsset，ptAmount=0 |
| `ClaimPreorderMemecoin(verseId,user,amount)` | `MemeverseLauncher` | Unlocked 后 preorder memecoin 领取成功 | preorder memecoin vested claim 索引 |
| `MintPOLToken(...)` | `MemeverseLauncher` | Locked 后用户主动加池并 mint POL 成功 | 加池 POL 头寸变动；不代表 Genesis 初始 POL claim |
| `RedeemMemecoinLiquidity(...)` | `MemeverseLauncher` | unlock 后主池退出成功 | 主池退出路径索引 |
| `RedeemAuxiliaryLiquidity(verseId,user,polUAssetLpAmount,ptUAssetLpAmount,ptPolLpAmount)` | `MemeverseLauncher` | Unlocked 后辅助池 LP 退出成功 | 辅助池退出路径索引；携带三类 LP 精确金额 |
| `BootstrapUnusedAssetsHandled(uint256 indexed verseId,address indexed uAsset,address indexed memecoin,uint256 unusedUAsset,uint256 creditedSettlementDustReserve,uint256 treasuryExcess,uint256 burnedMemecoin)` | `MemeverseLauncher` | Locked 流动性部署后处理未进入池的 bootstrap 资产 | 将 Launcher unused bootstrap 来源与 POLend 全局 reserve funding / memecoin burn 结果关联；`[代码已证]` |
| `RedeemAndDistributeFees(...)` | `MemeverseLauncher` | 费用赎回分发成功 | 执行者奖励与收益分账。字段语义：`polFee` 是被永久 burn 的 POL 数量（POL fee 在 `src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees` 内 burn，不分发给任何接收方）；`govFee` / `memecoinFee` 经 yieldDispatcher 分发（同链 `distributeSameChain`）或跨链 `IOFT.send`；`executorReward` 发给 `rewardReceiver` |
| `SetExternalInfo(...)` | `MemeverseLauncher` | 外部元数据更新 | 前端展示元数据刷新 |

除标注为目标事件规格的条目外，以上均为 `[代码已证]`。

**`genesisAndPreorder(...)` 合并入口事件**：该原子入口依次 emit `Genesis(verseId, user, genesisAmount)` 与 `Preorder(verseId, caller, user, preorderAmount)` 各一次，字段结构分别与单次 `genesis` / `preorder` 调用完全一致（`Preorder.caller` 仍为 `msg.sender`/payer），不新增事件。语义与容量校验见 [docs/spec/polend/genesis.md §2](polend/genesis.md)。

### 2.2 POLend / POLSplitter 目标事件面

本节描述 [docs/spec/polend/README.md](polend/README.md) 要求的目标事件面。若当前代码未 emit，对索引器而言是 current vs target gap，不能标成 `[代码已证]`。

| 事件 | 触发模块 | 触发时机 | 用途 | 状态 |
| --- | --- | --- | --- | --- |
| `LeveragedGenesis(uint256 indexed verseId,address indexed user,uint256 interestAmount)` | `POLend` | 用户在 Genesis 支付杠杆利息成功 | 杠杆创世参与与利息累计索引 | `[代码已证]` |
| `ClaimLeveragedYT(uint256 indexed verseId,address indexed user,address indexed to,uint256 amount)` | `POLend` | 杠杆创世初始 YT 领取成功 | leveraged YT claim 索引 | `[代码已证]` |
| `ClaimResidual(uint256 indexed verseId,address indexed user,address indexed to,uint256 uAssetAmount,uint256 memecoinAmount)` | `POLend` | 全局结算后杠杆残值领取成功 | leveraged residual claims 索引 | `[代码已证]` |
| `PreRedeemPTFee(uint256 indexed verseId,address indexed uAsset,uint256 ptAmount,uint256 uAssetBacking,address mintTo)` | `POLend` | settle 前杠杆侧 PT fee 预兑付 | PT fee 预兑付、债务增加与后续 backing 对账 | `[代码已证]` |
| `DefaultInterestRateChanged(uint256 oldRate,uint256 newRate)` | `POLend` | owner 修改默认利率 | 新注册 market 利率参数索引；不影响已注册 market | `[代码已证]` |
| `LeveragedDebtFactorChanged(uint256 oldFactor,uint256 newFactor)` | `POLend` | owner 修改全局杠杆债务上限系数 | 新增杠杆创世 debt cap 参数索引；不影响已 mint 债务 | `[代码已证]` |
| `ProtocolTreasuryChanged(address indexed oldTreasury,address indexed newTreasury)` | `POLend` | owner 修改 POLend protocol treasury | 杠杆利息 treasury 变更索引；与 Memeverse DAO governor treasury 不同 | `[代码已证]` |
| `SettlementDustReserveConfigured(address indexed uAsset,uint128 oldMaxReserve,uint128 newMaxReserve)` | `POLend` | owner 配置某 `uAsset` 的全局 reserve 上限 | reserve 上限变更审计 | `[代码已证]` |
| `SettlementDustReserveFunded(address indexed uAsset,address indexed funder,uint256 amount,uint256 credited,uint256 excess)` | `POLend` | 手动 fund 或 Launcher 注入 bootstrap unused `uAsset` | reserve 注入、over-capacity excess 审计；非 Launcher 成功事件中 `excess == 0`；Launcher bootstrap 来源由 `BootstrapUnusedAssetsHandled` 携带 `verseId` | `[代码已证]` |
| `SettlementDustReserveConsumed(uint256 indexed verseId,address indexed uAsset,uint256 consumed,uint256 reserveAfter)` | `POLend` | `executeGlobalSettlement` 消耗全局 reserve 补足 bounded deficit | reserve 消耗审计 | `[代码已证]` |
| `GlobalSettlementExecuted(uint256 indexed verseId,address indexed uAsset,uint256 verseDebt,uint256 recoveredUAsset,uint256 consumedSettlementDustReserve,uint256 settlementDustReserveAfter,uint256 residualUAsset,uint256 residualMemecoin)` | `POLend` | `executeGlobalSettlement` 成功完成 | 债务偿还、reserve 消耗后余额、residual 记账审计 | `[代码已证]` |
| `RedeemPT(uint256 indexed verseId,address indexed from,address indexed to,uint256 ptAmount)` | `POLSplitter` | settle 后 PT 兑付 | PT 兑付流水索引 | `[代码已证]` |
| `RedeemYT(uint256 indexed verseId,address indexed from,address indexed to,uint256 ytAmount,uint256 uAssetAmount,uint256 memecoinAmount)` | `POLSplitter` | settle 后 YT 兑付 | YT 兑付流水索引 | `[代码已证]` |
| `LeveragedGenesisWithCredit(uint256 indexed verseId,address indexed user,uint256 creditAmount)` | `POLend` | 用户在 Genesis 用 GenesisCredit 抵扣杠杆利息成功 | 杠杆创世 credit 抵扣参与与 credit 利息累计索引；`creditInterestPaid` 与 `market.totalCreditInterest` 同步累加 | `[代码已证]` |
| `CreditBurned(uint256 indexed verseId,address indexed uAsset,uint256 totalCreditInterest)` | `POLend` | `finalizeLeveragedGenesis` 烧毁该 verse 托管的 GenesisCredit（量 = 该 verse `market.totalCreditInterest`） | 杠杆 finalize 的 GenesisCredit 销毁审计；承载 credit 部分证据（`CreditBurned.totalCreditInterest` 是 credit 部分；real 部分为 `totalLeveragedInterest - totalCreditInterest`，由 finalize 全额清扫至 `protocolTreasury`，二者合起来对应 `market.totalLeveragedInterest`） | `[代码已证]` |
| `ClaimRefund(uint256 indexed verseId,address indexed user,address indexed to,uint256 refundedAmount)` | `POLend` | `claimRefund` 在 Refund 终态把 real-uAsset 利息退回给用户 | Refund 终态的 real `uAsset` 退回流水索引；与 credit 部分 GenesisCredit 退回物理隔离；credit-only 参与者不触发（`realPaid==0`） | `[代码已证]` |
| `CreditRefunded(uint256 indexed verseId,address indexed user,address indexed to,uint256 amount)` | `POLend` | `claimRefund` 在 Refund 终态把 GenesisCredit 托管余额退回给 credit 用户 | Refund 终态的 GenesisCredit 退回流水索引；与 real 部分 `uAsset` 退回物理隔离 | `[代码已证]` |
| `CreditFactoryChanged(address indexed oldFactory,address indexed newFactory)` | `POLend` | `setCreditFactory` 替换 `GenesisCreditFactory` 地址指针 | credit 工厂地址替换审计；影响后续 `leveragedGenesisWithCredit` 按 `uAsset` 查 GenesisCredit 的路径 | `[代码已证]` |

目标事件面必须覆盖 `POLend.executeGlobalSettlement(...)` 产生的 leveraged residual 与 settlement dust reserve 记账结果，以及 GenesisCredit 抵扣路径（`leveragedGenesisWithCredit` / `finalizeLeveragedGenesis` burn / Refund 退 credit / `setCreditFactory`）产生的会计与配置变化。若实现只依赖 token transfer 或内部状态变化，则属于事件面缺口。

### 2.3 GenesisCredit 冷启动层

| 事件 | 触发模块 | 触发时机 | 用途 | 状态 |
| --- | --- | --- | --- | --- |
| `CreditDeployed(address indexed uAsset,address indexed credit)` | `GenesisCreditFactory` | owner 调 `deployCredit` 成功后 | per-uAsset GenesisCredit 地址发现、冷启动索引、部署审计 | `[代码已证]` |
| `MerkleRootSet(bytes32 merkleRoot)` | `GenesisCredit` | owner 调 `setMerkleRoot` 成功后 | merkle claim root 配置审计、claim 数据版本追踪 | `[代码已证]` |
| `Claimed(address indexed user,uint256 amount)` | `GenesisCredit` | home-chain merkle claim 成功后 | 用户 claim 流水、空投供应索引；区分 claim mint 与 OFT inbound mint | `[代码已证]` |

### 2.4 Swap 与 LP

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `PoolInitialized` | `MemeverseUniswapHook` | 池初始化 | poolId 与 LP token 建档 |
| `LiquidityAdded` / `LiquidityRemoved` | `MemeverseUniswapHook` | Core 加减池 | LP 头寸变动 |
| `LPFeeCollected` / `ProtocolFeeCollected` | `MemeverseUniswapHook` | fee 归集时 | 手续费归属跟踪 |
| `FeesClaimed` | `MemeverseUniswapHook` | LP 提取收益时 | 已领取 fee 对账 |
| `PublicSwapResumeTimeUpdated` | `MemeverseUniswapHook` | pool-level 公开 swap 恢复时间更新 | unlock 后公开 swap 保护窗口可观测性 |
| `ReferralRebateAccrued(address indexed referrer,address currency,uint256 amount)` | `MemeverseDynamicFeeEngine` | 普通 swap 携带非零 referrer 且 `amount > 0` 时，hook 先在 `_collectProtocolFee` 内 `poolManager.take` 把 rebate 拉到 engine 地址，`accrueRebate` 纯记账（`pendingRebate[referrer][currency] += amount`）后 emit（`referrer == address(0)` 或 `amount == 0` 时 no-op：hook 不 take、`accrueRebate` 不记账 / 不 emit） | 返佣累计；索引器统计 protocol 总收入须同时读 hook 的 `ProtocolFeeCollected`（treasury 实收 `toTreasury`）与 engine 的 `ReferralRebateAccrued`，二者之和等于该 swap 的完整 protocolFee。**indexed**：`referrer` indexed，可按 referrer 直接 filter；`currency` 未 indexed，按 currency（per-token 统计）对账须扫全表聚合 distinct currency |
| `ReferralRebateClaimed(address indexed referrer,address indexed recipient,address currency,uint256 amount)` | `MemeverseDynamicFeeEngine` | referrer 调 `claimRebate` 领取 accrued rebate 并 transfer 成功后 | 返佣领取流水；`pendingRebate` 清零先于 external transfer（CEI）。**indexed**：`referrer` 与 `recipient` 均可按地址直接 filter；`currency` 未 indexed，per-token 对账须扫全表聚合 |
| `ReferrerRebateBpsUpdated(oldBps,newBps)` | `MemeverseDynamicFeeEngine` | `setReferrerRebateBps` 成功后（owner 经 hook wrapper 转发） | 全局返佣率变更审计；engine `initialize` 时以 `(0, 1000)` 触发一次 |

以上均为 `[代码已证]`。

**返佣对 `ProtocolFeeCollected.amount` 语义的影响**：带 referrer 的普通 swap 中，`ProtocolFeeCollected.amount`（on hook）是 treasury 实收 `toTreasury = protocolFee - rebate`，严格小于该 swap 的完整 protocolFee；差额在 engine 上的 `ReferralRebateAccrued.amount`。无 referrer 或 preorder settlement 路径下 `ProtocolFeeCollected.amount` 仍是完整 protocol fee。索引器 / 财务对账若按 swap 维度统计 protocol 总收入，必须把同一 swap 的 `ProtocolFeeCollected` 与 `ReferralRebateAccrued` 求和，否则会漏计 rebate 部分。

### 2.5 Yield / Governance / Cross-chain

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `Deposit` / `RedeemRequested` / `RedeemExecuted` / `AccumulateYields` | `MemecoinYieldVault` | 存入、排队赎回、执行赎回、收益累积 | vault 份额与收益流水 |
| `CycleStarted` / `CycleFinalized` / `RewardClaimed` / `TreasuryIncomeRecorded` / `TreasuryAssetSpendRecorded` 等 | `GovernanceCycleIncentivizerUpgradeable` | 治理周期与奖励账本变化 | 治理奖励索引 |
| `OFTProcessed` | `YieldDispatcher` | OFT compose 到账处理 | 收益路由或 burn 结果 |
| `OmnichainMemecoinStaking` / `OmnichainMemecoinStakingProcessed` | interoperation/staker | 发起远端 staking / 远端处理完成 | 跨链 staking 追踪 |

以上均为 `[代码已证]`。

## 3. 运维配置事件

重点配置事件（均 `[代码已证]`）：

- Launcher：`SetMemeverseSwapRouter`、`SetFundMetaData`、`SetExecutorRewardRate`、`SetPreorderConfig`、`SetGasLimits`、`SetLaunchImpl`、`SetSettlementImpl`、`SetLiquidityImpl`、`SetFeePreviewReader` 等
  - `SetLaunchImpl(address indexed launchImpl)`：launch sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setLaunchImpl(...)` 替换时均以新接线地址 `(launchImpl)` 单值触发。事件不携带旧值，旧值需通过历史日志或 `getLauncherContracts()` 快照对比获取。`[代码已证]`
  - `SetSettlementImpl(address indexed settlementImpl)`：settlement sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setSettlementImpl(...)` 替换时触发，单值不携带旧值。`[代码已证]`
  - `SetLiquidityImpl(address indexed liquidityImpl)`：liquidity sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setLiquidityImpl(...)` 替换时触发，单值不携带旧值。`[代码已证]`
  - `SetFeePreviewReader(address indexed feePreviewReader)`：fee-preview reader 地址替换事件，owner-level；脚本单角色模式部署期与 owner `setFeePreviewReader(...)` 替换时触发，单值不携带旧值。`[代码已证]`
- RegistrationCenter：`SetSupportedUAsset`、`SetDurationDaysRange`、`SetRegisterGasLimit`
- Hook：`TreasuryUpdated`、`ProtocolFeeCurrencySupportUpdated`、`LauncherUpdated`、`PoolInitializerUpdated`、`PoolInitializationAuthorized`、`DefaultLaunchFeeConfigUpdated`、`DynamicFeeEngineUpdated`、`LPTokenImplementationUpdated`、`PreorderSettlementExecutorUpdated`
  - `DynamicFeeEngineUpdated`：在 `upgradeDynamicFeeEngine` 中 emit，标记 engine pointer 替换（非 implementation 升级）。
  - `PoolInitializationAuthorized`：一次性授权消费事件，记录单次池初始化授权。
  - `LPTokenImplementationUpdated`：LP token clone 模板替换事件；`initialize` 时以 `(address(0), impl)` 触发，`setLpTokenImplementation` 时以 `(old, new)` 触发。
  - `PreorderSettlementExecutorUpdated`：preorder settlement executor 替换事件，owner-level 安全 retarget；`initialize` 时以 `(address(0), executor)` 触发，`setPreorderSettlementExecutor` 时以 `(old, new)` 触发。
- Engine（`MemeverseDynamicFeeEngine`）：`ReferrerRebateBpsUpdated`（owner 经 hook wrapper `setReferrerRebateBps` 转发到 engine setter；engine `initialize` 时以 `(0, 1000)` 触发一次）。
- Interoperation：`SetGasLimits`
- ProxyDeployer：`SetQuorumNumerator`

运维清理事件（均 `[代码已证]`）：

- Launcher：`RemoveGasDust(address indexed receiver,uint256 dust)`，owner-only 清理 Launcher native gas dust 时发出。

## 4. 已知事件缺口与解释

- `preorder(...)`、`claimUnlockedPreorderMemecoin(...)`、`redeemAuxiliaryLiquidity(...)` 已实现专用事件（`Preorder`、`ClaimPreorderMemecoin`、`RedeemAuxiliaryLiquidity`）。不再属于 Launcher 事件面缺口。
- `refundPreorder(...)` 的目标事件规格为 `RefundPreorder(uint256 indexed verseId,address indexed receiver,uint256 refundAmount)`；实现 emit 后不再属于 Launcher 事件面缺口。
- POLend / POLSplitter 目标事件面大多已实现；`burnPreRedeemedBacking` 保持可调用 settle 行为，但不要求专用 emitted event。
- Router 自身没有业务事件（swap/add/remove/permit2 路径）；链上索引主要依赖 Hook 事件与 token transfer。`[已知缺口]`
- `changeStage` 在 `Locked` 且未到 `unlockTime` 时也会发 `ChangeStage(..., Locked)`；索引器不能仅凭事件判断“是否真的迁移”。`[已知缺口]`
- 当前实现没有“保护窗口开始/结束”的专用阶段或专用事件，也没有 dedicated event 单独标记 `publicSwapResumeTime` 的激活或到期；索引器需要结合 stage、实际 `Locked -> Unlocked` 迁移交易时间、固定保护窗口（`UNLOCK_PROTECTION_WINDOW`，数值见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md)）与 swap 成败联合判断“unlock 后保护中”与“完全开放交易”的状态。`[已知缺口]`
- `SetExternalInfo` 事件携带的是本次传入数组；合约内 `communitiesMap` 为按索引覆盖，旧尾部数据可能保留，事件本身无法单独重建完整当前快照。`[已知缺口]`
- LayerZero endpoint / PoolManager 等外部协议事件不在本仓库定义。`[未知]`

## 5. 确定性边界

- 除明确标注为目标事件规格或 target-only 的条目外，本文只覆盖仓库 `src/**` 明确 `emit` 的事件。
- 继承自 OpenZeppelin 的通用事件（如 `Paused/Unpaused`、`OwnershipTransferred`）存在，但未作为 Memeverse 业务主索引面展开。
