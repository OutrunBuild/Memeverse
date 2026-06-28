# POLend Core

## 1. 文档定位

`polend/` 目录是 `POLend` 与 MemeverseV2 集成后的唯一产品真源（导航见 [polend/README.md](README.md)）。本文件承载整体定义：模块边界、POLend 状态、债务推导、错误语义、互斥关系；具体流程由同目录 genesis.md / pt-yt-splitter.md / settlement-and-fees.md 分担。

POLend 定义产品语义、资金流、状态边界、结算规则和接口职责。实现、测试、计划与开发辅助文档都必须服从 POLend 规格。

本文档不描述“当前代码已实现”的状态。

## 2. 核心目标

`POLend` 的核心目标是给 `Memeverse` 创世增加杠杆创世能力。

杠杆创世不是通用借贷。用户在 `Genesis` 阶段支付利息，协议在成功进入 `Locked` 时按该 verse 固定利率 mint 对应 `uAsset` 参与创世。若创世失败进入 `Refund`，杠杆用户只取回自己支付的利息，不发生 `uAsset` mint。

每个 verse 独立绑定自己的 `uAsset`。该 verse 的利息收取、杠杆 mint、退款、fee、PT 兑付、YT 兑付、全局结算都只能使用该 verse 绑定的 `uAsset`。

## 3. 核心术语

| 术语 | 含义 |
|---|---|
| `uAsset` | 统一记账资产，也是利息、mint、债务偿还和 PT 兑付的计价资产 |
| `memecoin` | verse 的项目代币 |
| `POL` | Proof of Liquidity，创世流动性证明 |
| `PT` | Principal Token，本金凭证，按 verse 固定 backing ratio 兑付 `uAsset` |
| `YT` | Yield Token，收益凭证 |

关键关系：

- raw-unit identity：`POL raw = main pool LP raw`，`PT raw = POL raw`，`YT raw = POL raw`
- `1 raw PT` 不等于 `1 raw uAsset`。每个 verse 在 `Locked` / 四池初始化时由 `Launcher` 一次性记录固定 PT backing ratio：
  - `mainUAssetFunds` 是主池 bootstrap budget，不是 PT backing truth
  - `ptBackingNumerator = actualMainUAssetUsed`
  - `ptBackingDenominator = main pool LP / POL raw amount actually minted at launch`
  - `uAssetBacking = FullMath.mulDiv(ptAmount, actualMainUAssetUsed, mainPoolPOLAmount)`
- `YT` 代表 `Splitter` 结算池内对应 `POL collateral` 的收益权益：兑付时按比例获得 `settlementUAsset` 中扣除 PT 准备金后的剩余 `uAsset` 以及全部 `settlementMemecoin`，不覆盖 `POLend` 残值，也不天然代表全部创世剩余资产
- `POL` 被 split 后成为 `Splitter` 托管的 `POL collateral`
- `Unlocked` 后，`POL collateral` 统一结算成 `settlementUAsset + settlementMemecoin`

## 4. 模块边界

`POLend` 与 `POLSplitter` 是四池模式的必配模块。

`Launcher` 不支持 `polend=0`、`polSplitter=0` 或任何未接入 `POLend / POLSplitter` 的降级模式。

### 4.1 Launcher

`Launcher` 负责：

- verse 生命周期编排
- 普通创世资金托管与退款
- preorder 资金托管、首笔交易与 vesting
- 四池部署
- 普通初始 `YT` 托管与发放
- 普通辅助池 LP 领取
- 普通辅助池 fee 记账与领取
- 辅助池 fee 捕获与 DAO governor 分发编排
- `Locked -> Unlocked` 编排以 [settlement-and-fees.md §4](settlement-and-fees.md) 为唯一权威顺序
- 本链与异链 `YieldDispatcher / OFT` 分发路径

### 4.2 POLend

`POLend` 负责：

