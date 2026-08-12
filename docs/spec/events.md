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
| `VerseInitialized(uint256 indexed verseId,address indexed pt,address indexed yt)` | `POLSplitter` | `initializeVerse` 成功 | verseId↔PT/YT 地址映射锚点，索引 PT/YT 流通面与兑付事件的前提 | `[代码已证]` |
| `Split(uint256 indexed verseId,address indexed user,uint256 polAmount,uint256 ptAmount,uint256 ytAmount)` | `POLSplitter` | `split` 成功 | per-verse POL 抵押品流入与 PT/YT 增发索引 | `[代码已证]` |
| `Merge(uint256 indexed verseId,address indexed user,uint256 amount,uint256 polAmount)` | `POLSplitter` | `merge` 成功 | per-verse POL 抵押品流出与 PT/YT 回收索引 | `[代码已证]` |
| `BackingRatioRecorded(uint256 indexed verseId,uint256 numerator,uint256 denominator)` | `POLSplitter` | `recordPTBackingRatio` 成功 | 每单位 PT 赎回价值参数记录索引；一次性写入（二次调用 revert） | `[代码已证]` |
| `VerseSettled(uint256 indexed verseId,uint256 settlementUAsset,uint256 settlementMemecoin)` | `POLSplitter` | `settle` 成功 | 结算池终值锚点(settlementUAsset 为扣 pre-redeemed uAsset backing 后金额),settled 状态翻转索引 | `[代码已证]` |
| `LeveragedGenesisWithCredit(uint256 indexed verseId,address indexed user,uint256 creditAmount)` | `POLend` | 用户在 Genesis 用 GenesisCredit 抵扣杠杆利息成功 | 杠杆创世 credit 抵扣参与与 credit 利息累计索引；`creditInterestPaid` 与 `market.totalCreditInterest` 同步累加 | `[代码已证]` |
| `CreditBurned(uint256 indexed verseId,address indexed uAsset,uint256 totalCreditInterest)` | `POLend` | `finalizeLeveragedGenesis` 烧毁该 verse 托管的 GenesisCredit（量 = 该 verse `market.totalCreditInterest`） | 杠杆 finalize 的 GenesisCredit 销毁审计；承载 credit 部分证据（`CreditBurned.totalCreditInterest` 是 credit 部分；real 部分为 `totalLeveragedInterest - totalCreditInterest`，由 finalize 全额清扫至 `protocolTreasury`，二者合起来对应 `market.totalLeveragedInterest`） | `[代码已证]` |
| `LendMarketRegistered(uint256 indexed verseId,address indexed uAsset,uint256 interestRate)` | `POLend` | `registerLendMarket` 成功注册 verse 杠杆市场 | 市场注册锚点：uAsset 绑定与注册时利率快照索引；后续 state 迁移起点 | `[代码已证]` |
| `MarketRefundable(uint256 indexed verseId)` | `POLend` | `markRefundable` 把 Genesis 市场迁至 `Refund` 终态 | 失败 verse 退款资格翻转索引；`claimRefund` 触发前提 | `[代码已证]` |
| `LeveragedGenesisFinalized(uint256 indexed verseId,address indexed uAsset,uint256 debt,uint256 realInterestSwept,uint256 creditBurned)` | `POLend` | `finalizeLeveragedGenesis` 把 Genesis 市场迁至 `Locked` 并锁债 | 成功 verse 锁债(debt mint)与 treasury 清扫审计；无条件发射(real-only 市场 `creditBurned==0`)；credit-only 市场 `realInterestSwept==0` | `[代码已证]` |
| `LeveragedYTRecorded(uint256 indexed verseId,address indexed yt,uint256 totalLeveragedYT)` | `POLend` | `recordLeveragedYT` 记录锁定 verse 的 YT 与分发总量 | YT 绑定与 pro-rata 分发总量索引 | `[代码已证]` |
| `ClaimRefund(uint256 indexed verseId,address indexed user,address indexed to,uint256 refundedAmount)` | `POLend` | `claimRefund` 在 Refund 终态把 real-uAsset 利息退回给用户 | Refund 终态的 real `uAsset` 退回流水索引；与 credit 部分 GenesisCredit 退回物理隔离；credit-only 参与者不触发（`realPaid==0`） | `[代码已证]` |
| `CreditRefunded(uint256 indexed verseId,address indexed user,address indexed to,uint256 amount)` | `POLend` | `claimRefund` 在 Refund 终态把 GenesisCredit 托管余额退回给 credit 用户 | Refund 终态的 GenesisCredit 退回流水索引；与 real 部分 `uAsset` 退回物理隔离 | `[代码已证]` |
| `CreditFactoryChanged(address indexed oldFactory,address indexed newFactory)` | `POLend` | `setCreditFactory` 替换 `GenesisCreditFactory` 地址指针 | credit 工厂地址替换审计；影响后续 `leveragedGenesisWithCredit` 按 `uAsset` 查 GenesisCredit 的路径 | `[代码已证]` |

目标事件面必须覆盖 `POLend.executeGlobalSettlement(...)` 产生的 leveraged residual 与 settlement dust reserve 记账结果，以及 GenesisCredit 抵扣路径（`leveragedGenesisWithCredit` / `finalizeLeveragedGenesis` burn / Refund 退 credit / `setCreditFactory`）产生的会计与配置变化。若实现只依赖 token transfer 或内部状态变化，则属于事件面缺口。

