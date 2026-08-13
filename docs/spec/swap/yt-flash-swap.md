# YT Flash Swap 规格（POL ↔ YT 复用 PT/POL 池）

本文档是 YT Flash Swap 的 canonical spec（产品真相层）。它在产品规则层面定义：新增独立 Router 复用既有 PT/POL Uniswap v4 池，在不建立第二个 AMM 的前提下把 POL 与 YT 互换。设计记录见 `docs/superpowers/specs/`（设计稿，非产品真源）；普通 PT/POL swap 的唯一 canonical 是 [uniswap-v4.md §3.1–§3.2](uniswap-v4.md)，本文不重述其费率/容量/价格限制规则。

标签约定：`[代码已证]` = 当前代码可直接验证。本文主体已由 `src/swap/MemeverseYTFlashSwapRouter.sol`、接口、Hook `activeAccountSessionPrincipal()` getter 与单元/集成/invariant 测试落地，统一标 `[代码已证]`。

## 1. 目标与边界

Memeverse 已有 PT/POL Uniswap v4 池，但没有独立的 YT 池。YT Flash Swap 复用该 PT/POL 池的现有流动性，把 POL 与 YT 互换，而不建立第二个 AMM。

基础兑换关系（raw unit，1:1 split/merge）：

\[
1\ \mathrm{POL} \xleftrightarrow{\mathrm{split}} 1\ \mathrm{PT}+1\ \mathrm{YT}
\xleftrightarrow{\mathrm{merge}} 1\ \mathrm{POL},\qquad
P(\mathrm{PT})+P(\mathrm{YT})=P(\mathrm{POL})
\]

本期只提供两个用户入口：

- POL → 精确数量 YT（`swapPOLForExactYT`）
- 精确数量 YT → POL（`swapExactYTForPOL`）

本期明确不提供：

- YT → 精确数量 POL：其净输出函数可有多个可行解，不能伪装成确定的 exact-output。
- 任意代币 ↔ YT 多跳路由、Permit2、原生币包装、Router 预存流动性或管理权限。
- Hook 自交换、新 Hook Facet、第二套 fee/referral 状态机。
- Router 链上求根、Lens 查询或报价循环。
- SDK/前端实现，或「链下找到全局最大 YT」的承诺。

本期选 POL ↔ YT，因为 POL 是 split/merge collateral，资产语义对应 Pendle 的 SY。PT ↔ YT 也需 flash composition，但不在范围内。不能断言 POL 路径对每笔交易必然有更小 price impact、liquidity 消耗或 gross fee；离散舍入、fee 币腿和执行状态都会改变结果。

## 2. 核心架构：Router 复用 PT/POL 池

新增独立的 `MemeverseYTFlashSwapRouter`。它是 PoolManager 的正常 swap 调用者，因此底层 PT/POL 腿与普通 swap 走同一条 Uniswap v4 和 `MemeverseUniswapHookUpgradeable` 路径。

Router 只保存以下 immutable 依赖：

| 依赖 | 用途 |
| --- | --- |
| `PoolManager` | unlock、普通 PT/POL swap、take、settle |
| `MemeverseUniswapHookUpgradeable` | 推导 canonical pool，读取当前 account-session principal |
| `POLSplitterUpgradeable` | split、merge，以及从 `verseId` 解析 canonical PT/POL/YT |

`MemeverseUniswapHookLens` 不保存在 Router 中：SDK 在固定历史状态用它报价，Router 只执行真实 swap 并以真实 `BalanceDelta` 结算。

Router 不接受任意 `PoolKey` 或资产地址。每个用户入口在任何资金动作前动态验证：

```text
launcher = hook.launcher()
canonical = launcher.getLauncherContracts()
canonical.memeverseUniswapHook == address(hook)
canonical.polSplitter == address(splitter)
```

每个入口只外调一次 `getLauncherContracts()` 并复用 `canonical` 完成两项比较。外调前必须先校验 `hook.launcher()` 返回的 launcher 非零且有 deployed code（否则回滚命名错误 `LauncherCodeNotReady`，镜像构造期 `HookCodeNotReady` 的先 code-length 后外读顺序），避免对无 code 地址的 STATICCALL 返回空 returndata 触发不透明的 ABI-decode 回滚。这把 immutable Hook/Splitter 绑定到 Hook 当前 launcher 的 canonical 配置；Router 不缓存 launcher 配置或维护第二套配置。随后仅从该 canonical Splitter 读取 verse 的 PT/POL/YT，拒绝零地址、重复地址或无 deployed code 的地址，并只从 canonical PT/POL 与 Hook 推导 `PoolKey`。POL、PT、YT 必须是 canonical 的被动、精确转账 ERC20；fee-on-transfer、rebasing、转账回调等不在范围内。付款只用 allowance + transferFrom，不支持 Permit2。