- 杠杆创世 market 注册
- 固定 market 利率
- 杠杆利息托管（包括真付 `uAsset` 利息与 GenesisCredit 抵扣的 credit 利息）
- 成功时 mint 杠杆 `uAsset`
- 成功时把真付部分（realInterest = `totalLeveragedInterest - totalCreditInterest`）的杠杆利息全额清扫至 `protocolTreasury`；credit 部分无 token 流入，跳过 treasury 清扫
- 成功时 burn 托管的该 verse 对应 GenesisCredit（量 = 该 verse `totalCreditInterest`）
- 杠杆退款（real 用户退 `uAsset`、credit 用户退 GenesisCredit，两套账本隔离）
- 杠杆初始 `YT` 托管与发放（real 与 credit 参与合计切分）
- 杠杆残值记账与领取
- settlement dust reserve 预留与手动注入
- 按 `uAsset` 维度记录系统债务
- 杠杆侧全局结算与债务偿还
- settle 前杠杆侧 PT fee 预兑付
- settle 时预兑付 PT fee backing 的 repay
- 维护 `GenesisCreditFactory` 地址指针（用于按 `uAsset` 查 GenesisCredit 地址）

`POLend.protocolTreasury` 接收全部真付部分杠杆利息（realInterest = `totalLeveragedInterest - totalCreditInterest`）、Launcher over-capacity funding excess 以及其他明确归 treasury 的杠杆利息收入。该产品术语映射到当前实现 getter/storage `treasury()` / `treasury`，不要求 ABI 重命名。它不是 Memeverse DAO governor，不是 `yieldVault`，也不接收主池 fee 或辅助池 fee。

`POLend` 维护按 `uAsset` 维度复用的全局 settlement dust reserve。该 reserve 只用于 `executeGlobalSettlement` 中补足有上限的整数舍入缺口，不是坏账兜底池，不参与用户残值分配；成功 settlement 后只扣减实际消耗量，未消耗余额继续留在全局池中。

### 4.3 POLSplitter

`POLSplitter` 负责：

- per-verse 初始化 `PT / YT`
- `split / merge`
- `settle`
- `preRedeemPTFee` 的 PT burn 与 `preRedeemedPT` 记录
- `redeemPT / redeemYT`

`POLSplitter` 不负责普通创世、杠杆退款、杠杆残值、preorder 或跨链发送。

## 5. 市场注册与利率

`POLend` 有全局默认利率：

```text
defaultInterestRate
```

约束：

```text
0 < defaultInterestRate <= 1e18
```

`defaultInterestRate` 是一次性创世利息比例，不是年化利率。

`setDefaultInterestRate(newRate)` 只影响未来新注册 verse，不影响任何已注册 market。setter 必须用当前 `leveragedDebtFactor` 与 `newRate` 校验默认配置仍满足杠杆约束，保证后续注册可用。

`Launcher.registerMemeverse` 必须在同一交易内调用：

```text
POLend.registerLendMarket(verseId)
```

`registerLendMarket` 只能由 `Launcher` 调用，每个 `verseId` 只能调用一次。

已注册判断使用 `market.uAsset != address(0)`。注册时从 `Launcher` 读取的 verse `uAsset` 必须非零；若为零，`registerLendMarket` revert `ZeroInput`，不创建 market。

`registerLendMarket` 还必须要求该 `uAsset` 已完成全局 reserve 配置：

```text
settlementDustStates[uAsset].maxReserve > 0
```

未配置 reserve 的 launch-supported `uAsset` 不是有效运行态，必须在 market 注册阶段直接拒绝，而不是延后到杠杆创世或 settlement 流程。

注册时：

- 从 `Launcher` 读取该 verse 的 `uAsset`
- 复制当前 `defaultInterestRate` 到 `market.interestRate`
- 设置 `market.state = None`
- 不初始化 `PT / YT`
- 不记录 `POL`
- 不记录 `PT`
- 不存储 `totalLeveragedDebt`

`market.interestRate` 注册后固定不变。

## 6. POLend 状态

### 6.1 Market

`getLendMarket(verseId)` 返回的 market 字段为：

```solidity
struct LendMarket {
    address uAsset;
    address yt;
    uint256 interestRate;
    uint256 totalLeveragedInterest;  // real + credit 合计（见 §6.3）
    uint256 totalCreditInterest;     // credit 利息累计（见 §6.3）
    uint256 totalLeveragedYT;
    MarketState state;
    address creditToken;             // 缓存 verse uAsset 对应的 GenesisCredit 地址（见 INV-21 约束 8）
}
```