### 2.3 GenesisCredit 冷启动层

| 事件 | 触发模块 | 触发时机 | 用途 | 状态 |
| --- | --- | --- | --- | --- |
| `CreditDeployed(address indexed uAsset,address indexed credit)` | `GenesisCreditFactory` | owner 调 `deployCredit` 成功后 | per-uAsset GenesisCredit 地址发现、冷启动索引、部署审计 | `[代码已证]` |
| `MerkleRootSet(bytes32 merkleRoot)` | `GenesisCredit` | owner 调 `setMerkleRoot` 成功后 | merkle claim root 配置审计、claim 数据版本追踪（版本追踪仅能外部记录：`MerkleRootSet` 无旧值参数） | `[代码已证]` |
| `Claimed(address indexed user,uint256 amount)` | `GenesisCredit` | home-chain merkle claim 成功后 | 用户 claim 流水、空投供应索引；区分 claim mint 与 OFT inbound mint | `[代码已证]` |

### 2.4 Swap 与 LP

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `PoolInitialized(PoolId indexed poolId, address indexed liquidityToken, Currency indexed currency0, Currency currency1)` | `MemeverseUniswapHook` | 池初始化 | poolId 与 LP token 建档 |
| `LiquidityAdded(PoolId indexed poolId, address indexed provider, address indexed to, uint128 liquidity, uint256 amount0, uint256 amount1)` | `MemeverseUniswapHook` | Core 加减池 | LP 头寸变动 |
| `LiquidityRemoved(PoolId indexed poolId, address indexed provider, uint128 liquidity, uint256 amount0, uint256 amount1)` | `MemeverseUniswapHook` | Core 加减池 | LP 头寸变动 |
| `LPFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 feePerShare, uint256 blockNumber)` | `MemeverseUniswapHook` | fee 归集时 | LP 每份额费用累计跟踪。可按 pool/currency 直接 filter |
| `ProtocolFeeCollected(PoolId indexed poolId, Currency indexed currency, address indexed treasury, uint256 amount, uint256 blockNumber)` | `MemeverseUniswapHook` | fee 归集时 | 协议费归集跟踪。可按 treasury 直接 filter 做 per-treasury 对账 |
| `FeesClaimed(PoolId indexed poolId, address indexed user, Currency indexed currency0, Currency currency1, uint256 fee0Amount, uint256 fee1Amount)` | `MemeverseUniswapHook` | LP 提取收益时 | 已领取 fee 对账 |
| `PublicSwapResumeTimeUpdated(PoolId indexed poolId, uint40 oldResumeTime, uint40 newResumeTime)` | `MemeverseUniswapHook` | pool-level 公开 swap 恢复时间更新 | unlock 后公开 swap 保护窗口可观测性 |
| `ReferralRebateAccrued(address indexed referrer, Currency indexed currency, uint256 amount)` | `MemeverseUniswapHook`(Router，经 `SwapFacet::_settleProtocolFee` 内联 emit；`_collectProtocolFee` 与 beforeSwap 主路径均调它) | 普通 swap 携带非零 referrer 且 `amount > 0` 时 | 返佣累计。可按 referrer/currency 直接 filter |
| `ReferralRebateClaimed(address indexed referrer, address indexed recipient, Currency indexed currency, uint256 amount)` | `MemeverseUniswapHook`(Router 直接实现) | referrer 调 `MemeverseUniswapHook::claimRebate` 领取 accrued rebate 并 transfer 成功后 | 返佣领取流水。可按 referrer/recipient/currency 直接 filter |
| `ReferrerRebateBpsUpdated(uint256 oldBps, uint256 newBps)` | `MemeverseUniswapHook`(Router 直接实现) | `setReferrerRebateBps` 成功后（hook `onlyOwner` 直接写 storage） | 全局返佣率变更审计；hook `initialize` 时以 `(0, 1000)` 触发一次 |
| `YTFlashSwapPOLForYT(uint256 indexed verseId, address indexed payer, address indexed recipient, uint256 exactYTOut, uint256 polInUsed, address referrer)` | `MemeverseYTFlashSwapRouter` | `swapPOLForExactYT` 全部 delta/余额/allowance 结清并 baseline 恢复后 | POL→精确 YT flash swap 成交流水；`payer` 恒为 `msg.sender`。`[代码已证]` |
| `YTFlashSwapYTForPOL(uint256 indexed verseId, address indexed payer, address indexed recipient, uint256 exactYTIn, uint256 polOut, address referrer)` | `MemeverseYTFlashSwapRouter` | `swapExactYTForPOL` 全部 delta/余额结清并 baseline 恢复后 | 精确 YT→POL flash swap 成交流水；`payer` 恒为 `msg.sender`。`[代码已证]` |

以上均为 `[代码已证]`。