构造期 PoolManager 对角不变量：Router 与 Hook 各自在构造期绑定一个 immutable `PoolManager`（经 `SafeCallback`/`ImmutableState`）。Router 在 `PoolManager.unlock` 内对自身 manager 调 `swap`，该 manager 再回调 `key.hooks = address(hook)` 的 `beforeSwap`/`afterSwap`，Hook 的 `onlyPoolManager` 把 `msg.sender` 比对自身 manager。若两者不同，每条 PT/POL swap（进而两条 YT Flash Swap 入口）都会在 Hook 侧回滚 `NotPoolManager`（若该 manager 上 pool 未初始化则先回滚 `PoolNotInitialized`），且 manager 为 immutable、错误不可恢复。因此构造成功前，在零地址检查之后、读取 `hook_.poolManager()` 并进行 manager 对角比较之前，必须按 `manager_`、`hook_`、`splitter_` 顺序确认这三个 immutable executable dependency 均有 deployed code；分别无 code 时回滚命名错误 `PoolManagerCodeNotReady`、`HookCodeNotReady`、`SplitterCodeNotReady`。`SafeCallback(manager_)` 在构造器 body 前已绑定 manager immutable，不能将上述 body 内检查表述为发生在该绑定之前；正确时序是部署成功前完成零地址与 code-ready 检查，再读取 getter 并进行对角比较。对角失配回滚命名错误 `RouterPoolManagerMismatch`。这与代码库对 facet（`_requireFacetPoolManager`→`FacetPoolManagerMismatch`）、UUPS upgrade（`UpgradePoolManagerMismatch`）、sibling lens（`HookLensPoolManagerMismatch`）的同对角处理一致。

POLSplitterUpgradeable 是生命周期和 PT-backing 的唯一真源。`Stage.Locked` 是 YT Flash Swap 的正常成功阶段；`Stage.Unlocked` 或 Splitter 已 settled 时，既有 split/merge 必须失败并使整笔 flash 原子回滚。Router 不缓存阶段或维护第二套生命周期判断。Splitter split/merge 与生命周期规则以 [polend/pt-yt-splitter.md](../polend/pt-yt-splitter.md) 为准。

## 3. 公开接口

用户可调用的状态变更接口只有两个。`unlockCallback` 是 PoolManager 的技术回调，不是用户入口。

```solidity
swapPOLForExactYT(verseId, exactYTOut, maxPOLIn, sqrtPriceLimitX96, recipient, deadline, referrer)
    returns (polInUsed)
swapExactYTForPOL(verseId, exactYTIn, minPOLOut, sqrtPriceLimitX96, recipient, deadline, referrer)
    returns (polOut)
```

金额和 `verseId` 的 Solidity 类型沿用项目现有的 canonical 类型；参数顺序和语义固定如下。

| 接口 | 用户给定的硬约束 | 成功时的确定结果 |
| --- | --- | --- |
| `swapPOLForExactYT` | 恰好获得 `exactYTOut`，最多支付 `maxPOLIn` | YTOut 等于 `exactYTOut`，返回实际拉取的 `polInUsed` |
| `swapExactYTForPOL` | 恰好卖出 `exactYTIn`，至少收到 `minPOLOut` | YTIn 等于 `exactYTIn`，返回实际发送的 `polOut` |

用户若只有 POL 预算 \(B\)，SDK 先选 YT 候选，再调用 `swapPOLForExactYT`；价格改善时不把未用预算自动换成更多 YT。这是刻意语义。若要「执行区块花尽 \(B\) 并尽量多得 YT」，须另行设计 exact-budget 产品，不以重复入口实现。

## 4. 数学模型

### 4.1 固定状态下的底层报价

固定完整链上状态 \(s\)，令 \(y\) 为目标 YT 数量，也即需要 split 或 merge 的整数 POL/PT 单位。

定义：

\[
R_s(y) = \text{在状态 }s\text{ 中，普通 exact-input }y\ \mathrm{PT}\rightarrow\mathrm{POL}\text{ 的最终净 POL 输出}
\]

该值已经包含同普通 PT/POL swap 一致的动态费、launch fee、protocol fee 币腿、referral、容量和价格限制。

买入一单位批量 \(y\) YT 的实际 POL 成本为：

\[
C_s(y) = y - R_s(y)
\]

买入只有：

\[
0 < R_s(y) < y
\]

