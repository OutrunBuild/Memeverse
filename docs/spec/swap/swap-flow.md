# Memeverse Swap 流程图

本文档聚焦当前 `swap`、`preorder settlement` 与 LP 主路径的执行与资金流，不展开治理、部署与链下流程。
其中资金准备既可来自常规 approve 路径，也可来自 `*WithPermit2(...)`。

相关实现主要位于：

- `src/swap/MemeverseSwapRouter.sol`
- `src/swap/MemeverseUniswapHook.sol`
- `src/swap/SwapFacet.sol` / `src/swap/DynamicFeeFacet.sol` / `src/swap/SettlementFacet.sol`（diamond facet，经 Router entry `delegatecall` 分发，共享 hook storage；详见 §1.1 / §3）

---

## 1. 总体交易执行流

```mermaid
flowchart TD
    A[用户调用 Router.swap / swapWithPermit2] --> B[Router 基础校验]
    B --> B1{currency0 或 currency1 是否为 address(0)?}
    B1 -- 是 --> BX[revert NativeCurrencyUnsupported]
    B1 -- 否 --> C[准备 ERC20 输入资金]
    C --> D[调用 PoolManager.swap]
    D --> E[Hook.beforeSwap]
    E --> F[执行动态费与启动期费率逻辑]
    F --> G[PoolManager 完成 swap]
    G --> H[Hook.afterSwap]
    H --> I[Router 做 minOut / maxIn 校验]
    I --> K[返回 BalanceDelta]
```

说明：

- 普通 swap 采用单路径结算，execute-or-revert（V10 定义见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §4）。
- swap 栈只支持 ERC20/ERC20 pair；native 拒绝规则（V5）与收费/币种边界见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3。
- 启动期保护通过 Hook 内的 `launch fee window` 费率逻辑体现。

### 1.1 返佣资金流（Referral Rebate）

普通 swap 携带 referrer 且收取 protocol fee 时，SwapFacet 的返佣处理按收费入口分流：满足合并领取条件的 `beforeSwap` 路径直接执行 `_computeRebate` 与 `_settleProtocolFee`，并将 LP fee 与 rebate 合并为一次 `PoolManager.take` 至 hook proxy；其余仍收取 protocol fee 的 `beforeSwap` 分支，以及 `afterSwap` 的 protocol-fee 路径，经 `_collectProtocolFee` 处理，rebate 非零时单独 `take`。rebate custody 在 hook proxy（`address(this)` 在 delegatecall 下为 hook proxy），`pendingRebate` 账本在 Router storage。

```mermaid
sequenceDiagram
    participant S as Swapper
    participant PM as PoolManager
    participant H as Hook (Router)
    participant R as Referrer

    S->>PM: swap(..., hookData=encodePacked(referrer))
    PM->>H: beforeSwap / afterSwap
    H->>H: entry shell delegatecall SwapFacet，_computeRebate 算 rebate，_settleProtocolFee 记账+emit 先于 treasury take
    Note over H: toTreasury = protocolFee - rebate<br/>LP fee 留在 hook<br/>beforeSwap 主路径(lpFee>0 && protocolFee>0 && effSupply!=0)：LP fee take 与 rebate take 合并为一次 take(currencyIn, address(this), lpFee+rebate)，同币种同收款人合并，省一次 PoolManager take + 一次 ERC20 transfer；afterSwap / beforeSwap 边界仍各独立 take（rebate 由 _collectProtocolFee 内 take）
    H->>H: 内联 pendingRebate[referrer][currency] += rebate + emit ReferralRebateAccrued（effect：写 hook storage，无 facet→facet delegatecall，无 PoolManager 调用）
    H->>PM: take toTreasury 到 treasury
    H->>PM: take LP fee 到 hook custody（beforeSwap 主路径并入下方 rebate take 合并）
    H->>PM: take rebate 到 hook proxy（beforeSwap 主路径与 LP fee 合并为一次 take；afterSwap / 边界由 _collectProtocolFee 独立 take；interaction：address(this)，delta 记 hook 被 specifiedDelta credit 抵消；与记账同在 unlock callback 原子执行，take 失败整笔回滚）
    PM-->>S: BalanceDelta

    R->>H: claimRebate(currency, recipient)
    Note over H: Router 直接实现, CEI: pendingRebate 先清零
    H->>R: transfer rebate 到 recipient
```

