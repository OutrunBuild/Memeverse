# Memeverse Swap 集成说明

本文档面向前端、路由层、SDK 与第三方集成方，说明如何使用：

- `MemeverseSwapRouter`
- `MemeverseSwapRouter.quoteSwap(...)`
- `MemeverseSwapRouter` 的可选 Permit2 入口

完成 Memeverse 池子的报价、下单与 LP 管理。

fee claim 需要单独区分两类能力：

- `MemeverseSwapRouter.previewClaimableFees(...)`：只读预览 helper，仅返回 claimable fee 估算值
- `MemeverseUniswapHook.claimFeesCore(...)`：可执行 self-claim 的 Hook Core 入口

当前推荐的分层是：

- `MemeverseSwapRouter`：公开 Periphery / 普通交易与流动性统一入口
- `MemeverseUniswapHook`：Core 引擎 / 低层 API / 可执行 fee claim
- 启动期建池与首笔流动性：收敛到 `MemeverseSwapRouter.createPoolAndAddLiquidity(...)`

推荐理解为：

- **普通集成方 / 链上 SDK：只认 `MemeverseSwapRouter`**
- **fee claim 执行路径：直接认 `MemeverseUniswapHook.claimFeesCore(...)`**
- **高级集成方 / 自定义 Router：可直接接 `MemeverseUniswapHook` 的 Core API**

另外还有一个重要运维约束：

- `treasury` 必须是**被动收款地址**
- swap 栈的 protocol fee settlement currency 只允许 ERC20
- `treasury` 的 `receive()` / `fallback()` 不得继续触发 swap、加减流动性或其他重入式链上交易逻辑

---

## 1. 总体架构

当前推荐的交易入口不是直接调用 `PoolManager.swap`，而是调用：

- `MemeverseSwapRouter.swap(...)`

同样，当前推荐的 LP 入口也不是直接调用 Hook Core，而是调用：

- `MemeverseSwapRouter.addLiquidity(...)`
- `MemeverseSwapRouter.removeLiquidity(...)`
- `MemeverseSwapRouter.createPoolAndAddLiquidity(...)`（仅 Launcher 可调用的 bootstrap 入口）
- 可选：对应 `*WithPermit2(...)` 入口

原因：

1. Router 统一处理 `deadline`、`amountOutMinimum`、`amountInMaximum`
2. Router 对 swap 栈执行 fail-close 输入约束（native 拒绝 V5、收费/币种边界 V4）见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3
3. Router 提供 pair 级 helper，如 `lpToken(...)`、`quoteAmountsForLiquidity(...)`
4. Router 对普通用户路由保持公开 surface；`createPoolAndAddLiquidity(...)` 明确划为仅 `Launcher` 可调用的启动期建池/首笔流动性入口，普通集成方无需感知专用 bootstrap / settlement 接线

当前普通 swap 语义是：

- 所有 swap 都是 execute-or-revert（V10 定义见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §4）
- 公开交易入口集中在 Router

如果需要直接接入 Hook，应把它理解为：

- `MemeverseSwapRouter` = **Recommended Public Entry Points**
- `MemeverseUniswapHook` 的 Core 接口 = **Low-level Core APIs**

---

## 2. 当前最终收费语义

### 2.1 LP fee

- `LP fee` 永远在 **输入币** 上收取
- 不会因为协议收费币配置变化而改变结算币种

### 2.2 Protocol fee

