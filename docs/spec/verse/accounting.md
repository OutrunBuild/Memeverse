# MemeverseV2 记账与资金语义

## 1. 说明与来源边界

- 本文档是当前产品真相层的一部分，定义当前记账规则。
- 规则证据来自 `src/**` 与 `test/**`。

## 2. Genesis 与 Preorder 入账

### 2.1 普通 Genesis

- 普通创世使用 `totalNormalFunds` 与 `userGenesisFund` 聚合账本。
- `genesis(verseId, amount, user)` 只接受该 verse 的 `uAsset`，累加：
  - `totalNormalFunds += amount`
  - `userGenesisFund += amount`
- `totalNormalFunds` 不包含 preorder、杠杆利息或杠杆债务。

### 2.2 杠杆 Genesis

- 杠杆创世由 `POLend` 记录用户支付的利息，并按 market 固定利率推导债务：
`totalLeveragedDebt = totalLeveragedInterest * 1e18 / market.interestRate`
- 成功 `genesis` / `leveragedGenesis` 写入后都必须保持 `totalNormalFunds + totalLeveragedDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，其中 `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max`；`leveragedGenesis` 写入前必须按累计 `nextTotalLeveragedInterest = totalLeveragedInterest + interestAmount` 推导 `previewDebt = nextTotalLeveragedInterest * 1e18 / market.interestRate`，并同时满足 `previewDebt <= debtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，不能只看当前调用 delta。
- `Genesis` 阶段不 mint 杠杆 `uAsset`；只有成功进入 `Locked` 时才由 `POLend.finalizeLeveragedGenesis` mint 推导债务并计入按 `uAsset` 维度的系统债务。
- `setLeveragedDebtFactor` 只改未来 `None / Genesis` market 的 debt cap / 容量预览口径，不追溯改变已注册 market 利率、已 mint 债务、退款、结算或 claim 账本。
- 杠杆退款、初始 `YT`、残值、PT fee 预兑付与全局结算规则以 [docs/spec/polend/settlement-and-fees.md](../polend/settlement-and-fees.md) 为准。

### 2.3 Preorder 入账

- preorder 是独立账本，不参与四池部署本金。
- preorder 入金、退款与结算都以该 verse 的 `uAsset` 记账和支付。
- preorder 容量以当前 `totalNormalFunds + totalLeveragedDebt` 为基数计算：
`preorderCap = (totalNormalFunds + totalLeveragedDebt) * 70% * preorderCapRatio / RATIO`
- `totalLeveragedDebt` 由当前 market 利率和 `totalLeveragedInterest` 推导；无杠杆参与时视为 0。
- `Refund` 状态下，preorder 用户按 `userPreorderFunds` 一次性退回该 verse 的 `uAsset`。

### 2.4 公开预览接口

- `previewPreorderCapacity(uint256 verseId) returns (uint256 remaining)` 是 view/preview 口径，不产生状态迁移。
- ABI 前置条件：未注册或无效 `verseId` revert `InvalidVerseId`。
- 计算口径：
  - `base = totalNormalFunds + totalLeveragedDebt`
  - `cap = base * 70% * preorderCapRatio / RATIO`
  - `remaining = max(cap - preorderState.totalFunds, 0)`
- `totalLeveragedDebt` 来自 `POLend`。
- `previewGenesisMakerFees(uint256 verseId) returns (uint256 uAssetFee,uint256 memecoinFee)` 预览可分发 genesis maker fee。该函数与 `quoteDistributionLzFee`（见 §5.4）由独立 view 合约 `MemeverseFeePreviewReader` 暴露，调用地址取 `getLauncherContracts().feePreviewReader`（见 [operations.md §3.3](../../operations.md)）；`previewPreorderCapacity` 由 Launcher 暴露。
- ABI 前置条件：校验 `verseId` 有效，且 verse stage 必须 `>= Locked`；无效 verse 或阶段不满足时按当前实现错误 revert。
- 该预览聚合主池 `memecoin/uAsset` claimable fees 与辅助池 gov-fee pools：`uAsset` 侧走 DAO/governor 路径，`memecoin` 侧走 yield vault 路径。

## 3. Locked 时的初始资金部署

### 3.1 Genesis -> Locked 资金口径

