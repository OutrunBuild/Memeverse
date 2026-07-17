# MemeverseV2 集成边界：Uniswap v4

## 1. 范围

本文描述 Memeverse 与 Uniswap v4 的集成边界（Router/Hook/PoolManager）。  
标签：

- `[代码已证]`
- `[未知]`

## 2. 组件边界

### 2.1 Periphery（推荐公开入口）

- `MemeverseSwapRouter` 负责对外 `quote/swap/addLiquidity/removeLiquidity` 与可选 Permit2 拉资（swap 与流动性操作）。
- Router 的 `previewClaimableFees(...)` 仅是只读 preview-only helper，不执行 fee claim。
- Router 的 quote/preview 只读路径委托给构造绑定的 `MemeverseUniswapHookLens`；Lens 必须有代码，且 Lens `poolManager` 必须与 Router 构造注入的 PoolManager 一致。Router 与 Hook 也必须共享同一个 PoolManager——Router 在自身 immutable PoolManager 上发起 unlock/initialize，该 PoolManager 回调 Hook 的 `onlyPoolManager` 回调（比对 Hook 的 poolManager immutable），不一致则 `NotPoolManager` 让所有 swap/池初始化 revert（DoS）；readiness（`_requireSwapReady`）在开闸前校验 `router.poolManager() == hook.poolManager()`（错误串 `ROUTER_POOL_MANAGER_NOT_READY`），与 3 facet 的 `_requireFacetPoolManager` 对称。`MemeverseUniswapHookLens.poolDynamicFeeState` 调用 hook getter `MemeverseUniswapHook::dynamicFeeStateOf(poolId)` 读取 Router storage 的 `DynamicFeeState`；该 getter 为 `view`，直接读取 `dynamicFeeState[poolId]`，不经 facet delegatecall，对称于 `addressBatchStateOf`，故 `Lens.poolDynamicFeeState` 亦为 `view`。公开的 `MemeverseUniswapHookLens.quoteSwap` 与 `MemeverseSwapRouter.quoteSwap` 保持 `view`：Lens 对 non-view Hook bridge `quoteSwapFeeWithContext` 发起 `STATICCALL`，Hook bridge 再经 `DELEGATECALL` 路由到 `DynamicFeeFacet.quote`。只有 Hook bridge 因 solc 0.8.35 Error 8961（`view` 函数内禁止 `delegatecall`）保持 non-view；EIP-214 的静态上下文会穿过后续 `DELEGATECALL` 传播到 facet，任何状态写入都会回滚。只读保证来自该 EVM 静态上下文，而非 `eth_call` 不提交状态的 RPC 行为；函数 selector 与返回结构均不变。`MemeverseUniswapHook::addressBatchStateOf(trader, poolId)` 同为 `view`，直接读取 Router storage 的 `addressBatchState`。
- Router 的 ERC20 payout helper 对 `recipient == address(0)` fail-close；remove-liquidity 出款不会把资产发送到零地址。
- 池创建只允许 Launcher 调用 `createPoolAndAddLiquidity(...)`，建池必须经 `Launcher -> Router`，由 Launcher 提供 desired budgets，再由 Router 执行实际建池与首笔加池；池创建不支持 Permit2。
- Router 对 bootstrap 的集成契约是“实际执行后返回 actual spend / actual liquidity”（非 preview-equality 契约）；Launcher 的 post-bootstrap accounting 与记账语义见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)。
- Router 内部固定构造 pool key（`fee = DYNAMIC_FEE_FLAG`、固定 `tickSpacing`、`hooks = configured hook`）；具体固定值与 Hook 侧约束见 [docs/spec/invariants.md](../invariants.md) INV-08（V23）。
- exact-output 强制 `amountInMaximum`；所有 swap 为 execute-or-revert（V10，见 §4）。

`[代码已证]`

### 2.2 Core 引擎（Hook）

- `MemeverseUniswapHook` 负责：
 - 动态费计算与启动窗口费率下限
 - protocol fee 与 LP fee 归集
 - LP token per pool + fee per share 记账
 - `addLiquidityCore/removeLiquidityCore/claimFeesCore` 低层能力；其中 fee claim 执行入口是 `claimFeesCore(...)`，fee owner 由 `msg.sender` 推导，`recipient` 可指定，当前不支持 relayed/signature-based claim