时，\(C_s(y)\) 才是本期所支持的正 POL 成本。

卖出一单位批量 \(y\) YT 时，定义：

\[
Q_s(y) = \text{在状态 }s\text{ 中，普通 exact-output }\mathrm{POL}\rightarrow y\ \mathrm{PT}\text{ 的最终净 POL 输入}
\]

该值包含同普通 PT/POL swap 一致的动态费、launch fee、protocol fee 币腿、referral、容量和价格限制。卖出的净 POL 输出为：

\[
O_s(y) = y - Q_s(y)
\]

只有 \(0 < Q_s(y) < y\) 时，\(O_s(y)\) 才是本期支持的正 POL 输出。

### 4.2 full-range 的含义与不含义

Hook 流动性是 full-range，只说明给定候选 \(y\) 的报价不跨 initialized tick；不代表价格线性，也不证明 \(C_s(y)\) 全域单调、预算可行集合是连续前缀、预算下根唯一或普通二分能找到全局最大可行 \(y\)。

整数舍入和 fee 已足以破坏这些推论。反例：固定 1% fee、虚拟储备为 4 PT / 9 POL 时：

\[
C(2)=1,\quad C(3)=0,\quad C(4)=1
\]

若本期拒绝零成本，候选可行性可以呈现「可行 → 不可行 → 可行」。在没有额外交易域证明前，SDK 不得把普通二分结果称为全局最大 YT，也不得把它当作 Router 的安全前提。

### 4.3 PoolManager delta 的正确含义

买入底层腿是 PT → POL exact-input。完成后，Router 对 PoolManager 的真实 delta 必须是：

\[
\Delta_{PT}=-y,\qquad \Delta_{POL}=+R_{actual}
\]

负 PT delta 是 Router 欠 PoolManager 的 PT；正 POL delta 是 PoolManager 欠 Router 的 POL。`take(POL)` 只领取并清除正的 POL delta，不会凭空制造 PT 债务。PT 债务来自这一次普通 swap 的输入义务。

卖出底层腿是 POL → PT exact-output。完成后，Router 的真实 delta 必须是：

\[
\Delta_{PT}=+y,\qquad \Delta_{POL}=-Q_{actual}
\]

正 PT delta 是 Router 可领取的 PT；负 POL delta 是 Router 欠 PoolManager 的 POL。两条路径的债务币种均由普通 swap 的输入币种决定，不由 take 反转。

## 5. 链下报价与报价失效

### 5.1 固定区块报价

SDK 用现有 `MemeverseUniswapHookLens` 和 EIP-1898 `blockHash` 固定报价状态。每个最终候选 \(y\) 都必须直接验证：trader 是预期执行 principal、方向是 PT → POL、`sqrtPriceLimitX96` 一致、快照中可完整执行而非 capacity/limit partial fill、\(0<R_{quote}(y)<y\)，且 \(C_{quote}(y)=y-R_{quote}(y)\) 符合用户预算规则。

满足这些条件的结果只能称为「该区块下已验证可执行候选」。它不是全局最优性的证明。

**Router 不接收 quote、\(R\)、离线猜测值或搜索边界，也不要求真实结算等于历史报价。** 历史报价只帮助用户选择参数；真实交易只由执行时状态和用户保护参数决定。

### 5.2 用户指定目标 YT

若用户指定目标 \(y\)，SDK 在固定快照求得 \(quotedCost=C_{quote}(y)\)，用户根据自己的滑点容忍度设定 \(maxPOLIn \ge quotedCost\)。Router 只在执行时 \(actualPOLIn \le maxPOLIn\) 时成交。

### 5.3 用户指定硬 POL 预算

用户给定预算 \(B\) 时，SDK 必须保留执行 headroom \(H>0\)，选择已直接验证且满足下式的候选 \(y\)：

\[
C_{quote}(y) \le B-H
\]

再调用 `swapPOLForExactYT(..., exactYTOut: y, maxPOLIn: B, ...)`。\(H\) 是报价到执行的成本缓冲，不是 YT 搜索宽度；成功时只拉真实成本，未用 POL 留在用户钱包。

### 5.4 固定快照卖出报价

卖出固定数量 \(y\) YT 时，SDK 在固定 snapshot 直接验证：trader 是预期执行 principal、方向是 `POL -> PT` exact-output \(y\)、`sqrtPriceLimitX96` 一致、快照中可完整执行而非 capacity/limit partial fill，且 \(0 < Q_{quote}(y) < y\)。

\[
quotedPOLOut=O_{quote}(y)=y-Q_{quote}(y)
\]