- Protocol fee 币种选择规则（V4：输入侧优先、支持列表、两侧均未注册时落输入侧不回退）见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3。
- 协议费代币（`supportedProtocolFeeCurrencies`）只控制收费腿、**不门控是否收费**（规则见上一行 §3）；注册的代币应是标准 ERC20；`treasury` 必须是被动收款方，不在收款期间发起协议操作。
- 返佣（referral rebate）切流：普通 swap 若 `hookData` 前 20 字节 packed 携带非零 referrer，protocol fee 收取路径（主体 SwapFacet 的 `_collectProtocolFee`，经 Router entry `delegatecall` 到 SwapFacet 执行；rebate 公式提取为 `_computeRebate`，记账 + treasury take + emit 提取为 `_settleProtocolFee`；beforeSwap 主路径不经 `_collectProtocolFee`，改走 `_computeRebate` + `_settleProtocolFee` + 合并 take）先计算 `rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`，再 split：
  - `toTreasury = protocolFee - rebate` 经 `_takeToTreasury` 到 treasury；
  - `_settleProtocolFee` 先内联累加 Router storage 的 `pendingRebate[referrer][currency]` 并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take` 转出 `toTreasury`（interaction），最后 emit `ProtocolFeeCollected`；这段记账本身是纯 storage effect，无 facet→facet delegatecall 或 PoolManager 调用。ledger effect 先于 treasury take 与调用方的 rebate take，helper 现为严格 CEI（effect → interaction → event）：treasury take 不触发 v4 hook callback，ERC20 currency 仍会执行外部 `transfer` token 代码。beforeSwap 主路径将 rebate 与 LP fee 合并 take，afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。任一步骤失败都会回滚整笔 swap。
- rebate custody 在 hook proxy（与 LP fee 同地址，但 `pendingRebate` 账本与 LP per-share accounting 分离）；rebate currency 与该 swap 的 protocol fee currency 一致，in-kind，不进入 treasury、不经过下游 uAsset / POLend 转换。
- rebate 为 pull 模式：swap 时只记账 + take，referrer 须主动调 `MemeverseUniswapHook::claimRebate(currency, recipient)` 领取（入口在 hook，Router 直接实现；从 hook custody 将 caller/referrer 名下的 rebate 转给 `recipient`——任意非零 payout destination，不必等于 referrer；仅 self-claim，不支持第三方代领 / 签名 claim）。
- `ProtocolFeeCollected.amount`（on hook）始终是 treasury 实收（`toTreasury = protocolFee - rebate`）。仅当 `rebate > 0` 时 `toTreasury < protocolFee`，差额见 hook 上 emit 的 `ReferralRebateAccrued`；`rebate` 在 `referrerRebateBps == 0` 或小额 `mulDiv` 向下取整为 0 时可为 0，此时 `toTreasury == protocolFee` 且不 emit rebate 事件。索引器统计 protocol 总收入须按 `ProtocolFeeCollected.amount +（若存在）ReferralRebateAccrued.amount` 求和，不要仅凭「是否带 referrer」推断国库金额。
- 无 referrer（`hookData` 空或前 20 字节为零）时不切 rebate，treasury 收全额 protocol fee。
- preorder settlement 路径（`executePreorderSettlement`）不携带 referrer，不参与返佣；其 `ProtocolFeeCollected.amount` 仍是完整 protocol fee。

### 2.3 两者是分开结算的

正确理解是：

- `LP fee`：输入侧
- `Protocol fee`：池中存在协议费代币时收该代币（输入侧优先），否则收输入侧（普通池，不回退）；有 referrer 时再切 rebate 到 hook proxy custody

### 2.4 启动期收费语义

当前启动期保护语义是：

- 普通路径：`launch fee window` 费率衰减
- 特殊路径：`MemeverseLauncher -> MemeverseUniswapHook.executePreorderSettlement(...)` 固定费率（数值定义见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）

---

## 3. 关键接口

### 3.1 Router 交易入口

```solidity
function swap(
    PoolKey calldata key,
    SwapParams calldata params,
    address recipient,
    uint256 deadline,
    uint256 amountOutMinimum,
    uint256 amountInMaximum,
    bytes calldata hookData
) external returns (BalanceDelta delta);
```

参数含义：

- `key`：池子 key（`currency0` / `currency1` 的 ERC20-only 与 native 拒绝 V5 见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3）
- `params`：Uniswap v4 swap 参数
- `recipient`：最终接收输出币的地址
- `deadline`：过期时间
- `amountOutMinimum`：
  - exact-input 时用于最小输出保护
  - exact-output 时通常可传 `0`
- `amountInMaximum`：
  - exact-input 时可传 `0`
  - exact-output 时必须传
- `hookData`：公开 Router 只把前 20 字节解释为 referrer 数据；普通集成路径可传空。若要触发返佣，caller 必须用 `abi.encodePacked(referrer)` 把 referrer 地址 packed 放入前 20 字节（`abi.encode` 会左 padding 导致 `SwapFacet::_decodeReferrer` 误读，禁止使用）；长度 < 20 字节或前 20 字节为全零视为无 referrer，protocol fee 不切 rebate。preorder settlement 使用 `Launcher -> Hook.executePreorderSettlement(...) -> SettlementFacet` 的 typed Router 路径，不通过公开 swap `hookData`

返回值含义：

- `delta`：最终 swap delta

返回值聚焦最终 `delta` 结算结果。

---

### 3.2 Router 报价入口

```solidity
function quoteSwap(PoolKey calldata key, SwapParams calldata params, address trader)
    external
    view
    returns (SwapQuote memory quote);