`POLend` 不在 `LendMarket` 中保存：

- `pt`
- `pol`
- `totalLeveragedDebt`
- `availableLaunchLiquidity`

### 6.2 Market 状态

```solidity
enum MarketState {
    None,
    Genesis,
    Locked,
    Settled,
    Refund
}
```

`None` 表示 market 已注册但无人参与杠杆创世。

第一笔 `leveragedGenesis` 成功存入利息后，market 从 `None` 进入 `Genesis`。

纯普通创世成功后，market 保持 `None`，不进入 `Locked / Settled / Refund`。

`claimRefund / claimLeveragedYT / claimResidual` 对 `state == None` revert `InvalidState`。

`Genesis → Refund` 的触发条件：创世阶段结束时（`totalNormalFunds < minTotalFund` 且 `totalLeveragedInterest < minTotalFund`），且 `market.state == Genesis`（有人参与杠杆创世）。`Launcher.changeStage` 在此条件下调用 `POLend.markRefundable(verseId)`。若 `market.state == None`（无杠杆参与），不调用 `markRefundable`。

### 6.3 用户杠杆状态

用户级杠杆利息按来源分两栏存储：

```solidity
mapping(uint256 verseId => mapping(address user => uint256)) leveragedInterestPaid;    // 真付 uAsset 利息（正常 leveragedGenesis 路径，字段名复用旧名承载 real 部分）
mapping(uint256 verseId => mapping(address user => uint256)) creditInterestPaid;  // GenesisCredit 抵扣利息（leveragedGenesisWithCredit 路径）
```

real 与 credit 两栏独立累加，不互相扣减；同一用户对同一 verse 可同时累积两栏。

market 级新增：

```solidity
uint256 totalCreditInterest;  // 该 verse 累计的 credit 利息（creditInterestPaid 在 market 维度的合计）
```

`market.totalLeveragedInterest` 保留为 real + credit 合计存储；real 部分用差值推导：

```text
realInterest = market.totalLeveragedInterest - market.totalCreditInterest
```

`totalCreditInterest` / `totalLeveragedInterest` 都是只增累计量，refund 路径不扣减（与原 `leveragedInterestPaid` / `totalLeveragedInterest` 的 refund 语义一致，用 `refundClaimed` 防重复）。这不会引发 burn 错误：`markRefundable` 与 `finalizeLeveragedGenesis` 都 `require market.state == Genesis` 并分别迁移到 `Refund` / `Locked` 终态（状态机互斥），同一 verse 的 refund 与 finalize 不会都发生，故 `totalCreditInterest` 在 finalize 时刻仍精确等于该 verse 未退走的 GenesisCredit 托管量。

兼容性：存储字段保留旧名 `leveragedInterestPaid` 承载 real 部分（与 `creditInterestPaid` 分栏）；对外 view `leveragedInterestPaid(verseId, user)` 返回 real+credit 合计，与 `getUserLeveragedDebt` 合计口径一致；存储层拆栏，view 层仍合计。real 部分用 `totalLeveragedInterest - totalCreditInterest` 差值推导仅在 finalize treasury 清扫时用。

per-verse `totalCreditInterest` 必须独立记账的原因：POLend 对某 uAsset 的 GenesisCredit 托管余额是该 uAsset 所有 verse 的 credit 利息合计（混池），finalize verse X 时 burn 的量必须精确等于 verse X 的 `totalCreditInterest`，不能动 verse Y 的份额。

不保存 `borrowedAmount`，不需要 `LeveragedPosition` 结构体。用户可多次参与杠杆创世，两栏各自持续累加。

### 6.4 残值状态

`ResidualState` 只保存初始总残值：

```solidity
struct ResidualState {
    uint256 residualUAsset;
    uint256 residualMemecoin;
}
```

用户 claim 后不递减这两个基数，只用 `residualClaimed` 防止重复领取。

### 6.5 Claim 状态

语义上保留三类独立 claim 状态：