- 内部架构为 diamond：callback / fee 分账 / LP per-share accounting 经 Router entry `delegatecall` 到 SwapFacet，动态费 state 读写经 `delegatecall` DynamicFeeFacet，preorder settlement 经 `delegatecall` SettlementFacet；三 facet 共享 Router storage，对外 ABI 统一在 hook 地址。
- `removeLiquidityCore(...)` 要求 `recipient != address(0)`，否则回退 `ZeroAddress()`（recipient 非零规则见 [docs/spec/invariants.md](../invariants.md) INV-07）。
- Hook 强制池约束（动态费 + 固定 `tickSpacing`）见 [docs/spec/invariants.md](../invariants.md) INV-08（V23）。

`[代码已证]`

### 2.3 Preorder settlement 显式结算通道

- 启动结算调用链是 `MemeverseLauncher -> MemeverseUniswapHook.executePreorderSettlement(...)`。
- Launcher bootstrap pool creation 采用集成契约“desired budgets -> actual Router spend -> post-bootstrap accounting”（Router 返回 actual spend）。
- bootstrap 记账语义、auxiliary underspend 处置见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)。
- Hook 仅接受已绑定 launcher 的直接调用（caller 约束完整规则见 [docs/spec/invariants.md](../invariants.md) INV-04），并将 `unlock/swap` 逻辑经 Router entry `delegatecall` 委托给 SettlementFacet。SettlementFacet 用 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)` 发起 unlock；Router 读取首个 ABI word 的 raw `uint256`，仅对 `ModifyLiquidity` 与 `Settlement` 两个当前支持值分支，其他值回退 `InvalidUnlockCallbackKind(rawKind)`。
- `SettlementCallbackData` 与 `SettlementResult` 定义在 `ISettlementFacet`；`settlementUnlockCallback` 使用 typed calldata / typed return。因 `SettlementCallbackData` 当前全静态，Router 在 kind 校验后用 `bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])` 前缀转发到 SettlementFacet（跳过 memory decode + 二次 encode；与 `abi.encodeCall` 字节等价）。Router 把 `_facetDelegatecall` 的原始 returndata 直接作为 `unlockCallback(bytes)` 返回内容交还 PoolManager，`executeSettlementLogic` 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。外部 v4 `unlockCallback(bytes)` ABI 不变。
- settlement swap 在 hook 地址下发起，是 v4 hook self-call；pinned v4-core 在 `msg.sender == address(key.hooks)` 时同时跳过 `beforeSwap` 与 `afterSwap`，固定 settlement fee 由 settlement 路径自处理。外部 callback-token 重入 swap 不是 self-call：跨池的仍执行普通 callback 与 public fee 路径；同池生命周期重入被 `SwapFacet` per-pool transient lock 阻断（`beforeSwapLogic` 入口 acquire / `afterSwapLogic` 出口 release，同 poolId 重入触发 `SwapLifecycleReentrant`），防止 outer swap 报价固定后 callback token 推进动态费 state 造成费率失真（见 [docs/spec/invariants.md](../invariants.md) INV-04A）。
- 该路径使用固定总费率（数值定义见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）。
- 进入该路径前，Launcher / POLend 的部署资金口径只统计 `totalNormalFunds + totalLeveragedDebt`，不统计 preorder，且该口径必须保持 `<= type(uint128).max`。

`[代码已证]`

## 3. 收费/币种/native 边界

本节是 swap 栈收费语义、币种配置与 native 拒绝规则的 canonical home。其它 swap 文档（`swap-flow.md`、`swap-integration.md`、`permit2.md`、`common/common-foundations.md`）只引用本节，不重述这些规则本体。

- `LP fee` 永远在输入侧。
- `Protocol fee` 币种由 `supportedProtocolFeeCurrencies` 决定：输入侧优先，输入不支持再看输出侧；若两侧均未注册（普通池），protocol fee 仍落在输入侧，swap 正常成交、不回退。
  - 解析式：`protocolFeeOnInput = inputSupported || !outputSupported`。真值表：输入侧注册→input；仅输出侧注册→output；两侧注册→input；两侧均未注册→input（普通池按输入侧收 protocol fee）。
- Exact-output swap 若实际 gross output 小于请求输出，Hook 回退 `ExactOutputPartialFill()`。
- Exact-input swap 若实际 pool input 与预期不符，Hook 回退 `ExactInputPartialFill()`。
- `FeeMath.PROTOCOL_FEE_SHARE_BPS = 3500`；shared fee math 将 `feeBps` 按 35% protocol / 65% LP 拆分。
- 公开 swap 始终使用正常费率路径：`feeBps = max(current launch fee, dynamic fee, FEE_BASE_BPS)`；dynamic fee 故障通过 `setFacet(DYNAMIC_FEE_FACET_ROLE, newAddr)` 升级/修复处理，不提供 bypass mode。
- 返佣（referral rebate）：普通 swap 可在 `hookData` 前 20 字节 packed 携带 referrer 地址（caller 用 `abi.encodePacked(referrer)`；`abi.encode` 会左 padding 导致 `SwapFacet::_decodeReferrer` 误读，禁止使用）。有 referrer 时，`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（默认 `referrerRebateBps = 1000` = 总 fee 的 10%），`toTreasury = protocolFee - rebate`。`SwapFacet::_settleProtocolFee`（`_collectProtocolFee` 调用；beforeSwap 主路径直接调）先内联累加 Router storage 的 `pendingRebate[referrer][currency]` 并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take` 转出 treasury share（interaction），最后 emit `ProtocolFeeCollected`；记账本身无 PoolManager 调用或 facet→facet delegatecall，并且先于 treasury take 与调用方执行的 rebate take。该 helper 现为严格 CEI（effect → interaction → event）：`PoolManager.take` 不触发 v4 hook callback，但 ERC20 currency 的 `transfer` 仍执行外部 token 代码；安全性依赖 fee currency 为标准 ERC20（注册的协议费代币；普通池下为输入代币）、treasury 是被动收款方，以及任一步失败时整笔事务原子回滚。beforeSwap 主路径（`lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0`）不经 `_collectProtocolFee`，走 `_computeRebate` + `_settleProtocolFee`，并将 rebate take 与 LP fee take 合并为一次 `poolManager.take(currencyIn, address(this), lpFeeInputAmount + rebate)`；afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。无 referrer 时不切 rebate，protocol 收全额 35%。rebate custody 在 hook proxy（`address(this)` 在 delegatecall 下即 hook proxy；v4 `PoolManager.take` delta 记调用者 hook，被 beforeSwap specifiedDelta credit 抵消；`pendingRebate` 账本在 Router storage，与 LP per-share accounting 分离）；referrer 经 `MemeverseUniswapHook::claimRebate` pull 领取（入口在 hook，Router 直接实现）。preorder settlement 路径不携带 referrer，不参与返佣。**返佣按链独立**：每条链的 hook 独立 settle / accrue / claim 该链 swap 的 rebate，无 LayerZero 同步、无跨链聚合、无全局 referrer 状态；referrer 在 A 链累积的 `pendingRebate` 只能在 A 链经 A 链的 hook `claimRebate` 领取，不能在 B 链领。
- `_decodeReferrer` 在 `SwapFacet::beforeSwapLogic` 与 `SwapFacet::afterSwapLogic` 各解码一次；rebate 路径调用点：beforeSwap 主路径（`lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0`）走 `_computeRebate` + `_settleProtocolFee` + 合并 take，beforeSwap 边界（lpFee==0、protocolFee==0、或 effectiveSupply==0/drained pool）与 afterSwap 3 点（exact-input output 侧、exact-output input 侧、exact-output output 侧）走 `_collectProtocolFee`（内含 `_computeRebate` + `_settleProtocolFee` + 独立 rebate take）；以上均传入 referrer。
- native 拒绝（V5）：swap 栈只支持 ERC20/ERC20 pair；`key.currency0` / `key.currency1` 任一侧为 `address(0)` 直接 `revert NativeCurrencyUnsupported`。swap 栈不接受 `msg.value`，Permit2 也不为 native 提供任何兜底路径。
- 非 standard 余额语义 token（fee-on-transfer / rebasing / 其它使名义 `amount` 与实到余额不一致的 token）不在支持范围内：swap 栈（含 preorder settlement 路径）一律按名义 `amount` 执行 `transferFrom` / `settle` / `take`。FoT token 下 settle 因余额不足而整笔原子回滚，不产生资金损失；准入应排除此类 token，运行时不做 FoT 检测。
- 同池 swap 生命周期重入保护：`SwapFacet.beforeSwapLogic` 在 `_revertIfPublicSwapBlocked(poolId)` 之后经 `MemeverseTransientState.acquireSwapLifecycleLock(poolId)` acquire（故仍在保护期内的同池重入优先回退 `PublicSwapDisabled`，保护期外的同池生命周期重入才回退 `SwapLifecycleReentrant`）per-pool transient lock，`afterSwapLogic` 出口 release；同一 poolId 在 outer `beforeSwap → _swap → afterSwap` 未完成期间再次进入 `beforeSwapLogic` 触发 `SwapLifecycleReentrant` revert。transient storage 事务结束自动清除，revert 不留脏 lock；settlement self-call 因 v4 跳过 callback 不进这两个函数的 acquire/release 路径，但 `SettlementFacet.executeSettlementLogic` 在 Phase 1 `transferFrom` 前 acquire、Phase 3 `_updateAfterSwap` 后的函数末尾 release 同一 per-pool lock，覆盖 Phase 1 transferFrom → Phase 3 `_updateAfterSwap` 全窗口（含 settle/take 窗口）；settlement self-call 不重复 acquire，无死锁（见 [docs/spec/invariants.md](../invariants.md) INV-04A）；跨池嵌套 swap 因 per-pool key 互不影响。

`[代码已证]`

## 4. 启动保护语义

- 当前普通 swap 路径为 execute-or-revert。
- 启动保护语义体现为 launch fee 衰减窗口与显式 preorder settlement 结算通道。
- preorder settlement 只消费 preorder 托管的 `uAsset`，不消费普通 genesis 本金；preorder 容量口径由 launcher 侧 `totalNormalFunds + totalLeveragedDebt` 决定。
- 解锁后的公开 swap 保护由 launcher 在 `Locked -> Unlocked` 迁移的 settlement 调用完成后写入各受保护池的 `publicSwapResumeTime`，再由 `hook.beforeSwap` 执行；hook-side public swap protection 在该写入后生效。
- `Locked -> Unlocked` 同交易 settlement 顺序与公开 swap 恢复时间写入约束见 [docs/spec/invariants.md](../invariants.md) INV-07A / INV-12（窗口数值见 [docs/spec/verse/config-matrix.md §3](../verse/config-matrix.md)）。
- swap API 保持单路径结算语义。

## 5. LP 总量与零供给语义

- 加/减流动性路径在 LP token `mint` / `burn` 后直接同步 `cachedLpTotalSupply[poolId]`，保持缓存总量与实际 LP token `totalSupply()` 一致；fee per-share 以全部已发行 LP token 为分母，不设置永久锁定或排除分账的 LP 份额；不要求额外的一行转发 helper。
- swap 路径使用 `_activeLpSupplyForSwap` 作为有效 LP 供应量的业务入口：`cachedLpTotalSupply == 0` 时 fallback 到 `poolManager.getLiquidity(poolId)`。
  - 两者均为 0 → 返回 0，允许零流动性 quote 语义正常执行。
  - 缓存为 0 但 pool liquidity > 0 → revert `NoActiveLiquidityShares`（不一致状态，不应出现）。
- LP 全部移除后（drained pool：`cachedLpTotalSupply == 0` 且 `poolManager.getLiquidity() == 0`），三种路径行为如下：
  - **quote（Lens 预览）**：quote 为纯模拟，不应用 `BeforeSwapDelta`/不移动资金，零流动性下不 revert；底层 `quoteSwapFeeWithContext`/`PreparedSwapFee`（内部结构，非公开 `SwapQuote` 字段）的池侧 deliverable 估算（gross input/output/grossOutput）在 `liquidity==0` 下均为 0。公开 `SwapQuote` 字段按方向分化：exact-input（`amountSpecified < 0`）下 `estimatedUserInputAmount` = 用户请求输入（非零，echo `uint256(-amountSpecified)`），`estimatedLpFeeAmount` = `feeOnAmount(userInput, lpFeeBps) > 0`（`feeBps` 保留 floor `max(launch fee, FEE_BASE_BPS)`，`lpFeeBps >= 65`），`estimatedUserOutputAmount` = 0（drained pool 无 deliverable 输出），`estimatedProtocolFeeAmount` 在 `protocolFeeOnInput` 时非零（`feeOnAmount(userInput, protocolFeeBps)`），否则 0（由 `feeOnAmount(estimatedGrossOutputAmount=0, protocolFeeBps)` 收敛，drained 下 mulDiv(0,…) 向下取整为 0）；exact-output（`amountSpecified > 0`）下池侧估算为 0，gross>0 门控（`Lens.sol:85`）使 `estimatedUserOutputAmount` = 0，`estimatedLpFeeAmount`/`estimatedProtocolFeeAmount` 由零输入/输出派生亦为 0——原"全方向归零"说法仅在此方向成立。`feeBps` 在两方向均保留 floor（动态费在 `amount=0`/`liquidity=0` 时早返，跳过 amount 计算但不重置 `feeBps`）。协议费输出侧子情况不 panic：gross 输出为 0，按有界减法收敛到 0。
  - **可执行公开 swap**：因零流动性无法成交而统一 revert。exact-input 在 afterSwap partial-fill 守卫 revert `ExactInputPartialFill`（`actualPoolInput == 0 ≠ expectedPoolInput > 0`），exact-output 在 afterSwap partial-fill 守卫 revert `ExactOutputPartialFill`（`actualOutputAbs == 0 < minimumOutputAbs > 0`），与协议费落在输入侧还是输出侧无关。底层 SwapMath 在零流动性下两方向均返回 `amountIn=0, amountOut=0, fee=0`（走 `sqrtPriceNext = target` 的 "capped by target" 分支，不触发 `InvalidPriceOrLiquidity`），`Pool.swap` 循环正常返回 delta=0，控制流到达 afterSwap 守卫；beforeSwap 的 gross 估算额同样按有界减法收敛到 0，不会在进入 pool swap 前提前 panic。注：经 PoolManager 公开执行的 swap，上述 selector 被 V4 包装层（`Hooks.callHook` → `WrappedError`，ERC-7751）包裹，不 verbatim 浮现于 revert data，故不应按 `.selector` 直接断言；hook 自结算路径（`msg.sender == hook`，如 preorder settlement）跳过 swap callback，不触发此 revert。
  - **preorder settlement**：`effectiveSupply == 0`（drained 池，无 LP 可接收 fee 分配）时 fail-closed。具体 selector 随 lpFee 是否非零分两种：当 `lpFeeInputAmount > 0`（常规输入）时入口 revert `NoActiveLiquidityShares`；当 gross 输入极小使 `feeOnAmount(gross, 65)` 下取整为 0 时，`NoActiveLiquidityShares` 检查被跳过，但因零流动性 swap 返回 delta=0，函数末尾的 `actualInputAmount != netInputAmount` 守卫 revert `ExactInputPartialFill`——同样 fail-closed，且该 dust 区间下 protocol fee（需 `gross >= 286`）亦为 0，无任何费用收取代入。

`[代码已证]`

## 6. 运维配置边界

- Hook owner 可改：
 - `treasury`
 - protocol fee 币种支持
 - `launcher`
 - `defaultLaunchFeeConfig`
 - 以上为非穷举子集；Hook owner 完整 onlyOwner setter 清单（含 `setReferrerRebateBps` / `setPoolInitializer` / `setLpTokenImplementation` / `setFacet` 等共 8 项）以 [docs/spec/access-control.md](../access-control.md) §3 边界矩阵 MemeverseUniswapHook 行为唯一来源。
- Launcher owner 配置 router / hook 时的 set-time 三重校验与 launcher 侧 `memeverseUniswapHook` write-once 约束见 [docs/spec/invariants.md](../invariants.md) INV-04（权限视角见 [docs/spec/access-control.md](../access-control.md) §5）。
- Hook owner 在配置完成后仍可 retarget `launcher`；这是接受的同一 trust boundary 内配置权，不视为额外越权模型。
- Router 的 `hook/permit2` 为构造不可变参数。
- 建池可用性依赖 router/hook/launcher 五个配置指针同时一致（含 INV-04 三重校验），`Genesis -> Locked` launch-time preflight 复核与完整约束见 [docs/spec/invariants.md](../invariants.md) INV-04。
- Launcher pause 不会直接阻断 `changeStage(...)` 驱动的建池，因为 `changeStage(...)` 不是 `whenNotPaused`；但 Hook `launcher` retarget、Router/Hook 指针不一致或 `poolInitializer` 漂移会阻断新池创建。

`[代码已证]`

## 7. 已知缺口与外部依赖

- Router 不发业务事件，索引主要依赖 Hook 事件与 token transfer。`[代码已证]`
- PoolManager 实例地址、Factory/部署策略属于部署环境，不在仓库固定。`[未知]`
