# MemeverseV2 集成边界：Uniswap v4

## 1. 范围

本文描述 Memeverse 与 Uniswap v4 的集成边界（Router/Hook/PoolManager）。  
标签：

- `[目标规范]`
- `[代码已证]`
- `[未知]`

## 2. 组件边界

### 2.1 Periphery（推荐公开入口）

- `MemeverseSwapRouter` 负责对外 `quote/swap/addLiquidity/removeLiquidity` 与可选 Permit2 拉资（swap 与流动性操作）。
- Router 的 `previewClaimableFees(...)` 仅是只读 preview-only helper，不执行 fee claim。
- Router 的 quote/preview 只读路径委托给构造绑定的 `MemeverseUniswapHookLens`；Lens 必须有代码，且 Lens `poolManager` 必须与 Router 构造注入的 PoolManager 一致。Router 与 Hook 也必须共享同一个 PoolManager——Router 在自身 immutable PoolManager 上发起 unlock/initialize，该 PoolManager 回调 Hook 的 `onlyPoolManager` 回调（比对 Hook 的 poolManager immutable），不一致则 `NotPoolManager` 让所有 swap/池初始化 revert（DoS）；readiness（`_requireSwapReady`）在开闸前校验 `router.poolManager() == hook.poolManager()`（错误串 `ROUTER_POOL_MANAGER_NOT_READY`），与 3 facet 的 `_requireFacetPoolManager` 对称。`MemeverseUniswapHookLens.poolDynamicFeeState` 调用 hook getter `MemeverseUniswapHookUpgradeable::dynamicFeeStateOf(poolId)` 读取 Router storage 的 `DynamicFeeState`；该 getter 为 `view`，直接读取 `dynamicFeeState[poolId]`，不经 facet delegatecall，对称于 `addressBatchStateOf`，故 `Lens.poolDynamicFeeState` 亦为 `view`。公开的 `MemeverseUniswapHookLens.quoteSwap` 与 `MemeverseSwapRouter.quoteSwap` 保持 `view`：Lens 对 non-view Hook bridge `quoteSwapFeeWithContext` 发起 `STATICCALL`，Hook bridge 再经 `DELEGATECALL` 路由到 `DynamicFeeFacet.quote`。只有 Hook bridge 因 solc 0.8.35 Error 8961（`view` 函数内禁止 `delegatecall`）保持 non-view；EIP-214 的静态上下文会穿过后续 `DELEGATECALL` 传播到 facet，任何状态写入都会回滚。只读保证来自该 EVM 静态上下文，而非 `eth_call` 不提交状态的 RPC 行为；函数 selector 与返回结构均不变。`MemeverseUniswapHookUpgradeable::addressBatchStateOf(trader, poolId)` 同为 `view`，直接读取 Router storage 的 `addressBatchState`。
- Router 的 ERC20 payout helper 对 `recipient == address(0)` fail-close；remove-liquidity 出款不会把资产发送到零地址。
- 池创建只允许 Launcher 调用 `createPoolAndAddLiquidity(...)`，建池必须经 `Launcher -> Router`，由 Launcher 提供 desired budgets，再由 Router 执行实际建池与首笔加池；池创建不支持 Permit2。
- Router 对 bootstrap 的集成契约是“实际执行后返回 actual spend / actual liquidity”（非 preview-equality 契约）；Launcher 的 post-bootstrap accounting 与记账语义见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)。
- Router 内部固定构造 pool key（`fee = DYNAMIC_FEE_FLAG`、固定 `tickSpacing`、`hooks = configured hook`）；具体固定值与 Hook 侧约束见 [docs/spec/invariants.md](../invariants.md) INV-08（V23）。
- exact-output 强制 `amountInMaximum`；所有 swap 为 execute-or-revert（V10，见 §4）。

`[代码已证]`

### 2.2 Core 引擎（Hook）

- `MemeverseUniswapHookUpgradeable` 负责：
 - 动态费计算与启动窗口费率下限
 - protocol fee 与 LP fee 归集
 - LP token per pool + fee per share 记账
 - `addLiquidityCore/removeLiquidityCore/claimFeesCore` 低层能力；其中 fee claim 执行入口是 `claimFeesCore(...)`，fee owner 由 `msg.sender` 推导，`recipient` 可指定，当前不支持 relayed/signature-based claim