**返佣对 `ProtocolFeeCollected.amount` 语义的影响**：`ProtocolFeeCollected.amount`（on hook）始终是 treasury 实收 `toTreasury = protocolFee - rebate`。普通 swap 携带非零 referrer **且** 计算出的 `rebate > 0` 时，`toTreasury < protocolFee`，差额在同笔 swap 的 `ReferralRebateAccrued.amount`。以下情况即使有 referrer，`rebate` 仍可为 0，此时 `ProtocolFeeCollected.amount` **等于**完整 protocol fee，且不 emit `ReferralRebateAccrued`：（1）`referrerRebateBps == 0`；（2）`FullMath.mulDiv(protocolFee, rebateBps, PROTOCOL_FEE_SHARE_BPS)` 向下取整为 0。无 referrer 或 preorder settlement 路径下无返佣，`ProtocolFeeCollected.amount` 为完整 protocol fee。索引器 / 财务对账按 swap 维度统计 protocol 总收入时：`ProtocolFeeCollected.amount +（若本笔 emit 了 `ReferralRebateAccrued` 则其 amount，否则 0）= protocolFee`；不要仅凭「存在 referrer」假定国库金额严格变小。

**`ReferralRebateAccrued` 的 CEI 与触发边界**：`_settleProtocolFee` 先写 `pendingRebate[referrer][currency] += amount` 并 emit 本事件（effect），再经 `_takeToTreasury` 调用 `PoolManager.take` 转出 treasury 份额（interaction），最后 emit `ProtocolFeeCollected`；记账本身是纯 storage effect，先于 treasury take 与调用方执行的 rebate take。该 helper 现为严格 CEI（effect → interaction → event）：`ReferralRebateAccrued` 先于 `ProtocolFeeCollected` emit；treasury take 不触发 v4 hook callback，但 ERC20 currency 会执行外部 `transfer` token 代码。beforeSwap 主路径将 rebate 与 LP fee 合并 take，afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。所有步骤在同一 swap 事务中执行，任一 take 或 token transfer 失败都会回滚账本和事件；安全边界要求 fee currency 为标准 ERC20（注册的协议费代币；普通池下为输入代币）、treasury 保持被动收款（`referrer == address(0)` 或 `amount == 0` 时不记账、不 emit rebate 事件）。

**`ReferralRebateClaimed` 的 CEI**：`pendingRebate` 清零先于 external transfer（CEI）。

### 2.4.1 Token 模块（Memecoin / MemePol）

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `Transfer(address indexed from, address indexed to, uint256 value)` | `Memecoin` / `MemePol`（经 `OutrunERC20Init._update`，`src/common/token/OutrunERC20Init.sol::_update`） | mint 为 `Transfer(0x0, account)`、burn 为 `Transfer(account, 0x0)`、转账为 `Transfer(from, to)` | token 供给变更的见证事件；mint/burn 由零地址方向标识。可按 from/to 直接 filter |
| `OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD)` | `Memecoin` / `MemePol`（经 `OutrunOFTCoreInit.sol::send`） | 源端跨链发出成功 | 源端跨链转出流水；可按 `fromAddress` 直接 filter |
| `OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD)` | `Memecoin` / `MemePol`（经 `OutrunOFTCoreInit.sol::_lzReceive`） | 目的端到账成功 | 目的端跨链到账流水；可按 `toAddress` 直接 filter |
| `PoolIdSet(PoolId indexed oldPoolId, PoolId indexed newPoolId)` | `MemePol`（经 `setPoolId`，`src/token/MemePol.sol::setPoolId`） | launcher 设置/重设 pool id 时 | POL 池关联变更可观测。`setPoolId` 无 one-shot guard 可重设，每次写入均 emit；`oldPoolId` 为被覆盖的旧值，首次设置时为 `bytes32(0)`；`newPoolId` 为新值 |

以上均为 `[代码已证]`。

**`Transfer` 与供给守恒**：mint（`from = address(0)`）与 burn（`to = address(0)`）是 token 单通道供给变更的见证；守恒语义见 [docs/spec/invariants.md INV-09A](invariants.md)。OFT 回归官方 OFTCore 后，公开 send 路径不再产生 COMMON-001 跨链通胀例外（源端 burn 1X、目的端单次 mint 1X）。

**`OFTReceived` 的 to=0 语义**：`send` 传 `to = bytes32(0)` 时，事件 `toAddress` 参数与 `endpoint.sendCompose` 路由均使用重映射前的 `address(0)`（`OutrunOFTCoreInit.sol::_lzReceive` 直接使用消息解码出的 `toAddress`），而余额经 `OutrunOFTInit.sol::_credit` 重映射后实际 mint 至 `0xdead` 哨兵；事件 toAddress 与余额落点不一致，按 `toAddress` 过滤的监控需知悉该分叉。同时该路由在 endpoint 队列留下**永久 pending 槽**：`MessagingComposer.sendCompose` 对 `to` 无守卫，照写 `composeQueue[token][0][guid][0] = keccak256(message)` 并 emit `ComposeSent`；该槽无收敛路径——`MessagingComposer.lzCompose` 对无代码目标（0 地址/普通 EOA）的高层调用经 solc 0.8.x EXTCODESIZE 前置检查 revert（`RECEIVED_MESSAGE_HASH` 写入随整笔交易回滚），executor 投递同样 revert（`LzComposeAlert` + 重试恒失败），同槽重写 `sendCompose` 报 `LZ_ComposeExists`，故槽位永久停留 `keccak256(message)`，监控信号为 `ComposeSent` 恒无对应 `ComposeDelivered`（预期终态，不可修复）。同族一般化：`to` 为任意无 composer 代码地址（含普通 EOA——用户普通 OFT 转账误带非空 composeMsg 即触发，非自伤）时机制相同。operations.md §3.13 步骤 4 的免许可 `lzCompose` 重驱动仅对实现 `lzCompose` 的 composer 目标（dispatcher/staker）成立，对无代码目标不适用。`[代码已证]`