用户按向下滑点容忍度设置 \(minPOLOut \le quotedPOLOut\)。Router 不接收 quote；执行时仍用 \(Q_{actual}\) 重算输出。

### 5.5 stale 与 MEV

固定 `blockHash` 只保证那个历史快照上的报价精确，不保证未来交易状态相同，也不防止 MEV。

对已选 \(y\)：

- 执行状态改善：`actualPOLIn` 变小，Router 少拉 POL。
- 执行状态恶化但仍在 `maxPOLIn` 内：成交。
- 实际成本超过 `maxPOLIn`：原子回滚。
- 执行时 capacity 不足、触碰价格限制或出现 partial fill：原子回滚。

卖出以执行时 `Q_actual` 重算 `polOut=y-Q_actual`：`Q_actual` 下降时支付更多 POL；`Q_actual` 上升但 `polOut >= minPOLOut` 时仍可成交；`polOut < minPOLOut` 必须在 take、pull、merge 前原子回滚。卖出的 capacity、价格限制或 partial fill 同样原子回滚。

SDK 应使用短 deadline、合理的 `sqrtPriceLimitX96`，高价值订单可使用 private orderflow。报价和执行必须使用同一个 account-session principal。

## 6. account session 与 principal 绑定

现有 Hook 不验证 payer 等于 activePrincipal；没有 Router 绑定时，Lens 可按一个地址报价而执行按另一个地址的动态费状态结算。Hook core 及其 interface 因此增加只读 getter：

```solidity
activeAccountSessionPrincipal() returns (address)
```

它只读当前 transaction 的 transient principal，不新增 Facet 或改变 `beginAccountSession`/`endAccountSession` 生命周期。每个 Router 用户入口在任何资金动作前必须验证：

```text
Hook.activeAccountSessionPrincipal() == msg.sender
```

同一资金动作前，用户入口还必须动态验证 §2 的 canonical dependency（Hook/Splitter 配置与 Router immutable 相同）。

因此 payer 固定为 `msg.sender`，没有独立 payer 参数，SDK Lens trader 也必须是同一地址；Router 看不到也不能验证历史 Lens 参数。Router 不自行开始或结束 session。无代码 EOA 不能直接建立当前 session，调用仍须由现有 smart-account、Safe 或 EIP-7702 原子 frame 完成：

```text
beginAccountSession -> Router 用户入口 -> endAccountSession
```

若上述三步的 principal 不一致（回滚 Router 自身接口的 `AccountSessionPrincipalMismatch`，它与 Hook 既有的 afterSwap 专用同名 error 是不同合约、不同语义，详见 §11），或当前 launcher 的 Hook/Splitter 配置不匹配 Router immutable（`CanonicalDependencyMismatch`），Router 在转账、take、settle、split 或 merge 前回滚。

## 7. 共用入口前置条件与不变量

两个用户入口都必须：

1. 检查 `deadline` 未过期。
2. 检查 exact amount 大于零；`exactYTOut` 与 `exactYTIn` 在任何 v4 signed-delta 转换或相关算术前必须满足 \(0 < amount \le type(int128).max\)。`maxPOLIn` 与 `minPOLOut` 保持完整 `uint256` 比较语义，不设 `int128` 上限。
3. 检查 `recipient` 不是零地址且不是 Router。
4. 动态验证当前 launcher 的 Hook/Splitter 配置与 Router immutable 相同；仅从 canonical Splitter 读取 PT/POL/YT，拒绝零、重复或无 deployed code 的地址，并仅从该 canonical PT/POL 与 Hook 推导 `PoolKey`。
5. 在任何资产动作前验证 active principal 与 `msg.sender` 相同。
6. 用户入口在本地保存 Router 的 PT、YT、POL `RouterBalances` baseline；它不进入 `FlashContext` 或 context hash。
7. 通过 `PoolManager.unlock` 执行单次 flash 结算。unlock 前以 transient storage 写入无动态 `hookData` 的 context hash；context 仅含 action、payer、recipient、verse/tokens、amount/limit/price limit、referrer 等执行字段，不含 `RouterBalances`。callback 只接受 PoolManager，验证原始 data hash 后立即清零，再 decode 或外调。
8. 用户入口具有重入保护；外部 callback、token 操作和 Splitter 操作都不能重入另一笔用户交易。
9. unlock 返回后，先确认 hash 已清零并 decode callback 结果，再检查 PT、YT、POL 三个余额都精确恢复到本地保存的 baseline。

Router 不把 baseline 中的余额视为可用流动性。正常部署后 baseline 应为零；即使意外存在 dust，任何交易也不得消费它。`recipient` 为 Router 被禁止，避免输出资产混入 baseline。