说明：

- **rebate custody 在 hook proxy**：`MemeverseUniswapHook` 的 callback/fee logic 由 SwapFacet / DynamicFeeFacet 经 Router entry `delegatecall` 执行并共享 Router storage。rebate `take` recipient = `address(this)`（hook proxy），`pendingRebate` 在 Router storage，`claimRebate`/`pendingRebateOf` 入口在 hook。
- **rebate currency = 该 swap protocol fee 的 currency**：由 `protocolFeeOnInput`（输入侧优先，否则输出侧）决定；rebate 与 protocol fee 同币种（in-kind）。LP fee 始终位于输入侧（currencyIn），与 protocolFeeOnInput 无关。无 referrer 时不切 rebate，protocol 收全额 35%。
- **claimRebate 在 hook 可调**：`MemeverseUniswapHook::claimRebate(currency, recipient)`（Router 直接实现）；hook 持有的 token 余额偿付能力见 [docs/spec/invariants.md](../invariants.md) INV-20。
- **preorder settlement 路径不携带 referrer，不参与返佣**：`executePreorderSettlement` 走 `Launcher -> Hook -> SettlementFacet`（Router entry `delegatecall`，见 §3），`hookData = bytes("")`，普通 swap 的返佣路径（beforeSwap 主路径 `_computeRebate` + 合并 take，及 beforeSwap 边界 / afterSwap 的 `_collectProtocolFee`）均不触发，protocol 收全额固定 fee 不切 rebate。

---

## 2. 启动期费率窗口

```mermaid
flowchart TD
    A[PoolInitialized] --> B[记录 poolLaunchTimestamp]
    B --> C{当前时间是否仍在 decayDurationSeconds 内?}
    C -- 是 --> D[使用 launch fee floor 约束]
    C -- 否 --> E[回到正常动态费 / 最小费逻辑]
```

说明：

- 新池初始化后会记录 `poolLaunchTimestamp`。
- 在衰减窗口内，fee 从 `startFeeBps` 逐步下降到 `minFeeBps`。
- 窗口结束后，回到常规动态费与最小费逻辑。

---

## 3. Preorder Settlement 显式通道

> typed unlock payload、raw discriminator 路由、typed returndata 与 v4 self-call callback skip 均已实现。`[代码已证]`

```mermaid
sequenceDiagram
    participant L as Launcher
    participant H as Hook (Router)
    participant SF as SettlementFacet
    participant PM as PoolManager

    L->>H: executePreorderSettlement(params)
    H->>H: 校验 msg.sender == launcher (Router 层 modifier)
    H->>SF: entry shell delegatecall executeSettlementLogic(params)
    SF->>SF: Phase 1 计算固定 1% fee, 收取 input 费用
    SF->>PM: unlock(abi.encode(Settlement, SettlementCallbackData))
    PM->>H: unlockCallback(data) (Router entry)
    H->>H: 读取 raw kind，仅接受 ModifyLiquidity / Settlement
    H->>SF: selector||rawData[32:] delegatecall settlementUnlockCallback
    SF->>PM: swap(..., hookData=bytes(""))
    Note over SF,PM: caller 是 hook，真实 v4 跳过 beforeSwap 与 afterSwap
    PM-->>SF: 返回 BalanceDelta
    SF->>SF: settle + take（含 output-side protocol fee）
    SF-->>H: 返回 typed SettlementResult ABI returndata
    H-->>PM: 原样返回 facet returndata
    PM-->>SF: 返回 unlock returndata
    SF->>SF: 一次解码 SettlementResult + Phase 3 _updateAfterSwap + output fee 对账
    SF-->>H: 返回 adjustedDelta
    H-->>L: 返回 adjustedDelta
```