### 2.5 Yield / Governance / Cross-chain

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `Deposit` / `RedeemRequested` / `RedeemExecuted` | `MemecoinYieldVault` | 存入、排队赎回、执行赎回 | vault 份额与赎回流水 |
| `AccumulateYields(address indexed yieldSource, uint256 yield, uint256 exchangeRate)` | `MemecoinYieldVault` | `MemecoinYieldVault.sol::_accumulateYield` 非空仓分支收益入账后 | vault 收益流水；`exchangeRate` 为 yield 入账后的快照 = `1e18 * (totalAssets + virtualAssets) / (totalSupply() + virtualAssets)`（永久虚拟资产缓冲（`virtualAssets`）阻尼，口径见 [governance-yield-details.md §4.1](governance/governance-yield-details.md)），即每 1e18 份额的资产价值；`yieldSource` 为收益入账发起方（`msg.sender`，协议路径为 yield dispatcher）；`[代码已证]` |
| `CycleStarted(uint128 indexed cycleId, uint128 startTime, uint128 endTime, address[] tokens, uint256[] balances)` | `GovernanceCycleIncentivizerUpgradeable` | 初始化（cycle 1）与每次 `finalizeCurrentCycle` 开启新周期时 | 周期开启锚点；`tokens/balances` 为周期起始 treasury ledger 快照（双 emit 位同源：initialize 位 `balances` 取 `__GovernanceCycleIncentivizer_init` 中 `_registerTreasuryToken` 写入 storage 的初始入账种子，finalize 位取 `finalizeCurrentCycle` 回填后的结转值，两者口径一致）；canonical 部署流下 `Governor` 零余额，故 initialize 位 `balances` 恒为 0（等于初始入账种子 0） |
| `CycleFinalized(uint128 indexed cycleId, uint128 endTime, address[] treasuryTokens, uint256[] balances, address[] rewardTokens, uint256[] rewards)` | `GovernanceCycleIncentivizerUpgradeable` | `finalizeCurrentCycle` 成功时 | 周期终结与划拨结果：treasury ledger 终值 + reward ledger 划拨明细；`endTime` 字段为 finalize 执行时刻时间戳 |
| `RewardClaimed(address indexed user, uint128 indexed cycleId, address indexed token, uint256 amount)` | `GovernanceCycleIncentivizerUpgradeable` | `claimReward` 成功发放时 | 用户奖励领取流水 |
| `TreasuryIncomeRecorded(uint256 indexed cycleId, address indexed token, address indexed sender, uint256 amount)` | `GovernanceCycleIncentivizerUpgradeable` | `recordTreasuryIncome` 记账时（纯账本动作，无 token transfer） | treasury 入账流水 |
| `TreasuryBalanceSynced(uint256 indexed cycleId, address indexed token, uint256 balance)` | `GovernanceCycleIncentivizerUpgradeable` | `syncTreasuryBalance` 成功时（纯账本动作，无 token transfer；permissionless） | treasury ledger 整额对账流水（balance 为 sync 后的 ledger 值） |
| `TreasuryAssetSpendRecorded(uint256 indexed cycleId, address indexed token, address indexed receiver, uint256 amount)` | `GovernanceCycleIncentivizerUpgradeable` | `recordTreasuryAssetSpend` 记账时（纯账本动作，无 token transfer） | treasury 支出流水 |
| `AccumCycleVotes(uint256 indexed cycleId, address indexed user, uint256 votes)` | `GovernanceCycleIncentivizerUpgradeable` | Governor 投票后回调 `accumCycleVotes` 时；cycleId 为 cast 时刻的当前周期 | 周期内投票权累计；reward 公式（userVotes / totalVotes）的分子数据源 |
| `TreasuryTokenRegistered(address indexed token)` | `GovernanceCycleIncentivizerUpgradeable` | `registerTreasuryToken` 成功时；治理组件初始化部署路径亦对每个 init token 触发一次 | treasury token 注册审计；`Governor.recordTreasuryTokenRegistration` 回调的配套信号 |
| `TreasuryTokenUnregistered(address indexed token)` | `GovernanceCycleIncentivizerUpgradeable` | `unregisterTreasuryToken` 成功时（该 token 同时是 reward token 时连带撤销其 reward 注册与当期 reward 记账，但**不**触发 `RewardTokenUnregistered`——该事件仅由显式 `unregisterRewardToken` 触发） | treasury token 注销审计 |
| `RewardTokenRegistered(address indexed token)` | `GovernanceCycleIncentivizerUpgradeable` | `registerRewardToken` 成功时 | reward token 注册审计 |
| `RewardTokenUnregistered(address indexed token)` | `GovernanceCycleIncentivizerUpgradeable` | `unregisterRewardToken` 成功时 | reward token 注销审计 |
| `RewardRatioUpdated(uint256 oldRatio, uint256 newRatio)` | `GovernanceCycleIncentivizerUpgradeable` | `updateRewardRatio` 成功时 | treasury→reward 划拨比例变更审计；比例在 `finalizeCurrentCycle` 时取最新值 |
| `OFTProcessed` | `YieldDispatcher` | OFT compose 到账处理（`lzCompose`，真实 compose guid）；同链费用分发 `distributeSameChain`（guid 恒为 `bytes32(0)`，launcher 同链分支调用） | 收益路由或 burn 结果；`burnedAtDispatcher=true` 仅表示 dispatcher 在 EOA receiver 分支执行了 `burn` 调用（与 `_settle` EOA 分支同源）——实际销毁仅对实现 caller-callable 单参 `burn(uint256)` 的 token 成立（fallback 吸收型 token 可能静默无销毁），非零金额时 `burnedAtDispatcher=false` 仅表示已发起 approve+pull 给合约 receiver，不保证实际拉取（fallback 吸收型 receiver 零移动；receiver 收到后可能在其内部销毁，如空 vault 的 accumulateYields burn）；零金额时 `burnedAtDispatcher=false` 且无任何资金转移：两种触发面（非自引用帧）均经 `_settle` 零金额短路（不 burn、不发下游调用、无资金记账；lzCompose 路径 `composeStates` 仍置 `Settled` 且事件照常 emit）；零金额自引用帧被自引用守卫消费、发 `ComposeRejected` 不发 `OFTProcessed`，见 ComposeRejected 行 |
| `ComposeSettled(bytes32 indexed guid, address indexed token, address indexed receiver, TokenType tokenType, uint256 amount, bool burnedAtDispatcher)` | `YieldDispatcher` | 已投递未执行 compose 兜底结算完成 | `settlePendingCompose` 成功时触发；`burnedAtDispatcher=true` 仅表示 EOA receiver 分支执行了 `burn` 调用（与 `_settle` EOA 分支同源）——实际销毁仅对实现 caller-callable 单参 `burn(uint256)` 的 token 成立（无单参 burn 的 token 该分支恒 revert、事件不发；fallback 吸收型 token 可能静默成功、`burnedAtDispatcher=true` 但零销毁）；`burnedAtDispatcher=false` 仅表示已发起 approve+pull，不保证实际拉取（fallback 吸收型 receiver 零移动）。`token` 键不保证是真实桥接 token：`sendCompose` 按 `msg.sender` 键控、任何人可写自己的槽，permissionless settle 仍可伪造但仅当 MEMECOIN 帧的合约 receiver 分支满足绑定（receiver 为自洽假 vault：`asset() == 攻击者 token`、空回调 no-op）才成功（无资金移动、真实槽不受影响）；该分支 receiver 为真实 vault 或未实现 `asset()` 的合约时经绑定校验 revert（真实 vault 具名 `TokenVaultMismatch`；无 `asset()` 合约空数据 revert），不再“任意攻击者 token + 空回调即可成功”（本轮 code writer 同步落地）；绑定只存在于 MEMECOIN 合约 receiver 分支，另两处例外仍可伪造成功（无资金移动、零影响、语义不变）：(a) EOA receiver 分支（receiver 无 code → `IBurnable(token).burn(amount)`，攻击者自有 token 实现 no-op `burn(uint256)` 时成功）；(b) UASSET 帧（假 governor 实现 no-op `receiveTreasuryIncome` 时成功）——对账仍须按已知 token 地址过滤。`tokenType` 为消息解码的结算类型（MEMECOIN→yieldVault / UASSET→governor），对账可直接按事件字段分账、无需 receiver 角色映射；但伪造帧的 tokenType 同样来自伪造 message，仍须按已知 token 地址过滤。参数名 `burnedAtDispatcher` 即指 dispatcher 自身动作——合约 receiver（vault）收到后可能在内部销毁（空 vault 时 accumulateYields 直接 burn、无 vault 事件），对账需结合底层 token 的 Transfer(to=0) 或 vault 状态核对；`[代码已证]` |
| `ComposeRejected(bytes32 indexed guid,address indexed token,uint256 amount)` | `YieldDispatcher` / `OmnichainMemecoinStaker` | 畸形 compose payload 被消费（无资金移动） | 两个 composer 同签名发出。`YieldDispatcher.lzCompose` 解析失败（畸形内层 composeMsg）或 receiver == 自身地址的自引用帧时触发（见 operations.md §3.13 自引用类）：置 `Settled`、不结算，使 endpoint 状态机收敛、executor 停止重试；`amount` 语义按 composer 分流：YieldDispatcher 对 <44 字节帧消费并报 `amount=0`（防御纵深路径，`_parseCompose` 短元组 `parseable=false`）；OmnichainMemecoinStaker 的 `lzCompose` 对 <76 字节帧在消费前即 `require(..., MalformedComposeMsg())` revert，其 `ComposeRejected` 恒来自 ≥76 字节帧、`amount` 恒为可读 amountLD（staker 侧无「短帧为 0」路径）。真实 endpoint 投递恒 ≥77 字节，[44,76) 短帧类仅覆盖手铸/`setQueue`/测试注入（防御纵深守卫输入），非生产可观测面。`OmnichainMemecoinStaker.lzCompose` 对 64 字节帧 receiver word 高位脏的帧消费：CEI 置 `Settled` 后 emit、不结算，endpoint 收敛、资金滞留 staker 托管（自伤边界）；`[代码已证]`（staker 变体参数名 memecoin，与 dispatcher 的 token 同签名同 topic0） |
| `StakingComposeSettled(bytes32 indexed guid, address indexed memecoin, address indexed receiver, uint256 amount)` | `OmnichainMemecoinStaker` | 已投递未执行 compose 兜底结算完成 | `settlePendingCompose` 成功时触发；事件不含 `yieldVault`（release 路径刻意只读 composeMsg 首 word、不触碰 vault，见 IOmnichainMemecoinStaker 接口 MalformedComposeMsg @dev）；意图 vault 需从目的链 endpoint `ComposeSent` message 重解码（operations.md §3.13.1 步骤 1）；事件身份即「裸币释放、未建仓」信号——份额/治理票让渡属 §3.13.1 语义分叉，对账须按事件身份入账（裸币转账），勿按「本应建仓」补记。`[代码已证]` |
| `OmnichainMemecoinStaking` / `OmnichainMemecoinStakingProcessed` | interoperation/staker | 发起远端 staking / 远端处理完成 | 跨链 staking 追踪。注意：receiver==staker 自伤帧的 vault-absent fallback 分支是自转 no-op、资金零移动，但 `OmnichainMemecoinStakingProcessed` 照常 emit——按该事件统计资金移动的对账逻辑对自伤帧会误计，对账须按 receiver 过滤（receiver 为 staker 自身或无出口合约地址时核对余额而非按事件计数入账）此外，`yieldVault` 字段 == `address(0)` 有两源且事件层不可区分：(i) composeMsg vault word 干净==0（合规无 vault / 协议 fallback）；(ii) composeMsg vault word 高 96 位脏，被 `OmnichainMemecoinStaker.sol::lzCompose` 三元降级为 `address(0)`（自伤帧降级释放，`testLzComposeReleasesToReceiverWhenVaultWordDirty` 钉）。两者资金移动语义相同（裸币转 receiver），仅成因不同；按 `yieldVault==address(0)` 做的统计须结合 endpoint `ComposeSent` message 重解码原 vault word 判别，完整机制见 operations.md §3.13.1 边界条目 (ii)/(iii)。`OmnichainMemecoinStaking` 的 `amount` 为原始输入额；截断发生时实际质押 = `amountSentLD`、余量 `remainder` 同交易退给 sender（无独立事件，对账按 `amountSentLD + remainder == amount` 核对），完整语义见 [interoperation-details.md §4.5](interoperation/interoperation-details.md)。 |