真实 `BalanceDelta` 是唯一结算依据。Router 不信任历史 quote，也不使用预存 PT/POL/YT 补差。

## 8. POL → 精确 YT：一次普通 swap 的资金流

设 \(y=exactYTOut\)。callback 在 `PoolManager.unlock` 中只执行以下资金步骤，并返回 `abi.encode(actualPOLIn)`。

1. 执行一次普通 exact-input：

   ```text
   y PT -> R_actual POL
   ```

   PoolManager 和 Hook 照常执行。真实 delta 必须恰好为：

   ```text
   PT = -y
   POL = +R_actual
   ```

   若 PT 输入未完全成交、出现额外币种 delta，或输出结构不符，抛出 `FlashDeltaMismatch`。该错误只表示真实 delta 不符合固定 \(y\) 的结构，绝不表示「真实结果偏离历史报价」。

2. 在 take 与 split 前验证：

   ```text
   0 < R_actual < y
   actualPOLIn = y - R_actual
   actualPOLIn <= maxPOLIn
   ```

   `R_actual` 等于 \(y\) 是零成本；`R_actual` 大于 \(y\) 是负成本。这两种情况本期都 fail closed，不能让 unsigned subtraction 下溢，也不能暗中把接口变成「同时给用户 YT 和额外 POL」的双输出交易。

3. `take` 恰好 `R_actual` POL，清除正 POL delta。

4. 仅从 payer（即 `msg.sender`）`transferFrom` 恰好 `actualPOLIn` POL 到 Router。此时 Router 的本次 POL 增量恰好为：

   ```text
   R_actual + actualPOLIn = y
   ```

   不预拉 `maxPOLIn`，没有退款分支。

5. Router 仅一次向 Splitter 批准恰好 \(y\) POL。调用 `split(verseId, y)`（split/merge 第一参数恒为本入口的 verseId，签名见 `src/polend/POLSplitterUpgradeable.sol::split` / `::merge`）后立即检查 Router 到 Splitter 的 POL allowance 为零；split 必须恰好消耗 \(y\)，非标准残余 allowance 一律 fail closed。成功路径不调用 `approve(0)`。split 后得到恰好 \(y\) PT + \(y\) YT。

6. 用得到的恰好 \(y\) PT 向 PoolManager `settle`，清除 \(-y\) PT delta。

7. 将恰好 \(y\) YT 转给 recipient，并返回：

   ```text
   abi.encode(actualPOLIn)
   ```

公共入口在 `_runFlashSwap` / `PoolManager.unlock` 返回、pending context hash 已消费且 callback result 已 decode 后，按 §7 使用本地保存的 PT、YT、POL baseline 检查余额。全部 postcondition 通过后，公共入口才 emit 并返回 `polInUsed`。

callback 资金步骤或 unlock 后公共入口 postcondition 任一步失败，整个 unlock 和所有 token 转账原子回滚。用户不会因失败交易被保留预拉资产。

## 9. 精确 YT → POL：一次普通 swap 的 flash merge 资金流

设 \(y=exactYTIn\)。callback 在 `PoolManager.unlock` 中只执行以下资金步骤，并返回 `abi.encode(polOut)`。

1. 执行一次普通 exact-output：

   ```text
   Q_actual POL -> y PT
   ```

   真实 delta 必须恰好为：

   ```text
   PT = +y
   POL = -Q_actual
   ```

   若没有取得精确 \(y\) PT、发生 partial fill 或 delta 结构异常，抛出 `FlashDeltaMismatch`。

2. 在领取 PT 前验证：

   ```text
   0 < Q_actual < y
   ```

   这确保 merge 后存在正的 POL 净输出，也避免零债务、负输出或算术下溢的未定义语义。

3. 计算 \(polOut=y-Q_{actual}\)，验证：

   ```text
   polOut >= minPOLOut
   ```

4. `take` 恰好 \(y\) PT，清除正 PT delta。

5. 从 payer `transferFrom` 恰好 \(y\) YT。`POLSplitterUpgradeable.merge` 直接 burn Router 持有的 PT/YT，不走 ERC20 approval 或 transferFrom；调用 `merge(verseId, y)`（split/merge 第一参数恒为本入口的 verseId，签名见 `src/polend/POLSplitterUpgradeable.sol::split` / `::merge`）得到恰好 \(y\) POL。

6. 用其中恰好 `Q_actual` POL 向 PoolManager `settle`，清除 \(-Q_actual\) POL delta。

7. 把恰好 `polOut` POL 转给 recipient，并返回 `abi.encode(polOut)`。