- 内部架构为 diamond：callback / fee 分账 / LP per-share accounting 经 Router entry `delegatecall` 到 SwapFacet，动态费 state 读写经 `delegatecall` DynamicFeeFacet，preorder settlement 经 `delegatecall` SettlementFacet；三 facet 共享 Router storage，对外 ABI 统一在 hook 地址。
- `removeLiquidityCore(...)` 要求 `recipient != address(0)`，否则回退 `ZeroAddress()`（recipient 非零规则见 [docs/spec/invariants.md](../invariants.md) INV-07）。
- Hook 强制池约束（动态费 + 固定 `tickSpacing`）见 [docs/spec/invariants.md](../invariants.md) INV-08（V23）。

`[代码已证]`

### 2.2.1 Smart EOA account session `[代码已证]`

- Hook ABI 增加 `beginAccountSession()` 与 `endAccountSession()`；Hook 自己持有 transient active session context，并在 begin 时从 `msg.sender` 捕获 principal。`msg.sender.code.length != 0` 只拒绝传统 EOA，不是认证或白名单；EIP-7702 delegated account 仍可被接受。
- `beforeSwap` 与 `afterSwap` 只可读取 active session context 的 principal，并将其作为 `DynamicFeeFacet` 的执行 trader。Router、`hookData`、PoolManager callback caller、`tx.origin` 与 Universal Router `msgSender` 均不得充当 principal 来源。

### 2.2.2 资产结算与转账 helper

- `_settleDeltas`：向 PoolManager settle 负 delta（用户欠池子的资金）；swap 栈语义下仅处理 ERC20/ERC20 pair，任一侧为 `address(0)` 直接 `revert NativeCurrencyUnsupported`。（`MemeverseUniswapHookUpgradeable.sol::_settleDeltas`）
- `_takeDeltas`：从 PoolManager take 正 delta（池子欠用户的资金）到 recipient。（`MemeverseUniswapHookUpgradeable.sol::_takeDeltas`）
- `transferWithGuard`：ERC20 转账 helper，Hook 与 Router 共用（两侧均 `using CurrencySettler for Currency;`）——guards（`amount == 0` 早退、`to == address(0)` revert）+ `OutrunSafeERC20.safeTransfer` 处理非合规 ERC20 返回值（返回 `false` 或非 bool 数据），失败抛 `OutrunSafeERC20.SafeERC20FailedOperation(address token)`。`CurrencySettler` 库的 `settle`/`take` 可处理 native 与 ERC20，但 `transferWithGuard` 自身仅 ERC20（swap 栈只允许 ERC20 结算）。`[文档已对齐实现]`（`src/swap/libraries/CurrencySettler.sol::transferWithGuard`）

### 2.3 Preorder settlement 显式结算通道