**`AccumulateYields` 的空仓静默面**：非零收益且 `totalSupply() == 0` 时 `MemecoinYieldVault.sol::_accumulateYield` 直接 burn 收益、不发本事件，对账须以底层 token 的 `Transfer(to=0)` 核对销毁；`yield == 0` 时 `_accumulateYield` 早退（不 burn、不 emit、账本不变），任何仓态下均无本事件；dispatcher 结算路径的对应提示见本表 `OFTProcessed` / `ComposeSettled` 行与 [governance-yield-details.md §5](governance/governance-yield-details.md)。

**`Deposit` 与 ERC-4626 对齐、不新增 `Withdraw`**：现有 `IMemecoinYieldVault.sol::Deposit`（`Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)`）签名已与 ERC-4626 标准 `Deposit` 逐字节一致；新增 `MemecoinYieldVault.sol::mint` 复用同一事件，不新增 `Deposit` 变体。不实现即时 `redeem` / `withdraw`，故**不新增** ERC-4626 标准 `Withdraw` 事件；现有 `RedeemRequested` / `RedeemExecuted` 两段式事件继续描述延迟赎回语义（见 [governance-yield-details.md §6](governance/governance-yield-details.md)）。

### 2.6 组件部署（MemeverseProxyDeployer）

verse 组件部署阶段（Launcher `Locked` → 部署治理组件）由 `MemeverseProxyDeployer` 发出的部署信号，是索引器建立 verse 组件地址映射与部署监控面的关键锚点：