公共入口在 `_runFlashSwap` / `PoolManager.unlock` 返回、pending context hash 已消费且 callback result 已 decode 后，按 §7 使用本地保存的 PT、YT、POL baseline 检查余额。全部 postcondition 通过后，公共入口才 emit 并返回 `polOut`。

这条路径同样不使用 Router 自有 PT/POL/YT，也不产生第二次 swap。

### 9.1 数值单位、记账与取整

canonical POL、PT、YT 均为 18-decimal ERC20，所有数值均使用 raw unit。`y`、`R_actual`、`Q_actual`、`actualPOLIn` 和 `polOut` 都是同一标度的 raw-unit 整数；split/merge 在 raw unit 上 1:1，Router 不做 decimal rescaling。

`R_actual` 与 `Q_actual` 是 Uniswap core/Hook 完成 fee 和 rounding 后的最终普通 swap `BalanceDelta` 数额。普通 swap 语义以 [uniswap-v4.md](uniswap-v4.md) 为准；Router 不重复收费、不对这些值再次取整，且不引入任何额外 rounding 操作。

## 10. fee、referral 与状态更新

每笔 YT Flash Swap 只执行一次真实的普通 PT/POL swap。因此它天然复用普通 swap 的完整规则：

- dynamic fee 与 launch fee；
- 65% LP / 35% protocol fee 分配；
- protocol fee 的币种腿；
- referral；
- capacity；
- `sqrtPriceLimitX96`；
- account session、lifecycle lock 与 Hook 的现有校验；
- 动态状态恰好更新一次。

两条入口的 referrer 编码只有一种：

```text
referrer == address(0): hookData = bytes("")
referrer != address(0): hookData = abi.encodePacked(referrer)
```

非零 referrer 的 packed `hookData` 必须只传给唯一的真实 PT/POL swap。不得使用 `abi.encode(referrer)`，也不得在 split 或 merge 阶段创建第二份 referral 数据。

Router 不复制 fee 数学，不在 Splitter 前后收取额外交易费，也不进行第二次「修正 swap」。这避免双重收费、双重动态状态更新和两个价格腿之间的额外价格风险。普通 swap 的 fee/referral 完整规则以 [uniswap-v4.md §3.1–§3.2](uniswap-v4.md) 与 [swap-integration.md §2](swap-integration.md) 为准。

## 11. 错误、事件与回调要求

错误集合应表达以下失败原因（名称遵循项目现有命名风格）：