- `refundClaimed`
- `leveragedYTClaimed`
- `residualClaimed`

三类状态在本文档中视为独立 bool 语义；实现层可将其压缩为位图等内部表示，只要对外行为与三个独立 bool 等价即可。

### 6.6 按 uAsset 维度的系统债务

`POLend` 必须按 `uAsset` 维度保存系统债务：

```text
globalDebtByUAsset[uAsset]
```

不保留单一 `globalTotalDebt` 产品语义，不把不同 `uAsset` 的债务混成名义总数。

对外 view：

```text
getTotalDebtByUAsset(uAsset)
```

不需要 `getTotalDebt()` 返回所有 `uAsset` 债务的名义总和。

`globalDebtByUAsset[uAsset]` 与 `uAsset.mintingStatusTable[POLend].amountInMinted` 保持一致口径：

- POLend mint 增加对应 `uAsset` 债务
- POLend repay 减少对应 `uAsset` 债务

`Genesis` 阶段的推导债务不计入 `globalDebtByUAsset`。

D mint 量始终基于 `totalLeveragedInterest`（real + credit 合计）按固定利率推导，credit 路径与正常路径口径一致；`globalDebtByUAsset[uAsset]` 在 `finalizeLeveragedGenesis` 时按合计债务增加，不区分来源。credit 利息同样受 `debtCap` + aggregate `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 约束（见 §7），不引入额外 uAsset 通胀上限放松。

单位一致性前提：`market.totalCreditInterest` 能与真付 `uAsset` 利息 raw-unit 同栏并入 `totalLeveragedInterest`、参与 launch gate / debt 推导 / YT / residual 分配，前提是 GenesisCredit 与该 verse `uAsset` 同 raw-unit 会计口径。当前 GenesisCredit 固定 18 decimals，故 credit path 只支持 `uAsset.decimals() == 18`。`leveragedGenesisWithCredit` 在该 verse 首次解析 credit token 的流程内（经 `creditOf(uAsset)` 取得地址后、写入 `market.creditToken` 缓存前）校验 `uAsset` 与 GenesisCredit 均为 18 decimals，不满足时 revert `CreditDecimalsMismatch`（见 §8）。

### 6.7 Settlement dust reserve

`POLend` 必须按 `uAsset` 维度维护全局 settlement dust reserve：

```solidity
struct SettlementDustState {
    uint128 reserve;
    uint128 maxReserve;
}