| 事件 | 触发模块 | 触发时机 | 用途 |
| --- | --- | --- | --- |
| `DeployMemecoin(uint256 indexed uniqueId, address memecoin)` | `MemeverseProxyDeployer` | `deployMemecoin` 成功部署 memecoin clone | verseId↔memecoin 地址映射 |
| `DeployPOL(uint256 indexed uniqueId, address pol)` | `MemeverseProxyDeployer` | `deployPOL` 成功部署 POL clone | verseId↔POL 地址映射 |
| `DeployYieldVault(uint256 indexed uniqueId, address yieldVault)` | `MemeverseProxyDeployer` | `deployYieldVault` 成功部署 yield vault clone | verseId↔yieldVault 地址映射 |
| `DeployGovernorAndIncentivizer(uint256 indexed uniqueId, address governor, address incentivizer)` | `MemeverseProxyDeployer` | `deployGovernorAndIncentivizer` 成功部署并初始化 governor/incentivizer 代理对 | verseId↔governor/incentivizer 地址映射；治理组件上线锚点 |

以上均为 `[代码已证]`。

## 3. 运维配置事件

重点配置事件（均 `[代码已证]`）：

- Launcher：`SetMemeverseSwapRouter`、`SetFundMetaData`、`SetExecutorRewardRate`、`SetPreorderConfig`、`SetGasLimits`、`SetLaunchImpl`、`SetSettlementImpl`、`SetLiquidityImpl`、`SetFeePreviewReader` 等
  - `SetLaunchImpl(address indexed launchImpl)`：launch sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setLaunchImpl(...)` 替换时均以新接线地址 `(launchImpl)` 单值触发。事件不携带旧值，旧值需通过历史日志或 `getLauncherContracts()` 快照对比获取。`[代码已证]`
  - `SetSettlementImpl(address indexed settlementImpl)`：settlement sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setSettlementImpl(...)` 替换时触发，单值不携带旧值。`[代码已证]`
  - `SetLiquidityImpl(address indexed liquidityImpl)`：liquidity sibling 实现指针替换事件，owner-level；脚本单角色模式部署期与 owner `setLiquidityImpl(...)` 替换时触发，单值不携带旧值。`[代码已证]`
  - `SetFeePreviewReader(address indexed feePreviewReader)`：fee-preview reader 地址替换事件，owner-level；脚本单角色模式部署期与 owner `setFeePreviewReader(...)` 替换时触发，单值不携带旧值。`[代码已证]`