| 失败类别 | Error 名 | 语义 |
| --- | --- | --- |
| 构造器零地址 | `ZeroAddress` | 构造器 `manager_`/`hook_`/`splitter_` 为零地址（**新增行**） |
| 构造器 PoolManager 无 code | `PoolManagerCodeNotReady` | 构造器 `manager_` 非零但无 deployed code；在读取 Hook getter 与 manager 对角比较前拒绝（**新增行**） |
| 构造器 hook 无 code | `HookCodeNotReady` | 构造器 `hook_` 非零但无 deployed code；在读取 `hook_.poolManager()` 前拒绝，避免 STATICCALL 返回空 returndata 触发 opaque ABI-decode 回滚；命名镜像代码库 `FacetCodeNotReady`/`UpgradeTargetCodeNotReady`/`HookLensCodeNotReady`（**新增行**） |
| 构造器 splitter 无 code | `SplitterCodeNotReady` | 构造器 `splitter_` 非零但无 deployed code；在读取 Hook getter 与 manager 对角比较前拒绝（**新增行**） |
| 构造器 PoolManager 对角失配 | `RouterPoolManagerMismatch` | 零地址检查和三个 executable dependency 的 code-ready 检查通过后，读取 Hook 的 immutable `poolManager` 与构造器 `manager_` 对角比较；两者不同则在部署成功前回滚。镜像代码库对 facet/upgrade/lens 的同类对角校验，使任何绑定错误 manager 的部署在构造期即回滚，而非运行时以 `NotPoolManager`/`PoolNotInitialized` 永久 brick 两条入口（**新增行**） |
| 无效 exact YT amount 或 int128 边界 | `AmountOutOfRange` | `exactYTOut` 或 `exactYTIn` 为零，或超过 v4/signed-delta 安全范围；`maxPOLIn` 与 `minPOLOut` 以完整 `uint256` 比较，不设 `int128` 上限 |
| 无效 recipient / deadline | `InvalidRecipient` / `ExpiredPastDeadline` | recipient 为零或 Router，交易期限过期 |
| account-session principal 不匹配 | `AccountSessionPrincipalMismatch` | 无活动 session，或 active principal 不等于 `msg.sender`；Router 在自身接口 `src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol` 定义**自己的** `AccountSessionPrincipalMismatch(address active, address caller)`，作用域仅限 Router 入口校验，与 Hook 既有的 afterSwap 专用同名 error `(address contextPrincipal, address activePrincipal)` 是不同合约、不同语义，不互相复用。两种情形都由同一校验 `hook.activeAccountSessionPrincipal() != msg.sender` 捕获（`address(0) != msg.sender`），按本期设计归入同一错误类别 |
| canonical dependency 不匹配 | `CanonicalDependencyMismatch` | Hook 当前 launcher 的 `memeverseUniswapHook` 或 `polSplitter` 不等于 Router immutable |
| 运行时 launcher 无 code | `LauncherCodeNotReady` | `hook.launcher()` 返回零地址或无 deployed code 的地址；在 `getLauncherContracts()` 外调前先拒绝，避免 STATICCALL 命中非合约返回空 returndata 触发 opaque ABI-decode 回滚；命名镜像构造期 `HookCodeNotReady` 与 `InvalidCanonicalVerseAssets` 的 code-length-first 模式（**新增行**） |
| canonical verse 资产零、重复或无 deployed code | `InvalidCanonicalVerseAssets` | canonical Splitter 对 `verseId` 返回零、重复、或无 deployed code 的 PT/YT/POL 地址；在 `_snapshotBalances` 读取 `balanceOf` 前先拒绝，避免 STATICCALL 命中非合约返回空 returndata 触发 opaque ABI-decode 回滚；与构造器 `HookCodeNotReady` 的 code-length-first 风格一致（**新增行**） |
| 非法 callback / unlock context | `UnexpectedOrTamperedCallback` / `CallbackNotConsumed` | 无 pending one-shot context，或 callback payload hash 与 `_runFlashSwap` 提交的 context 不匹配（被篡改/重放/伪造）；`UnexpectedOrTamperedCallback` 在 `_unlockCallback` 顶部触发；`PoolManager.unlock` 返回后 pending hash 未被清零则触发 `CallbackNotConsumed`（"调用者必须是 PoolManager"由基类 `SafeCallback` 的独立守卫负责，不归入此行） |
| 真实 delta 结构不符 | `FlashDeltaMismatch` | 真实 delta 不符合固定 \(y\) 所要求的币种、符号或完整成交结构；不比较任何历史 quote |
| 非法买入成本 | `InvalidBuyCost` | `R_actual` 为零、等于或大于 \(y\)（`R_actual == 0 || R_actual >= y`），三种情形都 fail closed，保证 unsigned 减法 `y - R_actual` 不下溢（与 §8 item 2 `0 < R_actual < y` 一致） |
| 超过 `maxPOLIn` | `MaxPOLInExceeded` | `actualPOLIn` 大于 `maxPOLIn` |
| 非法卖出债务 | `InvalidSellDebt` | `Q_actual` 为零或大于等于 \(y\) |
| 未满足 `minPOLOut` | `MinPOLOutNotMet` | `polOut` 小于 `minPOLOut` |
| Router 余额未恢复 | `RouterBalanceMismatch` | 成功路径试图消费 dust（PT/YT/POL 任一余额未回到 baseline） |
| 买入 Splitter POL allowance 残留 | `SplitterAllowanceResidual` | 成功路径留下买入所需的临时 POL 授权 |
| ERC20 approve 返回 false | `ApprovalFailed` | 向 Splitter 批准 POL 时 ERC20 `approve` 返回 false（**新增行**） |
| split 铸造数量不符 | `SplitResultMismatch` | Splitter split 未精确铸造请求的 PT 与 YT；对当前 Router 绑定的 canonical `POLSplitterUpgradeable`（`split` 严格 1:1、`_validateAndResolve` 锁定 canonical、`splitter` immutable）不可达，属 defense-in-depth / 升级安全覆盖（仅覆盖 UUPS 升级后偏离 1:1 或非 canonical/畸形 Splitter），非真实 Splitter 运行时记账安全证明（**新增行**） |
| merge 返回 POL 不符 | `MergeResultMismatch` | Splitter merge 未精确返回请求的 POL；对当前 Router 绑定的 canonical `POLSplitterUpgradeable`（`merge` 严格按量返回、`_validateAndResolve` 锁定 canonical、`splitter` immutable）不可达，属 defense-in-depth / 升级安全覆盖（仅覆盖 UUPS 升级后偏离或非 canonical/畸形 Splitter），非真实 Splitter 运行时记账安全证明（**新增行**） |

不保留任何与离线搜索参数、搜索轮数、搜索区间或历史报价相等性有关的错误。