说明：

- 这条路径不是普通用户路径。
- 启动结算直接进入 Hook Router，由 typed discriminator 路由到 SettlementFacet；不经过 `MemeverseSwapRouter` 普通 swap 通道。
- Settlement logic 经 Router entry `delegatecall` SettlementFacet 执行。unlock payload 直接使用 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)`；Router 只对当前支持的 raw discriminator 分支，未知值回退 `InvalidUnlockCallbackKind(rawKind)`。因 `SettlementCallbackData` 当前全静态，kind 校验后用 `bytes.concat(settlementUnlockCallback.selector, rawData[32:])` 前缀转发到 facet（跳过 memory decode + 二次 encode）。typed facet returndata 由 Router 原样返回，外层 settlement logic 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。
- settlement swap 是 hook self-call，真实 v4 同时跳过 `beforeSwap` / `afterSwap`；不需要 settlement transient routing flag。回调型 token 发起的**跨池**外部重入 swap 不是 hook self-call，仍执行普通 callbacks 并走 public fee 正常收费；**同池**生命周期重入（公开 swap 路径下由 outer `beforeSwapLogic` 持有该池 per-pool transient lock，回调内再次进入同池 `beforeSwapLogic` 触发 `SwapLifecycleReentrant`）被阻断，防止 callback token 在 outer 报价固定后推进动态费 state 造成费率失真；settlement self-call 因 v4 跳过 `beforeSwap`/`afterSwap` 不进这两个函数的 acquire/release 路径，故 settlement 路径下改由 `SettlementFacet.executeSettlementLogic` 在 Phase 1 `transferFrom` 前 acquire、Phase 3 `_updateAfterSwap` 后的函数末尾 release 同一 per-pool lock，覆盖 callback token 在 transferFrom 窗口（Phase 1/2，pre-unlock）与 settle/take transfer 期间对同池发起的 reentrant swap（见 [docs/spec/invariants.md](../invariants.md) INV-04A）。
- 该路径使用固定总费（数值定义见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）；caller 约束见 [docs/spec/invariants.md](../invariants.md) INV-04。不复用普通动态费结果。
- **资金与 approve 路径**：Launcher 只需对 Hook 做一次 infinite approve。Hook 作为 `transferFrom` 的 spender，拉取 protocol fee 到 treasury，并把 netInput 与 LP fee 合并一次 `transferFrom` 拉到 hook proxy custody（同源同收款人，省一次 ERC20 transferFrom）；SettlementFacet 用 hook proxy 余额直接 `transfer` 给 PoolManager，不需要任何 approve。详见 [docs/spec/swap/swap-integration.md §5.1](swap-integration.md)。

---

## 4. Permit2 并行资金流

```mermaid
flowchart TD
    A[用户调用 swapWithPermit2 / addLiquidityWithPermit2 / removeLiquidityWithPermit2] --> B[Router 校验 Permit2 payload]
    B --> C[Permit2 将 ERC20 拉到 Router]
    C --> D[进入普通 Router 执行逻辑]
    D --> E[swap / addLiquidity / removeLiquidity]
```

说明：

- Permit2 只改变 ERC20 资金准备方式；Permit2 入口语义（V6）见 [docs/spec/swap/permit2.md](permit2.md)。
- 一旦资金到达 Router，后续业务语义与普通入口完全一致。
- native 拒绝（V5）见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3。

---

## 5. Add Liquidity 主路径

```mermaid
sequenceDiagram
    participant U as 用户
    participant R as Router
    participant H as Hook

    U->>R: addLiquidity(...)
    R->>R: 校验 deadline / minAmount / pair 为 ERC20/ERC20
    R->>R: 准备 ERC20 输入资金
    R->>R: 要求目标 pool 已预先完成初始化
    R->>H: addLiquidityCore(...)
    H->>H: 计算 full-range liquidity
    H->>H: mint LP token
    H-->>R: 返回 liquidity 与 delta
    R-->>U: 返回 liquidity