- RegistrationCenter：`SetSupportedUAsset`、`SetDurationDaysRange`、`SetRegisterGasLimit`
- Hook（Router）：`TreasuryUpdated`、`ProtocolFeeCurrencySupportUpdated`、`LauncherUpdated`、`PoolInitializerUpdated`、`PoolInitializationAuthorized`、`DefaultLaunchFeeConfigUpdated`、`LPTokenImplementationUpdated`、`ReferrerRebateBpsUpdated`、`FacetUpdated`
  - `PoolInitializationAuthorized`：一次性授权消费事件，记录单次池初始化授权。
  - `LauncherUpdated`：hook `initialize` 时以 `(address(0), launcher_)` 触发一次（initializer write-once，运行期无 `setLauncher` 路径，见 [upgradeability.md §3.5](upgradeability.md) / [access-control.md §3](access-control.md)）。
  - `LPTokenImplementationUpdated`：LP token clone 模板替换事件；`initialize` 时以 `(address(0), impl)` 触发，`setLpTokenImplementation` 时以 `(old, new)` 触发。
  - `ReferrerRebateBpsUpdated`：`MemeverseUniswapHook::setReferrerRebateBps` 直接写 storage + emit；hook `initialize` 时以 `(0, 1000)` 触发一次。
  - `FacetUpdated`：`initialize` 时为初始 3 facet 绑定各 emit 一次 `FacetUpdated(role, address(0), facet)`（部署时建立基线，索引器可重建初始绑定）；此后 `setFacet(bytes32 role, address facet)` 成功后 emit，记录 swap / dynamicFee / settlement 三类 facet 地址替换（owner-level）。
- Interoperation：`SetGasLimits`
- ProxyDeployer：`SetQuorumNumerator`、`SetMinQuorumNumerator`、`SetBootstrapPeriod`、`SetMaxTreasurySpendRatio`、`SetUpgradeSupermajorityRatio`（均 owner-level、仅影响后续新部署 governor 初始化、不回溯既有实例；其中 `SetMinQuorumNumerator` 的 setter 另要求 `<=100` 见 `InvalidMinQuorumNumerator`，其余仅非零校验）
- Incentivizer：`TreasuryTokenRegistered`、`TreasuryTokenUnregistered`、`RewardTokenRegistered`、`RewardTokenUnregistered`、`RewardRatioUpdated`（均仅能经 Governor 治理操作触发，`onlyGovernance`；其中 `TreasuryTokenRegistered` 在治理组件初始化部署路径亦对每个 init token 触发一次）
- 跨链适配层（`src/common/omnichain`，owner-level）：`PeerSet`、`SetLzEndpointIds`、`EnforcedOptionSet`、`MsgInspectorSet`、`PreCrimeSet`
  - `PeerSet(uint32 eid, bytes32 peer)`：`OutrunOAppCoreInit::setPeer` 后触发，记录跨链可信 peer 路径变更（误配可致伪源链消息被接受）；覆盖 `Memecoin`/`MemePol`（OApp/OFT clone 系，经 `OutrunOAppInit` 继承）
  - `SetLzEndpointIds(LzEndpointIdPair[] pairs)`：`LzEndpointRegistry::setLzEndpointIds` 批量更新 chainId↔endpointId 路由映射后触发
  - `EnforcedOptionSet(EnforcedOptionParam[] enforcedOptions)`：`OutrunOAppOptionsType3Init::setEnforcedOptions` 批量更新跨链消息强制执行参数（type-3 options）后触发；覆盖 `Memecoin`/`MemePol`
  - `MsgInspectorSet(address inspector)`：`OutrunOFTCoreInit::setMsgInspector` 更新出站消息拦截器地址/开关后触发；覆盖 `Memecoin`/`MemePol`
  - `PreCrimeSet(address preCrimeAddress)`：`OutrunOAppPreCrimeSimulatorInit::setPreCrime` 更新 preCrime 模拟器接线后触发；覆盖 `Memecoin`/`MemePol`