mapping(address uAsset => SettlementDustState) settlementDustStates;
```

其中：

- `reserve` 是 `POLend` 当前持有、可用于 bounded settlement deficit 的该 `uAsset` 全局 reserve 余额
- `maxReserve` 是该 `uAsset` 全局 reserve 总上限，不是单 verse 上限，不是单次 settlement 上限

本文中的 launch-supported `uAsset` 指注册中心允许用于新 verse 注册 / launch 的 supported `uAsset`。治理 / 运维不得把某 `uAsset` 开放为 launch-supported，除非 Launcher 募资参数和 POLend settlement dust reserve 都已配置完成。

所有 launch-supported `uAsset` 都必须先配置 `maxReserve > 0`。POLend 不通过 `fundMetaDatas` 等募资参数推断 supported 状态；owner 必须显式调用：

```text
setMaxSettlementDustReserve(address uAsset, uint128 maxReserve)
```

setter 规则：

- `uAsset != address(0)`
- `maxReserve > 0`
- 若下调上限，必须满足当前 `reserve <= maxReserve`

`finalizeLeveragedGenesis` 必须把真付部分（realInterest）的杠杆利息全额清扫至 `protocolTreasury`。GenesisCredit 抵扣的 credit 利息没有对应 `uAsset` token 流入，不进入 treasury 清扫：

```text
realInterest = market.totalLeveragedInterest - market.totalCreditInterest
treasuryInterest = realInterest
```

`realInterest` 全额转入 `POLend.protocolTreasury`。该清扫不 mint，不增加 debt，不创建任何用户债权，不进 reserve。`realInterest` 是 real 部分；`CreditBurned.totalCreditInterest` 承载 credit 部分，二者合起来对应 `market.totalLeveragedInterest`。settlement dust reserve 的注入路径只有 Launcher bootstrap unused `uAsset`（`_handleBootstrapResiduals` → `fundSettlementDustReserve`）与手动 `fundSettlementDustReserve`，与 finalize treasury 清扫解耦。

`finalizeLeveragedGenesis` 还必须 burn POLend 托管的该 verse 对应 GenesisCredit，burn 量精确等于该 verse `market.totalCreditInterest`（混池 burn 安全性见 §6.3）。

唯一 public funding 入口为：

```text
fundSettlementDustReserve(address uAsset, uint256 amount)
```

规则：

- permissionless，任何地址都可调用
- `amount > 0`
- `settlementDustStates[uAsset].maxReserve > 0`
- 必须在 token transfer 前先读取 `capacity = maxReserve - reserve`
- 若 `msg.sender != Launcher`，必须在 transfer 前要求 `amount <= capacity`
- 若 `msg.sender == Launcher`，允许 over-capacity；credited 进入 reserve，`excess` 同交易转入 `protocolTreasury`
- 成功 funding 不产生 claim 权利，不进入残值
- 不受 pause 阻断；该入口只注入 `uAsset`，不产生 claim 权利，属于 unlock / repay 安全出口

Launcher 在 bootstrap liquidity deployment 后若发现 auxiliary pool actual spend 低于 desired budget 而留下 unused `uAsset`，必须调用该统一入口把该部分 unused `uAsset` 注入全局 reserve；若 reserve 已满，则 excess 进入 treasury。unused `memecoin` 必须 burn，不进入 reserve。该处理直接以实际执行结果为准，不依赖单独文档化的 bootstrap rounding-envelope accept/reject 规则，也不要求 auxiliary underspend 先满足额外的 backing / equality guard。Launcher 必须 emit `BootstrapUnusedAssetsHandled` 记录该 `verseId` 的 unused `uAsset` 与 burned `memecoin` 来源；POLend 的 `SettlementDustReserveFunded` 记录实际 reserve credited / treasury excess 结果。

## 7. 债务推导

每个 market 的总杠杆债务不存储，始终由固定利率和累计利息推导：

```text
totalLeveragedDebt = totalLeveragedInterest * 1e18 / market.interestRate
```

用户债务也不存储：

```text
userLeveragedDebt = userInterestPaid * 1e18 / market.interestRate
```

debt view 状态矩阵：

| Market 状态 | `getTotalLeveragedDebt` | `getUserLeveragedDebt` | `debtCap` | `remainingAdditionalInterest` |
| --- | --- | --- | --- | --- |
| 未注册 | revert | revert | revert | revert |
| `None` 且 Launcher verse 仍处于 `Genesis` | `0` | `0` | 正常计算 | 正常计算 |
| `None` 且 Launcher verse 已离开 `Genesis` | `0` | `0` | `0` | `0` |
| `Genesis` | 推导值 | 推导值 | 正常计算 | 正常计算 |
| `Locked` | 推导值 | 推导值 | `0` | `0` |
| `Settled` | 推导值 | 推导值 | `0` | `0` |
| `Refund` | 理论推导值 | 理论推导值 | `0` | `0` |

已注册但 `state == None` 时，`getLeveragedDebtInfo(verseId)` 返回 `totalLeveragedInterest=0,totalLeveragedDebt=0,interestRate=market.interestRate`，并按上表返回 `debtCap / remainingAdditionalInterest`。

若 `settlementDustStates[uAsset].maxReserve == 0`，该 market 对应 `uAsset` 未完成全局 reserve 配置，`getLeveragedDebtInfo(verseId)` 必须返回 `debtCap=0,remainingAdditionalInterest=0`，避免 view 层展示实际运行态会拒绝的可用容量。

`Refund` 状态下的 `getTotalLeveragedDebt(verseId)` 仍只是理论推导值，不代表真实已 mint 债务。只有成功执行 `finalizeLeveragedGenesis` 后，该 verse 的债务才进入真实系统债务。

`getLeveragedDebtInfo(verseId)` 只查询该 verse 的债务信息，与全局债务无关。

```solidity
struct LeveragedDebtInfo {
    uint256 totalLeveragedInterest;
    uint256 totalLeveragedDebt;
    uint256 interestRate;
    uint256 debtCap;
    uint256 remainingAdditionalInterest;
}
```

其中：

```text
rawDebtCap = fullPrecisionMulDiv(leveragedDebtFactor, max(totalNormalFunds, minTotalFund), 1e18)
aggregateDebtCap = MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - totalNormalFunds
debtCap = min(rawDebtCap, aggregateDebtCap)
totalLeveragedDebt = totalLeveragedInterest * 1e18 / market.interestRate
```

`debtCap` 是当前可新增杠杆创世状态下的有效上限，已包含 aggregate genesis funds 上限；`rawDebtCap` 只表示 `leveragedDebtFactor` 推导出的原始上限。`remainingAdditionalInterest` 表示在当前 `Genesis` 状态下还能新增的最大利息，使新增后的推导债务仍满足 `totalLeveragedDebt <= debtCap`。

精确计算：

```text
maxTotalLeveragedInterest = ((debtCap + 1) * market.interestRate - 1) / 1e18