```

说明：

- `addLiquidity(...)` / `addLiquidityCore(...)` 不负责初始化 pool，调用前目标 pool 必须已经存在且已初始化。
- 初始建池路径为 `Launcher -> Router.createPoolAndAddLiquidity(...)`。
- bootstrap 由 `Launcher` 先给出 desired budgets，再由 Router 执行 `createPoolAndAddLiquidity(...)`；对外记账真源是实际执行后的 actual spend / actual liquidity。

### 5.1 Bootstrap Execution

- 集成契约：Router 从 Launcher 提交的 desired budgets 执行 `createPoolAndAddLiquidity(...)`，并把 actual spend / actual liquidity 返回给 Launcher 做后续 accounting（bootstrap 不返回 preview-equality 结果）。
- 四池 bootstrap 的记账语义、`memecoin/uAsset` 主池 PT backing ratio 口径、auxiliary underspend 处置、unused bootstrap `uAsset` / `memecoin` 处置见 [docs/spec/verse/accounting.md](../verse/accounting.md) §3.2 与 [docs/spec/invariants.md](../invariants.md) INV-04；PT backing ratio 的记录与 split 操作语义 home 在 [docs/spec/polend/pt-yt-splitter.md §1](../polend/pt-yt-splitter.md)，不变量锚点见 [docs/spec/invariants.md](../invariants.md) INV-14 / INV-19；unused bootstrap `uAsset` 进入的 settlement dust reserve 结构与处置 home 在 [docs/spec/polend/core.md §6.7](../polend/core.md)，该 reserve 与杠杆侧 PT fee 预兑付的关联见 [docs/spec/polend/settlement-and-fees.md §5](../polend/settlement-and-fees.md)。

---

## 6. Remove Liquidity 与 Claim Fee 主路径

```mermaid
flowchart TD
    A[用户调用 removeLiquidity / removeLiquidityWithPermit2] --> B[Router 校验 deadline 与最小输出]
    B --> C[Router 准备 LP token]
    C --> D[Hook.removeLiquidityCore]
    D --> E[销毁 LP 并返回底层资产]
    E --> F[Router 校验 recipient 非零并把资产发给 recipient]

    G[fee owner 调用 Hook.claimFeesCore] --> H[Hook 由 msg.sender 推导 owner]
    H --> I[Hook 结算 pending fees]
    I --> J[校验 recipient 非零后把 fee 发给 recipient]
```

说明：

- 上图中两条路径的 `recipient` 非零 fail-close 规则（V7）见 [docs/spec/invariants.md](../invariants.md) INV-07，不在本文档重述。

---

## 7. 超简版摘要

```mermaid
flowchart TD
    A[普通 swap] --> B[Router 校验]
    B --> C{存在 EWVWAP 历史且交易回归 EWVWAP?}
    C -- 是 --> C1[跳过全部动态费组件<br/>effectiveFee = max(baseFee, launchFee)]
    C -- 否 --> C2[Hook 动态费<br/>adverse per-address + vol per-pool + short per-pool<br/>取 max(dynamicFee, launchFee)]
    C1 --> D[成功则返回 delta，失败则回退]
    C2 --> D

    E[preorder settlement] --> F[Launcher 调 Hook.executePreorderSettlement]
    F --> G[Hook 校验 launcher 绑定]
    G --> H[SettlementFacet delegatecall 执行：收取 input 费用 + unlock/swap/take]
    H --> I[固定 1% 结算]
```

一句话概括：

- 普通 swap：execute-or-revert，启动期靠费率衰减保护
- 特殊启动结算：显式 `Launcher -> Hook -> SettlementFacet`（Router entry `delegatecall`），固定费率（数值见 [docs/spec/verse/accounting.md §7.4](../verse/accounting.md)）