成功事件至少记录：

```text
YTFlashSwapPOLForYT(
    verseId, payer, recipient, exactYTOut, polInUsed, referrer
)

YTFlashSwapYTForPOL(
    verseId, payer, recipient, exactYTIn, polOut, referrer
)
```

事件只在所有 delta、余额和临时 allowance 均已结清后发出。`payer` 恒为 `msg.sender`。事件语义详见 [events.md §2.4](../events.md)。

## 12. 文件边界

### 12.1 需新增或修改的文件

| 路径 | 职责 |
| --- | --- |
| `src/swap/MemeverseYTFlashSwapRouter.sol` | 两个用户入口、PoolManager unlock callback、真实 delta 结算、baseline/allowance/reentrancy 保护 |
| `src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol` | 两个公开接口、事件、错误和返回值 |
| 现有 `src/swap/MemeverseUniswapHookUpgradeable.sol` | 增加只读 transient-principal getter，不改 session 生命周期 |
| 现有 `src/swap/interfaces/IMemeverseUniswapHook.sol` | 声明 `activeAccountSessionPrincipal()` |
| Router、Hook session、invariant 与 mock 测试文件 | 覆盖本稿验收条件 |

### 12.2 保持不变的既有依赖

| 路径或组件 | 边界 |
| --- | --- |
| 现有 `src/swap/MemeverseUniswapHookLens.sol` | 仅供 SDK 做固定 `blockHash` 报价；不是 Router immutable，不是 planned edit |
| 现有 `POLSplitterUpgradeable` | 保持 split/merge 和生命周期/PT-backing 的唯一真源；Router 只调用其既有检查 |

不新增 approximation math 库及其测试，不新增 Hook Facet，不新增 Permit2 Router，也不把报价逻辑嵌入 Router。

## 13. 测试验收

实现前必须用单元、集成、invariant 和 gas benchmark 覆盖以下行为：

1. 两条用户路径在正常 PT/POL 池状态下都完成一次且仅一次普通 swap。
2. Router 链上测试：无 session 或 active principal 不等于 `msg.sender` 时，必须在任何资金动作前回滚。
3. Solidity contract-level Lens/Router integration：正确 fixture 中 Lens trader 等于建立 session 的执行 account；错误 Lens trader 只进入 Lens quote，不进入 Router，Router 不读取或识别历史 Lens trader。
4. Solidity contract-level 同一 snapshot、未改变状态下，Lens quote 与实际 settlement 一致；Router 不接收 quote，也不以该相等性作为链上条件。真实 EIP-1898 `blockHash` RPC transport 属于后续 SDK 范围，不是本 Solidity plan 的测试承诺。
5. 报价后状态改善时，买入只拉取更少的实际 POL；卖出状态改善时多付 POL。状态恶化时，买入在 `maxPOLIn`、capacity 或 price limit 处成功或完整回滚；卖出若 `polOut < minPOLOut`，必须在 take、pull、merge 前回滚。
6. 买入的 `R_actual` 等于 \(y\) 与 `R_actual` 大于 \(y\) 都 fail closed；卖出的 `Q_actual` 为零与 `Q_actual` 大于等于 \(y\) 都回滚。
7. 所有 v4/int128 边界、零 exact amount、零或 Router recipient、过期 deadline 都被覆盖。
8. 买入只拉取 `actualPOLIn`，绝不先拉取完整 `maxPOLIn`。
9. 买入的 Splitter POL 临时 allowance 恰好为本次数量，成功后为零。
10. 预存 dust 不能被消费；PT/POL/YT 成功后精确回到各自 baseline。
11. dynamic/launch fee、65/35 分配、protocol fee 币腿、referral 和动态状态更新均与对应普通 swap 相同且只发生一次；非零 referrer 使用 `abi.encodePacked(referrer)`，`abi.encode(referrer)` 为反例，并与普通 swap 的 rebate/事件等价。
12. capacity、`sqrtPriceLimitX96`、partial fill、恶意 callback、token/Splitter 重入和任一中途失败都保持原子性。
13. gas benchmark 确认成功路径只有一次 PT/POL swap、一次 split 或 merge，且不含 Router 内的报价循环。

测试中的 mock token 只用于证明拒绝或原子回滚；生产路径只接受 canonical 被动精确转账资产。结算不变量见 [invariants.md INV-24](../invariants.md)，访问控制边界见 [access-control.md §3](../access-control.md)，事件面见 [events.md §2.4](../events.md)，审阅边界见 [SECURITY_AND_APPROVALS.md §4.6](../../SECURITY_AND_APPROVALS.md)。