if maxTotalLeveragedInterest <= totalLeveragedInterest:
    remainingAdditionalInterest = 0
else:
    remainingAdditionalInterest = maxTotalLeveragedInterest - totalLeveragedInterest
```

以上容量计算只在 `settlementDustStates[uAsset].maxReserve > 0` 时执行；否则容量返回 0。

该公式与 `totalLeveragedInterest * 1e18 / market.interestRate` 的向下取整语义严格匹配。实现应使用全精度乘除，避免中间乘法溢出。

## 8. 错误语义

`InvalidState`：状态前置条件不满足。

`InvalidConfig`：配置前置条件不满足。

`POLend` 侧 `InvalidConfig` 使用场景：

- `registerLendMarket`：对应 `uAsset` 未完成全局 reserve 配置
- `fundSettlementDustReserve`：`uAsset` 未完成全局 reserve 配置
- `initialize / setLeveragedDebtFactor`：`leveragedDebtFactor > uint128.max * 1e18`

`POLend` 侧 `InvalidState` 使用场景：

- `registerLendMarket`：market 已注册；Launcher 返回的 verse `uAsset == address(0)` 时 `ZeroInput`
- `leveragedGenesis`：market 未注册或非 None/Genesis，Launcher verse 非 Genesis
- `leveragedGenesisWithCredit`：market 未注册或非 None/Genesis，Launcher verse 非 Genesis，`creditAmount == 0` 时 `ZeroInput`，该 `uAsset` 在 `GenesisCreditFactory` 未部署对应 GenesisCredit（revert `NoCreditForUAsset`），或该 verse `uAsset` / 缓存的 GenesisCredit decimals 非 18（revert `CreditDecimalsMismatch`，仅在该 verse 首次解析 credit token 时触发）
- `markRefundable`：market 非 Genesis
- `finalizeLeveragedGenesis`：market 非 Genesis
- `recordLeveragedYT`：market 非 Locked 或已记录
- `preRedeemPTFee`：market 非 Locked
- `executeGlobalSettlement`：market 非 Locked
- `claimRefund`：market 非 Refund
- `claimLeveragedYT`：market 非 Locked/Settled
- `claimResidual`：market 非 Settled
- `getLeveragedDebtInfo`：market 未注册
- `getUserLeveragedDebt`：market 未注册；`user == address(0)` 时 `ZeroInput`
- `getTotalDebtByUAsset`：`uAsset == address(0)` 时 `ZeroInput`

`POLSplitter` 侧 `InvalidState` 等价错误：

- `recordPTBackingRatio`：verse 未 initialize 或 ratio 已记录
- `split / previewPTToUAsset / preRedeemPTFee / redeemPT / redeemYT`：ratio 未记录
- `AlreadyUnlocked`：split/merge 时 verse 已 Unlocked 或 settle 已完成
- `NotUnlocked`：settle 时 verse 尚未 Unlocked
- `AlreadySettled`：重复 settle，或 preRedeemPTFee 时已 settled
- `NotSettled`：redeemPT/redeemYT 时尚未 settled
- `AlreadyDeployed`：`initializeVerse` 重复调用

`GenesisCredit` / `GenesisCreditFactory` 侧错误语义（permissionless claim 与 owner-only 部署）：

GenesisCredit 侧（permissionless，home-chain 限定）：

- `NotHomeChain(uint32 homeChainEid)`：`claim` 在非 home 链调用（`endpoint.eid() != homeChainEid`）。远程 OFT 部署只能桥接供应，不得经 `claim` 铸造。
- `ZeroInput()`：`claim(amount == 0)` 或 `burn(amount == 0)`。
- `AlreadyClaimed()`：`claim` 时 `claimed[msg.sender] != 0`（每用户最多领一次）。
- `InvalidProof()`：`claim` 的 merkle proof 校验失败。

GenesisCreditFactory 侧（owner-only 部署）：

- `ZeroAddress()`：构造时 `lzEndpoint_` 为零地址（`owner_` 由 OZ Ownable 内部零地址校验，`homeChainEid_` 为值类型无零值语义）。
- `ZeroUAsset()`：`deployCredit` 时 `uAsset == address(0)`。
- `AlreadyDeployed()`：`deployCredit` 时该 `uAsset` 已部署（`registry[uAsset] != address(0)`）。
- `InvalidUAssetDecimals(uint8 actual, uint8 expected=18)`：`deployCredit` 时 `uAsset.decimals() != 18`。credit 固定 18-dec，raw-unit 1:1 记账才成立（与 POLend 侧 `CreditDecimalsMismatch` 呼应）。

`SettlementDustReserveExceeded(uint256 amount, uint256 capacity)`：`fundSettlementDustReserve(address,uint256)` 的非 `Launcher` 调用者在 transfer 前请求金额超过剩余 capacity。

`SettlementDustInsufficient(uint256 deficit, uint256 availableReserve)`：`executeGlobalSettlement` 中 `recoveredUAsset < verseDebt`，且实际缺口超过当前 `uAsset` 全局 reserve 余额。该错误表示缺口不再被当前 reserve 规则接受为可补偿 dust。

统一使用 `InvalidClaim` 覆盖无份额或重复领取：

- `claimRefund`
- `claimNormalYT`
- `claimLeveragedYT`
- `claimResidual`
- `redeemAuxiliaryLiquidity`
- 普通 refund
- preorder refund
- `redeemYT`：`outstandingYT == 0`

不保留 `InvalidRefund / InvalidRedeem` 这种分裂错误。

`POLend` 与 `POLSplitter` 的重入锁使用 `ReentrancyGuardReentrantCall` 错误。

`ptAmount = 0` 时 `Launcher` / `POLend` 不应调用下游 `Splitter.preRedeemPTFee`；若直接触发 Splitter-only 防御路径，因换算 backing 为 0 而 revert `InvalidClaim`。

settled 后不应再走 `preRedeemPTFee`，而应由 `Launcher` 路由到 `redeemPT`。`preRedeemPTFee` 的 settled 检查不作为正常业务分支设计。`POLSplitter` 侧的 `AlreadySettled` 检查是防御性安全防线：正常流程中该检查不会触发（Launcher 在 `Locked` 时走 `preRedeemPTFee`，`Unlocked` 后走 `redeemPT`）；其作用是在 Launcher 路由逻辑异常时阻止 post-settle PT burn，防止不可逆资金损失。

## 9. 互斥关系

普通侧：

- `refund` 只在 `Refund`
- 初始 `YT` claim 只在成功路径
- `redeemAuxiliaryLiquidity` 只在 `Unlocked` 及之后成功路径
- `refund` 与成功路径 claim / redeem 互斥

杠杆侧：

- `claimRefund` 只在 `Refund`
- `claimLeveragedYT` 只在成功路径
- `claimResidual` 只在 `Settled`
- `claimRefund` 与 `claimLeveragedYT / claimResidual` 互斥

Preorder：

- 成功路径：主池首笔交易后按比例 vesting 领取 `memecoin`
- Refund 路径：原路退回 `uAsset`