```

`quoteSwap` 是公开的只读入口，前端、SDK、链上 Router 与聚合器可按普通 `view` 函数直接调用，无需手动构造 `staticcall`。Lens 会在内部以 `STATICCALL` 进入 non-view Hook bridge，再由 Hook 路由到报价 facet；函数 selector 与返回结构不变。

当前推荐把 Router 视为普通用户路由的统一公开入口；公开入口包含可执行用户路由与只读 helper：

- `quoteSwap(...)`
- `previewClaimableFees(...)`
- `getHookPoolKey(...)`
- `lpToken(...)`
- `quoteAmountsForLiquidity(...)`
- `quoteExactAmountsForLiquidity(...)`
- `swap(...)`
- `swapWithPermit2(...)`
- `addLiquidity(...)`
- `addLiquidityWithPermit2(...)`
- `removeLiquidity(...)`
- `removeLiquidityWithPermit2(...)`

启动期 bootstrap 单独入口：

- `createPoolAndAddLiquidity(...)`（launcher-only bootstrap）

其中 `previewClaimableFees(...)` 是只读 preview-only helper，用于查询当前可领取 fee 估算值，不执行任何结算。

当前 fee claim 执行入口是 `MemeverseUniswapHook.claimFeesCore(...)`。

- 调用方必须是 fee owner；owner 严格由 `msg.sender` 推导
- 参数中的 `recipient` 可指定实际收款地址
- 当前无 `owner` 显式参数
- 当前不支持 `nonce` / `deadline` / signature
- 当前不支持第三方 relayed claim，也不支持 EIP-712 signature-based fee claim

对只知道 token pair、不想感知 `PoolKey` / Hook 细节的集成方，当前只读 helper 可以这样理解：

- `lpToken(tokenA, tokenB)`：返回该 pair 对应的 Hook LP token 地址
- `quoteAmountsForLiquidity(tokenA, tokenB, liquidityDesired)`：按当前池价返回目标 LP liquidity 需要的两侧 token 数量
- `quoteExactAmountsForLiquidity(...)`：面向已初始化池，使用当前 `slot0` 为目标 liquidity 报价。
- bootstrap 集成契约：Router 从 Launcher 提交的 desired budgets 执行，并把 actual execution / actual spend 返回给 Launcher 做 post-bootstrap accounting（集成真源不是 preview/equality）。
- bootstrap 记账语义、auxiliary underspend 处置、unused bootstrap `uAsset` / `memecoin` 处置见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)。

---

### 3.3 Permit2 入口要点

Permit2 入口是并行路径，不替代现有 approve 路径。集成时应注意：

- `permit2()` 可用于确认 Router 绑定的 Permit2 合约地址
- `swapWithPermit2(...)` / `addLiquidityWithPermit2(...)` / `removeLiquidityWithPermit2(...)` 只负责签名拉资
- 池创建仅走 `Launcher -> Router.createPoolAndAddLiquidity(...)`，Router 侧受 `onlyLauncher` 限制，不是 Permit2 路径
- Permit2 拉资后，deadline、slippage、Hook 语义与普通入口一致
- `removeLiquidity(...)` / `removeLiquidityWithPermit2(...)` 的最终 `recipient` 不能为 `address(0)`；共享 Router payout helper 会 fail-close（recipient 非零 V7 见 [docs/spec/invariants.md](../invariants.md) INV-07）
- Permit2 只处理 ERC20；swap 栈不接受 native 资产，也不接受 `msg.value`（V5 见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3；Permit2 入口语义 V6 见 [docs/spec/swap/permit2.md](permit2.md)）
- 签名里的 `spender` 必须是 Router 地址，`transferDetails.to` 必须是 Router

---

## 4. `SwapQuote` 字段说明

`SwapQuote` 当前包含这些核心字段：

- `feeBps`
- `estimatedUserInputAmount`
- `estimatedUserOutputAmount`
- `estimatedProtocolFeeAmount`
- `estimatedLpFeeAmount`
- `protocolFeeOnInput`

### 4.1 输入/输出金额字段

- `estimatedUserInputAmount`
  - 用户最终总共要支付的输入数量
- `estimatedUserOutputAmount`
  - 用户最终净到手的输出数量

### 4.2 手续费字段

- `estimatedLpFeeAmount`
  - LP fee 金额
  - 永远在输入侧计价
- `estimatedProtocolFeeAmount`
  - protocol fee 金额
  - 输入币优先，输入不支持时再看输出币；两侧均未注册（普通池）时落输入侧不回退（见 uniswap-v4.md §3）

### 4.3 `protocolFeeOnInput`

- `true`：本次 protocol fee 在输入侧收
- `false`：本次 protocol fee 在输出侧收

---

## 5. Preorder Settlement 集成注意事项

- 这是启动结算专用通道，不是普通用户交易接口。
- `MemeverseLauncher` 直接调用 `MemeverseUniswapHook.executePreorderSettlement(...)`，Hook Router delegatecall `SettlementFacet` 并使用 typed settlement unlock callback。
- Hook 侧 caller 约束（`msg.sender == launcher`）见 [docs/spec/invariants.md](../invariants.md) INV-04（权限视角见 [docs/spec/access-control.md §5](../access-control.md)）。
- 该路径使用固定总费率（数值定义见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）。
- `MemeverseLauncher` 接入 Router 时的 set-time 三重校验与 `Genesis -> Locked` launch-time preflight 见 [docs/spec/invariants.md](../invariants.md) INV-04（权限视角见 [docs/spec/access-control.md](../access-control.md) §5）。

### 5.1 资金流与 approve 路径

Preorder settlement 的资金流分三步：

1. **Hook 从 Launcher 收取 input 费用**：LP fee 经 `_accrueLpFee` 记入 per-share 累计（纯记账，token 拉款合并到第 2 步），protocol fee 经 `transferFrom` 直接转给 treasury。
2. **Hook 从 Launcher 拉取 netInput 与 LP fee 到 hook proxy custody**：一次 `transferFrom(launcher, address(this), netInputAmount + lpFeeInputAmount)`（同源同收款人合并，省一次 ERC20 transferFrom）。Settlement logic 经 Router entry `delegatecall` SettlementFacet 执行（SettlementFacet 持有 unlock 回调上下文，负责 swap、settle、take 与 output-side protocol fee 扣减）。
3. **Hook proxy 余额 settle 给 PoolManager**：`CurrencySettler.settle` 中 `payer == address(this)`（delegatecall 下即 hook proxy）走 `transfer` 分支，不需要 approve。

Launcher 只需对 **Hook 地址**做一次 infinite approve（`_safeApproveInf(uAsset, hookAddress)`）。所有 `transferFrom` 的 spender 都是 hook，to 可以是 hook 自身或 treasury，不需要额外 approve PoolManager。

普通集成方不应自行构造这条路径。

---

## 6. Hook Core 的定位

Hook 仍保留（LP 与池操作低层入口）：

- `addLiquidityCore(...)`
- `removeLiquidityCore(...)`
- `claimFeesCore(...)`

报价（quote）不在 Hook Core：普通集成方走 `MemeverseSwapRouter.quoteSwap`，链上自定义 Router / 聚合器走 `MemeverseUniswapHookLens.quoteSwap`（两个公开入口均为 `view`；Lens 内部以 `STATICCALL` 进入 Hook 的 `quoteSwapFeeWithContext`，Hook 再 `DELEGATECALL` 到 `DynamicFeeFacet.quote`，详见 [docs/ARCHITECTURE.md](../../ARCHITECTURE.md) 费率报价表）。Hook 没有名为 `quoteSwap` 的 selector。

这些低层接口主要面向：

- 官方 Router
- 其他链上自定义 Router / 聚合器
- 高级集成场景

但应注意：

- 当前 Hook Core 只面向动态费池
- 普通集成方优先走 Router，而不是自己拼 `PoolManager.swap`

---

## 7. 最终理解方式

把当前 Memeverse Swap 理解成：

- `Router`：统一公开入口、预算与退款管理层
- `Hook`（diamond Router）：admin/view/liquidity 入口直接实现，callback / 动态费计算 / 协议收费分账 / LP 记账 / preorder settlement 经 Router entry `delegatecall` 分发到 SwapFacet / DynamicFeeFacet / SettlementFacet（三 facet 共享 Router storage，对外 ABI 统一在 hook 地址）
- `preorder settlement`：`Launcher -> Hook` 的受限专用结算通道（SettlementFacet 执行 unlock/swap/settle/take）

其中普通交易、启动期费率、LP 记账和结算专用通道都在同一套 Router + Hook（diamond）语义下协同完成。