运维清理事件（均 `[代码已证]`）：

- Launcher：`RemoveGasDust(address indexed receiver,uint256 dust)`，owner-only 清理 Launcher native gas dust 时发出。

## 4. 已知事件缺口与解释

- `burnPreRedeemedBacking` 不要求专用事件。
- `MemeverseSwapRouter` 不发业务事件；swap、流动性与资金变动的链上索引依赖 Hook 事件和 token `Transfer`。
- `MemeverseYTFlashSwapRouter` 与 `MemeverseSwapRouter` 不同：它直接 emit `YTFlashSwapPOLForYT` / `YTFlashSwapYTForPOL` 业务事件（见 §2.4，`[代码已证]`），因为它的两入口资金流不被普通 Hook 的 swap/LP 事件完整覆盖（涉及 split/merge 与 baseline 恢复）。
- `changeStage` 在 `Locked` 且未到 `unlockTime` 时也会发 `ChangeStage(..., Locked)`；索引器不能仅凭事件判断“是否真的迁移”。`[已知缺口]`
- 当前实现没有“保护窗口开始/结束”的专用阶段或专用事件，也没有 dedicated event 单独标记 `publicSwapResumeTime` 的激活或到期；索引器需要结合 stage、实际 `Locked -> Unlocked` 迁移交易时间、固定保护窗口（`UNLOCK_PROTECTION_WINDOW`，数值见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md)）与 swap 成败联合判断“unlock 后保护中”与“完全开放交易”的状态。`[已知缺口]`
- `SetExternalInfo` 事件携带的是本次传入数组；合约内 `communitiesMap` 为按索引覆盖，旧尾部数据可能保留，事件本身无法单独重建完整当前快照。`[已知缺口]`
- `lzCompose` 的 `Released` 吸收分支（`YieldDispatcher.sol::lzCompose`、`OmnichainMemecoinStaker.sol::lzCompose`）不发任何事件：该 (token, guid) 已由 `settlePendingCompose` 兜底结算并 emit `ComposeSettled`（dispatcher）/ `StakingComposeSettled`（staker），吸收分支是 no-op（无状态变更、无资金移动），故不再 emit。推论：消费者不能仅订阅正向事件（`OFTProcessed` / `OmnichainMemecoinStakingProcessed`）做入账——在「兜底先于正向」时序下（受益人先 `settlePendingCompose`，endpoint 晚到重投 `lzCompose` 被吸收），该 guid 永不 emit 正向事件，只 emit `ComposeSettled`（dispatcher）/ `StakingComposeSettled`（staker）。必须同时订阅 `ComposeSettled`（dispatcher）/ `StakingComposeSettled`（staker）并按 (token, guid) 去重，才能覆盖该时序。吸收分支补发正向事件是错误方向（会谎称发生了一次并未发生的到账处理，并触发消费者重复入账）。**事件序注记（settle 先胜时序）**：该时序下 endpoint 仍会独立 emit `ComposeDelivered`（endpoint 事件，不在本仓库定义，见 §5；其 emit 位在 composer `lzCompose` 正常返回之后，吸收 no-op `return` 即满足），但 `ComposeDelivered` **不蕴含** composer 已处理该消息——composer 侧为 no-op、零事件；上文的 `ComposeSettled`（dispatcher）/ `StakingComposeSettled`（staker）按 (token, guid) 去重规则在该时序生效，索引器不可仅凭 `ComposeDelivered` 入账。endpoint 侧终态收敛机制见 operations.md §3.13。`[已知缺口]`
- LayerZero endpoint / PoolManager 等外部协议事件不在本仓库定义。`[未知]`
- `unregisterTreasuryToken` 连带撤销 reward token 注册与当期 reward 记账时静默（不触发 `RewardTokenUnregistered`，该事件仅由显式 `unregisterRewardToken` 触发）；维护 reward allowlist 的索引器须按 `TreasuryTokenUnregistered` 对账该移除。`[已知缺口]`

## 5. 确定性边界

- 除明确标注为目标事件规格或 target-only 的条目外，本文只覆盖仓库 `src/**` 明确 `emit` 的事件。
- 继承自 OpenZeppelin 的通用事件（如 `Paused/Unpaused`、`OwnershipTransferred`）存在，但未作为 Memeverse 业务主索引面展开（其中 `OwnershipTransferred` 由两个共享同一 ERC7201 owner 槽（`outrun.storage.Ownable`，`0x7f241041…f00`）但基类不同的 Outrun Ownable 家族 emit：`OutrunOwnableInit`（自定义 Initializable 基）由 `__OutrunOwnable_init` / `transferOwnership` emit，覆盖 OApp/OFT clone 系（最小代理 clone，不可升级）；`OutrunOwnableUpgradeable`（OZ Initializable 基）同样由 `__OutrunOwnable_init` / `transferOwnership` emit，覆盖 `MemeverseLauncher` / `MemeverseUniswapHook` / `POLend` / `POLSplitter`（UUPS 可升级）的 owner 迁移面；`SplitterToken` / `PrincipalToken` / `YieldToken` 不继承任一家族，不 emit 该事件，不降级为业务主索引）。