- `Genesis -> Locked` 的 launch gate 单独看是否满足：
`totalNormalFunds >= minTotalFund || totalLeveragedInterest >= minTotalFund`
- 上述门槛只决定能否从 `Genesis` 进入 `Locked`；不等于成功后的部署资金、容量资金或分账资金口径。
- 成功部署资金口径：
`totalGenesisFunds = totalNormalFunds + totalLeveragedDebt`
- `totalGenesisFunds` 不等于退款资金池，也不包含 preorder。
- 成功路径必须保持 `totalGenesisFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，其中 `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max`。
- `POLSplitter.initializeVerse` 在四池部署前调用；PT/YT 初始化不依赖是否有杠杆参与。

### 3.2 四池部署

- `totalGenesisFunds` 统一按 `70/30` 拆分：
  - `70%` 进入 `memecoin/uAsset` 主池。
  - `30%` 进入三个辅助池路径。
- `Launcher` 先为主池和三个辅助池计算 desired budgets，再调用 Router 执行建池与首笔加池。
- canonical truth 是实际执行结果：哪些 token 真正进入池子、主池实际花掉多少 `uAsset`、主池实际 mint 出多少 `POL`，都以后续实际 spend / actual mint 记账。
- 四池为：
  - `memecoin/uAsset`
  - `POL/uAsset`
  - `PT/uAsset`
  - `PT/POL`
- 主池 PT backing ratio 记录口径是“主池实际执行 spend / 主池实际产出的 POL raw amount”，不是 desired budget，也不是 Router 内部临时报价预算。
- 辅助池 bootstrap 的 auxiliary underspend 处置（actual spend 记账、不施加独立 bootstrap backing / equality guard、不依赖独立 rounding-envelope 规则、unused `uAsset` / `memecoin` 处置）见 [docs/spec/invariants.md](../invariants.md) INV-04。
- bootstrap 后若还有未进入辅助池 LP 的 `POL/PT`，它们属于单独的 bootstrap residual 类别，不是普通用户 LP floor dust。该 residual 先按 funding share 切成 leveraged share 和 normal share，再分别走后续 claim 路径。
- POL、PT、YT 的拆分比例、辅助池资产配比和 LP 记录以 [docs/spec/polend/pt-yt-splitter.md](../polend/pt-yt-splitter.md) 为准。

### 3.3 preorder 结算

- `Launcher` 先完成 `memecoin/uAsset` 主池实际建池，再使用托管 preorder `uAsset` 执行首笔交易买入 `memecoin`。
- 买出的 `memecoin` 由 `Launcher` 托管，并按 `userPreorderFunds / totalPreorderFunds` 线性释放。

## 4. 用户份额公式

### 4.1 初始 YT

- 四池部署时 split 得到的 `YT` 按资金占比分配：
`totalNormalClaimableYT = totalYT * totalNormalFunds / totalGenesisFunds`
`totalLeveragedYT = totalYT - totalNormalClaimableYT`
- 普通初始 `YT` 由 `Launcher` 托管并按 `userGenesisFund / totalNormalFunds` 领取。
- 杠杆初始 `YT` 由 `POLend` 托管并按 `userInterestPaid / totalLeveragedInterest` 领取。

### 4.2 preorder 线性解锁

- 用户总可得 preorder memecoin：
`purchased = settledMemecoin * userPreorderFunds / totalPreorderFunds`
- 线性释放窗口：`preorderVestingDuration`，已领数量累计在 `claimedMemecoin`。

### 4.3 Unlocked 后退出

- `redeemMemecoinLiquidity(verseId, amountInPOL)` 等价于 `unwrap=false`。
- `redeemMemecoinLiquidity(verseId, amountInPOL, unwrap)`：先 burn `amountInPOL`，再令 `amountInLP = amountInPOL`。
  - `unwrap=false`：按 `amountInLP` 转出 `memecoin/uAsset` LP token。
  - `unwrap=true`：按 `amountInLP` 移除 `memecoin/uAsset` LP，并发送底层 `memecoin` 与 `uAsset`。
- 该路径是 `Unlocked` 退出路径；解锁后保护窗口内仍允许执行，但不是公开 swap。
- `redeemAuxiliaryLiquidity`：普通用户在 `Unlocked` 后一次性领取三个辅助池普通份额 LP token，份额基准为 `userGenesisFund / totalNormalFunds`。
- 该路径还负责分发 bootstrap residual 的 normal share：`normalResidualPOL` 与 `normalResidualPT` 按同一 `userGenesisFund / totalNormalFunds` 比例分给普通用户。
- 若存在杠杆债务，`Locked -> Unlocked` 的同一笔交易内先执行 POLend 全局结算并切走杠杆份额 LP；普通用户只能领取结算后剩余的普通份额。
- 杠杆残值由 `POLend` 记录并按 `userInterestPaid / totalLeveragedInterest` 领取；残值不属于 `POLSplitter` 的 PT/YT 兑付池。
- 当前退出路径由 `redeemMemecoinLiquidity`、`redeemAuxiliaryLiquidity` 与 `POLend.claimResidual` 分别承载主池、普通辅助池和杠杆残值权益。

## 5. Fee 记账与分发

### 5.1 主池 fee

- `memecoin/uAsset` 主池 fee 按以下规则分流：
  - `uAsset` fee 走 Memeverse DAO governor 路径。
  - `memecoin` fee 给 `yieldVault`。

### 5.2 辅助池 fee

- 辅助池为 `POL/uAsset`、`PT/uAsset`、`PT/POL`。
- `POL` fee 全部 burn。
- `Locked` 阶段的 `uAsset fee / PT fee` 按 `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt` 切分，计算必须使用 full-precision `mulDiv` 或等价 overflow-safe 实现：
  - `govUAssetFee = fullPrecisionMulDiv(totalUAssetFee, totalLeveragedDebt, totalGenesisFunds)`
  - `govPTFee = fullPrecisionMulDiv(totalPTFee, totalLeveragedDebt, totalGenesisFunds)`
  - 取整差额归普通侧
  - 普通侧进入 `normalFeeStates`，用户按 `userGenesisFund / totalNormalFunds` 领取。
  - 杠杆侧最终转换为 `uAsset` 后进入 Memeverse DAO governor 路径，不进入 `POLend.protocolTreasury`。
- `claimNormalFees` 的普通侧 entitlement 计算也必须使用 full-precision `mulDiv`：
  - `entitledUAsset = fullPrecisionMulDiv(accUAssetFee, userGenesisFund, totalNormalFunds)`
  - `entitledPT = fullPrecisionMulDiv(accPTFee, userGenesisFund, totalNormalFunds)`
  - 目的不是修改分账公式，而是保证 `accUAssetFee` / `accPTFee` 已可表示但中间乘法可能溢出的情况下不会错误 revert。
- `Unlocked` 后新产生的辅助池非 `POL` fee 全部归 Memeverse DAO governor，普通用户仍可补领历史 `Locked` 阶段普通侧 fee。
- 普通侧 PT fee 领取分两条路径：
  - `settled=false`：直接把按份额应得的 `PT` 转给用户，并把该部分 `claimedPTFee` 标记为已领。
  - `settled=true`：先看 `previewPTToUAsset(verseId, ptAmount)`；只有 backing 非零时才调用 `redeemPT` 把对应 `uAsset` 发给用户并标记该部分 `claimedPTFee`。若 backing 为零，则该笔 PT entitlement 保持未领取状态，允许后续重试；同次 `uAsset` fee 领取不受影响。
- governor 路径的 PT fee 也有同样的 zero-backing 保留语义：`pending auxiliary gov PT fee` 或本次 preview 出来的 gov PT fee 在 `previewPTToUAsset(...) == 0` 时不得视为已处理，而是留在 pending 状态等待后续可兑付时再转换。
- PT fee 的预兑付、settle 后 redeem、pending auxiliary gov fee 规则以 [docs/spec/polend/settlement-and-fees.md](../polend/settlement-and-fees.md) 为准。

### 5.3 执行者奖励与治理收入

- 对主池 `memecoin/uAsset` 的 `uAsset` fee，`executorReward` 必须使用 full-precision `mulDiv` 或等价 overflow-safe 实现计算：`executorReward = fullPrecisionMulDiv(mainPoolUAssetFee, executorRewardRate, 10000)`。
- `executorRewardRate` 单位为 protocol ratio units（分母 `RATIO = 10000`，即 bps）。合法区间 `[0, 10000)`：`src/verse/MemeverseLauncher.sol::initialize` 与 `src/verse/MemeverseLauncher.sol::setExecutorRewardRate` 均校验 `executorRewardRate < RATIO`，越界 revert `FeeRateOverFlow`（owner 经 `setExecutorRewardRate` 配置）。部署脚本默认值 `25`（0.25%）。
- `mainPoolGovFee = mainPoolUAssetFee - executorReward`，减法必须保持 checked arithmetic 语义。
- 执行者奖励直接发给 `rewardReceiver`。
- `quoteDistributionLzFee` 与 `redeemAndDistributeFees` 必须共享同一套执行者奖励分账算术语义；quote 口径不得因中间乘法溢出而偏离 redeem 实际执行结果。
- 上述 quote 与 redeem 共享的分账算术通过内部库 `src/verse/libraries/MemeverseLauncherLib.sol::splitExecutorReward` 落地：`MemeverseFeeDistributor._splitExecutorReward` 与 `MemeverseFeePreviewReader._splitExecutorReward` 仅作为薄 wrapper 调用同一实现，二者之间仅在如何读取 `executorRewardRate` 上不同。[代码已证]
- 辅助 governor 路径的 `uAsset` fee 与 `PT` 转换后的 `uAsset` 会在主池分账之后并入 governor treasury 路径，不额外再拆执行者奖励。

### 5.4 治理链本地/异链分发

- 目标：`quoteDistributionLzFee(verseId)`（由 `MemeverseFeePreviewReader` 暴露，与 Launcher 的 `redeemAndDistributeFees` 跨合约、算术须逐字镜像）返回 Launcher 费用分发所需的 required native fee；本地分发或无跨链要求时返回 `0`。执行者奖励分账与主池 fee 的 token 顺序排列通过共享的 `MemeverseLauncherLib` 辅助函数（`splitExecutorReward`、`mapPairFees`）实现，因此两侧逐字节一致；其余镜像辅助函数（辅助 governor fee 拆分、OFT send-param 构造）则通过源码约定与注释标注成对维护，并由 `MemeverseLauncherFeePreviewConsistency.t.sol` 端到端断言 `quoteDistributionLzFee` 等于 `redeemAndDistributeFees` 所需 native fee 作机器化反 drift 哨兵；该测试同时启用 amountLD 敏感的 OFT 报价（mock `quoteSend` 返回 `sendParam.amountLD`）并注入非零杠杆与普通资金，使辅助 governor fee 的 `mulDiv` 量级 drift 亦能被捕获（非仅 zero-crossing）。OFT send-param 构造（`_buildSendParamAndMessagingFee`）现同样经 `MemeverseLauncherLib::buildSendParamAndMessagingFee` 共享实现，结构与量级 drift 均不可达；唯一仍靠源码约定成对维护的是辅助 governor fee 拆分（`_splitAuxiliaryGovFees`，因移走会改 `preserveNormalShare==false` 短路与外部调用顺序）。[代码已证]
- `previewGenesisMakerFees` 与 `quoteDistributionLzFee/redeemAndDistributeFees` 不共享同一 main-pool `uAsset` 净额口径：
  - `previewGenesisMakerFees` 返回的是 gross main-pool `uAsset` fee，再叠加辅助 governor fee 的 `uAsset` 等价额；这里不会先扣执行者奖励。
  - `quoteDistributionLzFee` 与 `redeemAndDistributeFees` 对 main-pool `uAsset` fee 会先拆出 `executorReward`，只有剩余的 `govFee` 进入 governor treasury 路径。
- 三者共享的只是辅助 governor fee 来源范围，而不是同一最终净额：
  - 已累积在 `pendingAuxiliaryGovFeeStates.pendingUAssetFee` 的辅助池 gov `uAsset` fee
  - 当前 preview/claim 到的辅助池 gov `uAsset` fee
  - 辅助池 gov `PT` fee 按当前阶段转换成的 `uAsset`
    - `Locked`：经 `POLend.preRedeemPTFee(...)`
    - `Unlocked/settled`：经 `POLSplitter.redeemPT(...)`
- 若治理链为本链或异链，token 的最终 receiver 映射（`UASSET` → `Governor.receiveTreasuryIncome`、`MEMECOIN` → `YieldVault.accumulateYields`，非合约 receiver → burn）以 [docs/spec/interoperation/interoperation-details.md](../interoperation/interoperation-details.md) §3.3 为跨链终点 canonical；本链/异链路径见 §3.1/§3.2。
- 目标：`redeemAndDistributeFees` 的 native payment 必须精确等于 required fee；underpay 与 overpay 都会 revert（实现要求“等于”，不是“大于等于”）。
- 目标：若本次没有任何 fee 被分发，required fee 为 `0`，因此非零 `msg.value` 应 revert。

## 6. Treasury / Yield / Governance 周期语义

Governor / Incentivizer 的 custody 与 ledger 分层、token 准入、周期结算、reward payout 调用链、YieldVault `totalSupply == 0` burn 语义见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md)：

- Governor custody 与 ledger 分层、token 准入（V17/V19）：见 `governance-yield-details.md` §7。
- YieldVault `totalSupply == 0` 时 yield burn（V20）：见 `governance-yield-details.md` §5。
- 周期结算 `rewardRatio` 划拨、reward payout 调用链与账本回卷语义：见 `governance-yield-details.md` §6–§8。

accounting.md 只保留对 Launcher 侧记账入口的引用：launcher 把 fee/yield 经 `YieldDispatcher` 推到 `Governor.receiveTreasuryIncome` / `YieldVault.accumulateYields`，跨链终点的 token-to-receiver 映射见 [docs/spec/interoperation/interoperation-details.md](../interoperation/interoperation-details.md) §3.3。

## 7. Launch Fee 记账

### 7.1 概述

- Launch fee 是在 token launch 阶段（池初始化后的一段时间窗口内）对 swap 施加的额外费率保护。
- 每个池的 launch 时间戳在 `beforeInitialize` 中记录为 `poolLaunchTimestamp[poolId]`。
- Launch fee 与动态费叠加取 max：`effectiveFeeBps = max(dynamicFeeBps, launchFeeBps)`。
- **EWVWAP 豁免**：当池存在 EWVWAP 历史且交易方向回归 EWVWAP（即交易后 spot 距离 EWVWAP 更近）时，跳过全部动态费组件（adverse + volatility + short），直接返回 `baseFeeBps`。无历史时视为 adverse。此豁免大幅降低零售用户回归方向的费率负担。
- 当不满足 EWVWAP 豁免时，动态费率由三部分组成：
  - **Adverse（per-address）**：基于 per-address 3 秒窗口内的累积 PIF 计算的逆向冲击费。同一地址在 3 秒内连续交易的 PIF 会累积，使拆单攻击面临与大单等同的费率。3 秒窗口从 batch 首笔交易开始计时，到期后重置。普通用户单笔交易不受影响。公式为软饱和曲线：`adverse = dffMax × effectivePif / (effectivePif + pifCap) × effectivePif / 1e6`。
  - **Volatility（per-pool）**：基于波动率偏差累加器计算的波动费。使用 sqrt 曲线平滑费率响应（避免二元跳变），累加器按价格偏差步数增长，经 10 秒 filter period 和 60 秒 decay period 衰减。实现采用整数公式 `floor(sqrt(accumulator * VOL_MAX_FEE_BPS^2 / VOL_MAX_DEVIATION_ACCUMULATOR))`；其中 `VOL_MAX_FEE_BPS = 50`、`VOL_MAX_DEVIATION_ACCUMULATOR = 1_500_000`，当累加器达到上限时精确得到 `50` bps，低累加器区间会因整数除法与整数开方产生截断。
  - **Short-term（per-pool）**：基于短期冲击累加器的快速交易惩罚。15 秒线性衰减窗口，2% floor 保护普通用户（累积 PIF 低于 floor 不收费），cap 限制最大 200 bps。
- `dynamicFeeBps = baseFeeBps + adverseBps + volatilityBps + shortBps`，硬上限 `maxFeeBps = 10000`。

### 7.2 衰减公式

- 默认配置 `defaultLaunchFeeConfig`：
  - `startFeeBps = 5000`（50%）
  - `minFeeBps = 100`（1%，即 `FEE_BASE_BPS`）
  - `decayDurationSeconds = 900`（15 分钟）
- 形状参数 `LAUNCH_FEE_EXP_SHAPE_WAD = 4e18`，指数衰减曲线：
  - `elapsed = block.timestamp - launchTimestamp`
  - 若 `elapsed >= decayDurationSeconds`，直接返回 `minFeeBps`
  - 否则：
    ```
    expAtElapsed = wadExp(-elapsed * SHAPE / decayDuration)
    expAtEnd     = wadExp(-SHAPE)
    decayWad     = (expAtElapsed - expAtEnd) * 1e18 / (1e18 - expAtEnd)
    feeBps       = minFeeBps + (startFeeBps - minFeeBps) * decayWad / 1e18
    ```
- 衰减单调递减：`elapsed` 增大时 `feeBps` 单调递减，不变量由 `LaunchFeeQuoteHandler` 测试保证。

### 7.3 Launch Fee 的分配对象

- Launch fee 本身不产生独立分配；它是 effective fee 的一部分，参与与常规 swap fee 相同的拆分：
  - **LP 分配**：`lpFeeBps = effectiveFeeBps - protocolFeeBps`（用减法实现，吸收 protocol 向下舍入的取整 dust，保证 `lpFeeBps + protocolFeeBps == effectiveFeeBps`；对应 LP/protocol 名义 65/35）
  - **Protocol 分配**：`protocolFeeBps = floor(effectiveFeeBps * 3500 / 10000)`（`FeeMath.protocolFeeBps`，内部 `FullMath.mulDiv` 向下取整）
- LP fee 按 per-share 累加到 `fee0PerShare / fee1PerShare`，LP 持有人通过 `claimFeesCore` 领取。
- Protocol fee 发送到 `treasury` 地址。

### 7.4 Preorder Settlement 的固定费率

- Preorder settlement swap 经独立入口 `executePreorderSettlement` 发起；SettlementFacet 使用显式 typed unlock payload，由 hook proxy 自己调用 PoolManager。真实 v4 对 hook self-call 同时跳过 `beforeSwap` / `afterSwap`，因此固定费率与全部 settlement fee 记账由 settlement 入口和 typed callback 自处理（见 [INV-04A](../invariants.md)）。typed payload/self-call 接线已实现。`[代码已证]`
- 固定费率 `PREORDER_SETTLEMENT_FEE_BPS = 100`（1%），不使用动态费也不使用衰减曲线。
- 分配同样遵循 65/35 拆分（与普通 swap 一致，LP/protocol = `FeeMath.PROTOCOL_FEE_SHARE_BPS` 对应比例）：
  - `lpFeeBps = 65`（0.65%）
  - `protocolFeeBps = 35`（0.35%）
- 输入侧费用在 settlement 入口直接收取：
  - LP fee 部分：从 `payer` pull ERC20 到 hook，按 per-share 计入 LP 分配；若 `effectiveSupply == 0`（有效 LP 供应量为零，无 LP 可接收分配）则整笔回退、LP fee 与 protocol fee 均不收取、整笔 settlement 失败（fail-closed，避免费用滞留 hook）。fail-closed 经两个守卫落地：`lpFeeInputAmount > 0` 时入口 revert `NoActiveLiquidityShares`；gross 极小使 LP fee 下取整为 0 的角例，由零流动性 swap 返回的 delta=0 触发函数末尾 `ExactInputPartialFill` revert——两者均整笔回退、无费用收取代入。settlement 入口调用的 `_activeLpSupplyForSettlement` 另在「缓存为 0 但 pool liquidity > 0」的不一致状态提前 revert 同一错误。详见 `uniswap-v4.md` §5。
  - Protocol fee 部分：从 `payer` pull ERC20 直接到 `treasury`。
- 输出侧 protocol fee（当 `!protocolFeeOnInput` 时）在 settlement callback 中从 pool output 扣取后发送到 `treasury`；当 `feeOnAmount` 向下取整令 `protocolFeeOutputAmount == 0`（小额 output 下可发生）时跳过该次 `take`，与 `SwapFacet._takeToTreasury` 的零额守卫一致，避免对零额 transfer 返回 false 的 ERC20（非 FoT/rebasing 类，与 uniswap-v4.md §3 排除的余额漂移 token 不同）误 revert。

### 7.5 配置管理

- `setDefaultLaunchFeeConfig`：owner 可更新全局默认配置。
  - 校验：`startFeeBps / minFeeBps / decayDurationSeconds` 均不能为零。
  - 校验：`startFeeBps <= 10000`，`minFeeBps <= 10000`，`minFeeBps <= startFeeBps`。
- 全局配置对所有池实时生效：每次 swap 读取当前 `defaultLaunchFeeConfig`，已创建的池不持有配置快照。`startFeeBps` 仅影响仍处于衰减窗口内的池；`minFeeBps` 影响所有池（含已度过窗口的池，其 floor 费率随之变化）。
- 每个池独立保存且冻结的唯一值是创建时（`beforeInitialize`）写入的 `poolLaunchTimestamp`，它只决定该池在衰减曲线上的位置（elapsed），不锁定曲线参数。
- 变更通过 `DefaultLaunchFeeConfigUpdated` 事件链上可审计。