- 启动结算调用链是 `MemeverseLauncherUpgradeable -> MemeverseUniswapHookUpgradeable.executePreorderSettlement(...)`。
- Launcher bootstrap pool creation 采用集成契约“desired budgets -> actual Router spend -> post-bootstrap accounting”（Router 返回 actual spend）。
- bootstrap 记账语义、auxiliary underspend 处置见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)。
- Hook 仅接受已绑定 launcher 的直接调用（caller 约束完整规则见 [docs/spec/invariants.md](../invariants.md) INV-04），并将 `unlock/swap` 逻辑经 Router entry `delegatecall` 委托给 SettlementFacet。SettlementFacet 用 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)` 发起 unlock；Router 读取首个 ABI word 的 raw `uint256`，仅对 `ModifyLiquidity` 与 `Settlement` 两个当前支持值分支，其他值回退 `InvalidUnlockCallbackKind(rawKind)`。
- `SettlementCallbackData` 与 `SettlementResult` 定义在 `ISettlementFacet`；`settlementUnlockCallback` 使用 typed calldata / typed return。因 `SettlementCallbackData` 当前全静态，Router 在 kind 校验后用 `bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])` 前缀转发到 SettlementFacet（跳过 memory decode + 二次 encode；与 `abi.encodeCall` 字节等价）。Router 把 `_facetDelegatecall` 的原始 returndata 直接作为 `unlockCallback(bytes)` 返回内容交还 PoolManager，`executeSettlementLogic` 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。外部 v4 `unlockCallback(bytes)` ABI 不变。
- settlement swap 在 hook 地址下发起，是 v4 hook self-call；pinned v4-core 在 `msg.sender == address(key.hooks)` 时同时跳过 `beforeSwap` 与 `afterSwap`，固定 settlement fee 由 settlement 路径自处理。外部 callback-token 重入 swap 不是 self-call：跨池的仍执行普通 callback 与 public fee 路径；同池生命周期重入被 `SwapFacet` per-pool transient lock 阻断（`beforeSwapLogic` 入口 acquire / `afterSwapLogic` 出口 release，同 poolId 重入触发 `SwapLifecycleReentrant`），防止 outer swap 报价固定后 callback token 推进动态费 state 造成费率失真（见 [docs/spec/invariants.md](../invariants.md) INV-04A）。
- 该路径使用固定总费率（数值定义见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）。
- 进入该路径前，Launcher / POLendUpgradeable 的部署资金口径只统计 `totalNormalFunds + totalLeveragedDebt`，不统计 preorder，且该口径必须保持 `<= type(uint128).max`。

`[代码已证]`

## 3. 收费/币种/native 边界

本节是 swap 栈收费语义、币种配置与 native 拒绝规则的 canonical home。其它 swap 文档（`swap-flow.md`、`swap-integration.md`、`permit2.md`、`common/common-foundations.md`）只引用本节，不重述这些规则本体。

### 3.1 普通动态 Swap 的一次选费与四路径 `[代码已证]`

普通动态 Swap 保留 exact-input 与 exact-output。动态费只按原始用户请求选择一次：exact-input 使用 `requestedGrossInput`，exact-output 使用 `requestedNetOutput`。原始价格限制只限制可执行性；协议费币腿、费后核心目标、任一费用和本笔 fee-induced flow 都不能重新选择费率。因此没有 fee-on-fee、递归收费或多轮费率估算。

设 `totalFeeBps = lpFeeBps + protocolFeeBps`。四条路径必须按下面的资产归属结算：

| 请求 | 协议费币腿 | 核心目标 | 最终结算 |
| --- | --- | --- | --- |
| exact-input | 输入侧 | `floor(requestedGrossInput × (BPS_BASE - totalFeeBps) / BPS_BASE)` 输入 | 用户支付原始输入；已取整总输入费按费率拆为 protocol 与 LP。 |
| exact-input | 输出侧 | `floor(requestedGrossInput × (BPS_BASE - lpFeeBps) / BPS_BASE)` 输入 | LP 费在输入侧；protocol fee 从实际核心毛输出扣除，用户取得净输出。 |
| exact-output | 输入侧 | `requestedNetOutput` 输出 | 用户输入由实际核心输入按总费生存率向上反推；输入侧总费拆分。 |
| exact-output | 输出侧 | 按 LP/总费生存率向上反推的核心毛输出 | protocol fee 固定为毛输出减请求净输出；用户输入由实际核心输入按 LP 生存率向上反推。 |

输出侧 protocol fee 按总费/LP 费生存率之比从核心毛输出扣除：`protocolFee = coreGrossOutput − floor(coreGrossOutput × (BPS_BASE − totalFeeBps) / (BPS_BASE − lpFeeBps))`，即输出侧有效率 = `protocolFeeBps / (BPS_BASE − lpFeeBps)`（grossed-up，非裸 `protocolFeeBps / BPS_BASE`）。

上式只适用于 `exact-input / 输出侧`。非零 `exact-output` 在 `totalFeeBps == BPS_BASE` 时由 `OrdinarySwapMath.deriveSettlementPlan` 提前回退 `ExactOutputAtFullFee`；仅当 `totalFeeBps < BPS_BASE` 时，`exact-output / 输出侧` 才适用 `coreOutputTarget = ceil(requestedNetOutput × (BPS_BASE - lpFeeBps) / (BPS_BASE - totalFeeBps))` 及固定 `protocolFee = coreOutputTarget - requestedNetOutput`。`userNetOutput = actualCoreGrossOutput - protocolFee`；`overfill = actualCoreGrossOutput - coreOutputTarget` 全部归用户，不再收 protocol fee。pinned v4 正常完整成交通常 `actualCoreGrossOutput == coreOutputTarget`，仍须记录这一定义的防御性/adapter 结算语义。

输入侧已取整总费中的 protocol share 向下取整，余数归 LP。不同币种 amount 不得相加；protocol fee、rebate 和 treasury share 必须同币种，且 `rebate <= actualProtocolFee`。`FeeMath.feeOnAmount` 只用于固定费，普通动态路径由 `OrdinarySwapMath` 实现。

PoolManager 传入 `afterSwap` 的 `BalanceDelta` 是实际核心 delta：它决定完整成交、费用与动态历史。Hook 返回 charging delta 后的 Router 返回值是最终用户 delta：`amountOutMinimum` 与 `amountInMaximum` 只能基于它检查。失败交易必须使全部收费与状态更新回滚。

### 3.2 原始价格限制、全范围容量与报价 `[代码已证]`

非零请求必须有活跃流动性，且事前价格在全范围下端点（允许 equality）与上端点（严格小于）之间。原始限制必须在全局方向边界内并严格位于事前价格的正确一侧；有效停止价再裁入全范围边界。若有效停止价是用户内部限制，核心目标可等于容量；若它是全范围端点，核心目标必须严格小于容量。端点 equality、零/错误方向 raw limit、零流动性、不可完整成交和不可表示金额都必须 revert。V4 `SwapMath` 的输出取整也可能把 post-swap 价格推到全范围端点；即使 core target 严格小于 capacity，此情形同样 revert `FinalTargetNotExecutable`，以避免端点仓位被取整差值耗尽。

`quoteSwapFeeWithContext`、Lens 与执行对同一非零完整上下文执行相同的一次选费、四路径和容量判断，必须同样成功或失败并给出相同最终用户金额。报价始终只读：即使外层 bridge 为 non-view，Lens 的 `STATICCALL` 与传播的静态上下文也禁止状态写入、`settle`、`take` 和可写外部调用。零金额报价是兼容预览，不代表可执行交易。

### 3.3 当前实现收费、币种与回调边界 `[代码已证]`

- `LP fee` 永远在输入侧。
- `Protocol fee` 币种由 `supportedProtocolFeeCurrencies` 决定：输入侧优先，输入不支持再看输出侧；若两侧均未注册（普通池），protocol fee 仍落在输入侧，swap 正常成交、不回退。
  - 解析式：`protocolFeeOnInput = inputSupported || !outputSupported`。真值表：输入侧注册→input；仅输出侧注册→output；两侧注册→input；两侧均未注册→input（普通池按输入侧收 protocol fee）。
- Exact-output swap 必须用实际核心输出与本条路径的核心输出目标比较；不足时 Hook 回退 `ExactOutputPartialFill()`。
- Exact-input swap 必须用实际核心输入与变换后的核心输入目标比较；不相等时 Hook 回退 `ExactInputPartialFill()`。
- `FeeMath.PROTOCOL_FEE_SHARE_BPS = 3500`；shared fee math 将 `feeBps` 按 35% protocol / 65% LP 拆分。
- 公开 swap 始终使用正常费率路径：`feeBps = max(current launch fee, dynamic fee, FEE_BASE_BPS)`；dynamic fee 故障通过 `setFacet(DYNAMIC_FEE_FACET_ROLE, newAddr)` 升级/修复处理，不提供 bypass mode。
- 返佣（referral rebate）：普通 swap 可在 `hookData` 前 20 字节 packed 携带 referrer 地址（caller 用 `abi.encodePacked(referrer)`；`abi.encode` 会左 padding 导致 `SwapFacet::_decodeReferrer` 误读，禁止使用）。referrer 无签名、无准入、无 referee 侧绑定，自推荐合法（该 referral 语义是防多层返佣/女巫类误报的既定产品规则）。有 referrer 时，`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（默认 `referrerRebateBps = 1000` = 总 fee 的 10%），`toTreasury = protocolFee - rebate`。`SwapFacet::_settleProtocolFee`（`_collectProtocolFee` 调用；beforeSwap 主路径直接调）先内联累加 Router storage 的 `pendingRebate[referrer][currency]` 并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take` 转出 treasury share（interaction），最后 emit `ProtocolFeeCollected`；记账本身无 PoolManager 调用或 facet→facet delegatecall，并且先于 treasury take 与调用方执行的 rebate take。该 helper 现为严格 CEI（effect → interaction → event）：`PoolManager.take` 不触发 v4 hook callback，但 ERC20 currency 的 `transfer` 仍执行外部 token 代码；安全性依赖 fee currency 为标准 ERC20（注册的协议费代币；普通池下为输入代币）、treasury 是被动收款方，以及任一步失败时整笔事务原子回滚。beforeSwap 主路径（`knownLpInputFee > 0 && knownProtocolInputFee > 0 && effectiveSupply != 0`）不经 `_collectProtocolFee`，走 `_computeRebate` + `_settleProtocolFee`，并将 rebate take 与 LP fee take 合并为一次 `poolManager.take(currencyIn, address(this), knownLpInputFee + rebate)`；afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。无 referrer 时不切 rebate，protocol 收全额 35%。rebate custody 在 hook proxy（`address(this)` 在 delegatecall 下即 hook proxy；v4 `PoolManager.take` delta 记调用者 hook，被 beforeSwap specifiedDelta credit 抵消；`pendingRebate` 账本在 Router storage，与 LP per-share accounting 分离）；referrer 经 `MemeverseUniswapHookUpgradeable::claimRebate` pull 领取（入口在 hook，Router 直接实现）。preorder settlement 路径不携带 referrer，不参与返佣。**返佣按链独立**：每条链的 hook 独立 settle / accrue / claim 该链 swap 的 rebate，无 LayerZero 同步、无跨链聚合、无全局 referrer 状态；referrer 在 A 链累积的 `pendingRebate` 只能在 A 链经 A 链的 hook `claimRebate` 领取，不能在 B 链领。
- `_decodeReferrer` 在 `SwapFacet::beforeSwapLogic` 与 `SwapFacet::afterSwapLogic` 各解码一次；rebate 路径调用点：beforeSwap 主路径（`knownLpInputFee > 0 && knownProtocolInputFee > 0 && effectiveSupply != 0`）走 `_computeRebate` + `_settleProtocolFee` + 合并 take，beforeSwap 边界（lpFee==0、protocolFee==0、或 effectiveSupply==0/drained pool）与 afterSwap 3 点（exact-input output 侧、exact-output input 侧、exact-output output 侧）走 `_collectProtocolFee`（内含 `_computeRebate` + `_settleProtocolFee` + 独立 rebate take）；以上均传入 referrer。
- native 拒绝：swap 栈只支持 ERC20/ERC20 pair；`key.currency0` / `key.currency1` 任一侧为 `address(0)` 直接 `revert NativeCurrencyUnsupported`。swap 栈不接受 `msg.value`，Permit2 也不为 native 提供任何兜底路径。
- 非 standard 余额语义 token（fee-on-transfer / rebasing / 其它使名义 `amount` 与实到余额不一致的 token）不在支持范围内：swap 栈（含 preorder settlement 路径）一律按名义 `amount` 执行 `transferFrom` / `settle` / `take`。FoT token 下 settle 因余额不足而整笔原子回滚，不产生资金损失；准入应排除此类 token，运行时不做 FoT 检测。
- 同池 swap 生命周期重入保护：`SwapFacet.beforeSwapLogic` 在 `_revertIfPublicSwapBlocked(poolId)` 之后经 `MemeverseTransientState.acquireSwapLifecycleLock(poolId)` acquire（故仍在保护期内的同池重入优先回退 `PublicSwapDisabled`，保护期外的同池生命周期重入才回退 `SwapLifecycleReentrant`）per-pool transient lock，`afterSwapLogic` 出口 release；同一 poolId 在 outer `beforeSwap → _swap → afterSwap` 未完成期间再次进入 `beforeSwapLogic` 触发 `SwapLifecycleReentrant` revert。transient storage 事务结束自动清除，revert 不留脏 lock；settlement self-call 因 v4 跳过 callback 不进这两个函数的 acquire/release 路径，但 `SettlementFacet.executeSettlementLogic` 在 Phase 1 `transferFrom` 前 acquire、Phase 3 `_updateAfterSwap` 后的函数末尾 release 同一 per-pool lock，覆盖 Phase 1 transferFrom → Phase 3 `_updateAfterSwap` 全窗口（含 settle/take 窗口）；settlement self-call 不重复 acquire，无死锁（见 [docs/spec/invariants.md](../invariants.md) INV-04A）；跨池嵌套 swap 因 per-pool key 互不影响。加流动性路径 `MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore` 同样持锁：在接收人 fee 快照（`MemeverseUniswapHookUpgradeable.sol::_updateUserSnapshotViaFacet`）之前 acquire、在 LP mint 与 `cachedLpTotalSupply` 更新之后 release，覆盖快照→settle `transferFrom`→mint 全窗口。

`[代码已证]`

## 4. 启动保护语义

- 当前普通 swap 路径为 execute-or-revert。
- 启动保护语义体现为 launch fee 衰减窗口与显式 preorder settlement 结算通道。
- preorder settlement 只消费 preorder 托管的 `uAsset`，不消费普通 genesis 本金；preorder 容量口径由 launcher 侧 `totalNormalFunds + totalLeveragedDebt` 决定。
- 解锁后的公开 swap 保护由 launcher 在 `Locked -> Unlocked` 迁移的 settlement 调用完成后写入各受保护池的 `publicSwapResumeTime`，再由 `hook.beforeSwap` 执行；hook-side public swap protection 在该写入后生效。
- `Locked -> Unlocked` 同交易 settlement 顺序与公开 swap 恢复时间写入约束见 [docs/spec/invariants.md](../invariants.md) INV-07A / INV-12（窗口数值见 [docs/spec/verse/config-matrix.md §3](../verse/config-matrix.md)）。
- v4 LP fee 的代码结构事实是：新池初始化为零、当前没有 `updateDynamicLPFee`、普通 `beforeSwap` 不返回 fee override。它们不增加 runtime、deployment 或 governance check。PoolManager protocol fee 是外部 controller 的行为，不受 Memeverse 权限或保证，也不属于本任务的 protocol fee 模型。
- swap API 保持单路径结算语义。

## 5. LP 总量与零供给语义

- 加/减流动性路径在 LP token `mint` / `burn` 后直接同步 `cachedLpTotalSupply[poolId]`，保持缓存总量与实际 LP token `totalSupply()` 一致；fee per-share 以全部已发行 LP token 为分母，不设置永久锁定或排除分账的 LP 份额；不要求额外的一行转发 helper。
- LP token 转账（`transfer` / `transferFrom`）先经 `UniswapLP.sol::_update` 对 `from` / `to` 调用 `MemeverseUniswapHookUpgradeable.sol::updateUserSnapshot(poolId, ...)`，结晶 fee 快照：将可 claim fee 累入 `pendingFee0` / `pendingFee1` 并推进 offset（`SwapFacet.sol::updateUserSnapshotLogic`）`[代码已证]`。
  - `mint` / `burn` 不经该钩子：hook 内部加/减流动性路径直接经 `MemeverseUniswapHookUpgradeable.sol::_updateUserSnapshotViaFacet` 完成同一结晶。
  - add-liquidity 的快照→mint 窗口持 lifecycle lock：`MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore` 在接收人 fee 快照之前 acquire、在 LP mint 与 `cachedLpTotalSupply` 更新之后 release，保证快照 offset 与 mint 时点 feePerShare 一致；remove-liquidity 的快照与 burn 先于 take 窗口、窗口后无份额发行，无需持锁。
  - 自转（`from == to` 非零）只结晶一次：`updateUserSnapshot` 在同一交易内按地址幂等（SwapFacet 零增长 fast path）。
- swap 路径使用 `_activeLpSupplyForSwap` 作为有效 LP 供应量的业务入口：`cachedLpTotalSupply == 0` 时 fallback 到 `poolManager.getLiquidity(poolId)`。
  - 两者均为 0 → 非零普通动态报价与公开 swap 都必须拒绝；不能以零输出、partial fill 或费用预估伪装为可执行。
  - 缓存为 0 但 pool liquidity > 0 → revert `NoActiveLiquidityShares`（不一致状态，不应出现）。
- LP 全部移除后（drained pool：`cachedLpTotalSupply == 0` 且 `poolManager.getLiquidity() == 0`），三种路径行为如下：
  - **非零 quote 与公开 swap**：两者都因缺少活跃流动性拒绝。quote 不应用 `BeforeSwapDelta`、不移动资金，但仍必须在返回报价前完成同一可执行性检查；执行路径也不得在 v4 返回零 delta 后继续收取费用。
  - **preorder settlement**：`effectiveSupply == 0`（drained 池，无 LP 可接收 fee 分配）时 fail-closed。具体 selector 随 lpFee 是否非零分两种：当 `lpFeeInputAmount > 0`（常规输入）时入口 revert `NoActiveLiquidityShares`；当 gross 输入极小使 `feeOnAmount(gross, 65)` 下取整为 0 时，`NoActiveLiquidityShares` 检查被跳过，但因零流动性 swap 返回 delta=0，函数末尾的 `actualInputAmount != netInputAmount` 守卫 revert `ExactInputPartialFill`——同样 fail-closed，且该 dust 区间下 protocol fee（需 `gross >= 286`）亦为 0，无任何费用收取代入。
- LP fee 可领额度 view：`MemeverseUniswapHookLens::claimableFees(hook, key, owner)` 返回已记录 `pendingFee0/1` 加上尚未 snapshot 的增量（LP 余额 × (`feePerShare` − offset)，Q128 向下取整、保守不超领；零 owner 或未建池返回 0，零 LP 余额只返回已记录 pending）；Router 的 `previewClaimableFees(...)` 经该 Lens view 实现。`[代码已证]`
- LP fee 的收取与 claim 遵循 CEI：fee take 前先经 `_accrueLpFee` 入账（`MemeverseSwapFeeBase::_accrueLpFee` 纯记账、不转账）；`claimFeesCore` 执行链为快照结晶（经 `SwapFacet::updateUserSnapshotLogic`）→ 清零 pending → `CurrencySettler.transferWithGuard` 转账 → `FeesClaimed`。`[代码已证]`

普通动态 Swap 的零金额报价可保留兼容行为：它跳过 raw limit、流动性、容量与曲线检查，但只返回费率预览，不代表 PoolManager 的零金额执行可通过。

## 6. 运维配置边界

- Hook owner 可改：
 - `treasury`
 - protocol fee 币种支持
 - `defaultLaunchFeeConfig`
 - 以上为非穷举子集；Hook owner 完整 onlyOwner setter 清单（含 `setReferrerRebateBps` / `setPoolInitializer` / `setLpTokenImplementation` / `setFacet` 等共 7 项）以 [docs/spec/access-control.md](../access-control.md) §3 边界矩阵 MemeverseUniswapHookUpgradeable 行为唯一来源。
- Launcher owner 配置 router / hook 时的 set-time 三重校验与 launcher 侧 `memeverseUniswapHook` write-once 约束见 [docs/spec/invariants.md](../invariants.md) INV-04（权限视角见 [docs/spec/access-control.md](../access-control.md) §5）。
- `launcher` 由 hook `initialize` 一次性固化（initializer write-once），不可 retarget，不视为额外越权模型。
- Router 的 `hook/permit2` 为构造不可变参数。
- 建池可用性依赖 router/hook/launcher 五个配置指针同时一致（含 INV-04 三重校验），`Genesis -> Locked` launch-time preflight 复核与完整约束见 [docs/spec/invariants.md](../invariants.md) INV-04。
- Launcher pause 不会直接阻断 `changeStage(...)` 驱动的建池，因为 `changeStage(...)` 不是 `whenNotPaused`；但 Router/Hook 指针不一致或 `poolInitializer` 漂移会阻断新池创建（`launcher` binding 由 initialize 固化，运行时不可偏离）。

`[代码已证]`

## 7. 已知缺口与外部依赖

- Router 不发业务事件，索引主要依赖 Hook 事件与 token transfer。`[代码已证]`
- PoolManager 实例地址、Factory/部署策略属于部署环境，不在仓库固定。`[未知]`
