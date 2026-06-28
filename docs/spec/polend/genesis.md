# POLend Genesis

本文件覆盖 POLend 创世流程：普通创世、Preorder、门槛与杠杆上限、杠杆创世、Genesis→Locked 迁移与初始 YT claim。POLend 子系统整体导航见 [polend/README.md](README.md)。

## 1. 普通创世状态

`Launcher` 不再使用 `GenesisFund`。

`Memeverse` 内保存：

```text
totalNormalFunds
```

`totalNormalFunds` 表示普通创世用户支付的 `uAsset` 总额，不包含 preorder，不包含杠杆利息，不包含杠杆债务。

用户侧只保存：

```text
userGenesisFund
```

普通创世不拆存 `userMemecoinFund / userAuxiliaryFund`。

`genesis(verseId, amount, user)`：

- `amount` 使用 `uint256`
- 只接受该 verse 的 `uAsset`
- 只在 `Genesis` 阶段开放
- 累加 `totalNormalFunds += amount`
- 累加 `userGenesisFund += amount`
- `Genesis` 事件只记录 `amount`

普通退款：

- 只在 `Refund` 状态开放
- 按 `userGenesisFund` 全额退回该 verse 的 `uAsset`
- 一次性领取
- 不清零 `userGenesisFund`，用 `isRefunded` 标记
- `userGenesisFund = 0` 或重复领取 revert `InvalidClaim`

## 2. Preorder

`preorder` 是独立于普通创世与杠杆创世的资金池。

`preorder` 资金：

- 只接受该 verse 的 `uAsset`
- 托管在 `Launcher`
- 不参与四池部署本金
- 与 `genesis` 是独立账本
- 同一地址可以同时参与 `genesis` 和 `preorder`

`preorder(verseId, amount, user)`：

- `amount` 使用 `uint256`
- `amount > 0`
- `user != address(0)`
- 只在 `Genesis` 阶段开放
- 只要仍处于 `Genesis`，即使已经满足 flash lock 条件，也仍可继续参与

`preorder` 容量只基于主池 memecoin 侧资金计算：

```text
preorderCap = (totalNormalFunds + totalLeveragedDebt) * 7 / 10 * preorderCapRatio / RATIO
```

`preorderCap` 不把辅助池 30% 纳入容量。

`preorderCapRatio` 必须满足 `0 < preorderCapRatio <= RATIO`。

`preorder` 写入前必须满足：

```text
totalPreorderFunds + amount <= preorderCap
```

超出容量时 revert cap exceeded 语义错误。`preorderCap` 与容量预检必须使用全精度乘除或等价的 overflow-safe 计算顺序，不允许依赖不安全的普通中间乘法。

`totalLeveragedDebt` 使用该 market 固定利率和当前 `totalLeveragedInterest` 推导；market 为 `None` 时视为 0。

`preorder` 在 `Locked` 建池后的行为：

- `Launcher` 先部署 `memecoin/uAsset` 主池
- 所有初始 `memecoin` 都在主池
- `Launcher` 使用托管 preorder `uAsset` 执行主池第一笔交易，买出 `memecoin`
- 买出的 `memecoin` 进入 `Launcher` 托管
- 用户按 `userPreorderFunds / totalPreorderFunds` 分配
- vesting 从首笔交易完成时间开始

`Refund` 状态下，preorder 用户按 `userPreorderFunds` 一次性退回 `uAsset`。`userPreorderFunds = 0` 或重复 refund revert `InvalidClaim`。

## 3. 成功门槛与杠杆上限

`Genesis -> Locked` 成功门槛是 OR：

```text
totalNormalFunds >= minTotalFund
OR
totalLeveragedInterest >= minTotalFund
```

杠杆侧成功门槛比较的是 `totalLeveragedInterest`，不是 `totalLeveragedDebt`。
这只是 `Genesis -> Locked` 的 launch gate；成功后的部署、容量和分账资金口径仍看 `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt`，不要混读。

`minTotalFund` 按该 verse 的 `uAsset` 精度解释：

- 普通侧比较 `uAsset` 本金总额
- 杠杆侧比较已支付 `uAsset` 利息总额

`flashGenesis=true` 只表示允许提前 `changeStage`，不会自动进入 `Locked`。

只有真正离开 `Genesis` 后，`genesis / leveragedGenesis / preorder` 才关闭。

杠杆上限：

```text
debtCapBase = max(totalNormalFunds, minTotalFund)
rawDebtCap = fullPrecisionMulDiv(leveragedDebtFactor, debtCapBase, 1e18)
debtCap = min(rawDebtCap, MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - totalNormalFunds)
totalLeveragedDebt <= debtCap
```

`leveragedDebtFactor` 是全局杠杆债务上限系数，所有 verse 共享，不是单用户倍数。对单个 verse 而言，factor 推导出的原始杠杆债务上限为 `fullPrecisionMulDiv(leveragedDebtFactor, max(totalNormalFunds, minTotalFund), 1e18)`，实际有效上限还必须受 aggregate genesis funds 剩余容量限制。

约束：`fullPrecisionMulDiv(leveragedDebtFactor, interestRate, 1) >= 1e36`。该条件是纯杠杆创世独立达到成功门槛的前提。`leveragedDebtFactor` 无独立下限，只与 `interestRate` 联合约束。market 注册在复制当前默认配置前校验该约束；全局配置 setter 也必须保持同一约束，保证后续注册可用。

`fundBasedAmount` 的地址排序最紧分支（`memecoin > uAsset`）要求 `fundBasedAmount <= 2^64 - 1`，该上界只服务 launcher bootstrap 初始价格参数，不用于约束 `minTotalFund`、`totalNormalFunds` 或其他 fund-size 变量。

`MAX_LEVERAGED_DEBT_FACTOR = uint128.max * 1e18` 是 `leveragedDebtFactor` 的技术有效上限，不是经济最优值。aggregate genesis funds 支持域已按 `uint128.max` 封顶，更大的 `leveragedDebtFactor` 不会增加任何 verse 的可用 `debtCap` 或 `remainingAdditionalInterest`，因此 `initialize` 与 `setLeveragedDebtFactor` 都必须按 `InvalidConfig` 拒绝。所有 `leveragedDebtFactor` 相关计算都必须使用全精度 `mulDiv` 或等价 overflow-safe 实现安全完成，该上限校验不能依赖把 `minTotalFund`、`totalNormalFunds` 或 `totalLeveragedInterest` 预先限制到 `2^64 - 1` 这一错误前提。

`setLeveragedDebtFactor(newFactor)` 只影响仍可新增杠杆创世的未来 debt cap / `remainingAdditionalInterest` 计算，即 market 为 `None / Genesis` 且 Launcher verse 仍处于 `Genesis` 的情形。setter 不改变已注册 market 的固定 `interestRate`，不改变已 mint 债务，不改变 `Locked / Settled / Refund` 的结算或 claim 语义。降低 `leveragedDebtFactor` 后，若已有 Genesis market 的累计债务已达到或超过新 cap，后续 `leveragedGenesis` 可能被阻止，但既有利息不会被追溯 revert。`finalizeLeveragedGenesis` 仍不重复检查 debt cap。

`MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 固定为：

```text
type(uint128).max
```

成功路径的创世总资金口径为：

```text
totalGenesisFunds = totalNormalFunds + totalLeveragedDebt
```

`totalGenesisFunds` 不包含 preorder。

成功 `genesis` / `leveragedGenesis` 写入后都必须保持：

```text
totalGenesisFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS
```

即使普通资金为 0，杠杆债务上限也仍受 aggregate MAX 约束，实际可达到的上限为：

```text
min(fullPrecisionMulDiv(leveragedDebtFactor, minTotalFund, 1e18), MAX_SUPPORTED_TOTAL_GENESIS_FUNDS)
```

`leveragedGenesis` 写入前必须用本次新增利息后的总利息做预检：

```text
nextTotalLeveragedInterest = totalLeveragedInterest + interestAmount
previewDebt = nextTotalLeveragedInterest * 1e18 / market.interestRate
rawDebtCap = fullPrecisionMulDiv(leveragedDebtFactor, max(totalNormalFunds, minTotalFund), 1e18)
previewDebt <= rawDebtCap
totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS
```

预检必须基于累计 `nextTotalLeveragedInterest -> previewDebt`，不能只检查当前调用新增 delta。

成功门槛比较 `totalLeveragedInterest`（用户实际支付的 uAsset 利息总额），四池部署资金口径使用 `totalLeveragedDebt`（利息推导出的债务本金，`debt = interest × 1e18 / interestRate`）。二者数值不同但方向一致。

## 4. 杠杆创世

`leveragedGenesis(verseId, interestAmount)`：

- 只允许 Launcher 已注册的 verse
- 只允许 Launcher verse 处于 `Genesis`
- market 为 `None` 时，本次调用成功后进入 `Genesis`
- market 为 `Genesis` 时，继续累计利息
- market 为其他状态时 revert
- `interestAmount` 必须大于 0
- 要求该 verse 的 `uAsset` 已完成全局 reserve 配置：`settlementDustStates[uAsset].maxReserve > 0`
- 参与地址为 `msg.sender`，没有 user-address 输入
- 从用户转入该 verse 的 `uAsset` 到 `POLend`
- 只累计 `leveragedInterestPaid[verseId][msg.sender]`
- 只累计 `market.totalLeveragedInterest`
- 不 mint `uAsset`
- 不存储 `borrowedAmount`
- 不存储 `totalLeveragedDebt`

事件：

```solidity
event LeveragedGenesis(uint256 indexed verseId, address indexed user, uint256 interestAmount);
```

### 4.1 GenesisCredit 抵扣杠杆创世

`leveragedGenesisWithCredit(verseId, creditAmount)`：冷启动期允许用户用 GenesisCredit（与该 verse `uAsset` raw-unit 1:1 对应的 ERC20/OFT）抵扣杠杆利息，等价于"免费借贷参与创世"。

GenesisCredit 当前固定 18 decimals，因此 credit path 只支持 `uAsset.decimals() == 18` 的 verse。`GenesisCreditFactory.deployCredit` 必须拒绝非 18-dec `uAsset`（revert `InvalidUAssetDecimals`），`POLend.leveragedGenesisWithCredit` 在该 verse 首次解析 credit token 的流程内（经 `creditOf(uAsset)` 取得地址后、写入 `market.creditToken` 缓存前）校验 `uAsset` 与 GenesisCredit 均为 18 decimals；不满足时 revert `CreditDecimalsMismatch`。非 18-dec `uAsset` 仍可走普通 `genesis` 与真付 `uAsset` 的 `leveragedGenesis`，但不得启用 GenesisCredit credit path。

- 只允许 Launcher 已注册的 verse
- 只允许 Launcher verse 处于 `Genesis`
- market 为 `None` 时，本次调用成功后进入 `Genesis`
- market 为 `Genesis` 时，继续累计
- `creditAmount > 0`
- 要求该 verse 的 `uAsset` 已完成全局 reserve 配置
- 经 `GenesisCreditFactory` 查该 `uAsset` 对应的 GenesisCredit 地址；无则 revert `NoCreditForUAsset`（credit 是可选路径，不影响正常 `leveragedGenesis`）
- `GenesisCredit.transferFrom(msg.sender, POLend, creditAmount)` → 托管到 `POLend`（**不 burn**，finalize 时统一 burn）
- `creditInterestPaid[verseId][msg.sender] += creditAmount`
- `market.totalCreditInterest += creditAmount`
- `market.totalLeveragedInterest += creditAmount`（real + credit 合计，用于 launch gate + D 推导 + debt cap 预检）
- 不 mint `uAsset`（与正常路径一致，mint 发生在 finalize）
- emit `LeveragedGenesisWithCredit(verseId, user, creditAmount)`

Debt cap 预检与正常路径同一公式，用 `nextTotalLeveragedInterest`（real + credit 合计）推导 `previewDebt <= debtCap`。GenesisCredit 抵扣的利息同样吃 debt cap，不引入额外 uAsset 通胀上限放松。

GenesisCredit 抵扣的利息**计入 `minTotalFund` 启动门槛且不封顶**（launch gate 策略）：协议可纯靠发 GenesisCredit 把 verse 推到 `Locked`。这是有意的冷启动策略，`debtCap` + aggregate `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` 仍对 D 的 mint 量封顶，故自助启动的 D 通胀有界。

事件：

```solidity
event LeveragedGenesisWithCredit(uint256 indexed verseId, address indexed user, uint256 creditAmount);
```

如果最终进入 `Refund`：

- 杠杆用户只取回自己支付的利息
- 不存在 `uAsset` 本金退款
- 因为 `uAsset` 从未在 `Genesis` 阶段 mint

`Genesis -> Refund` 时，只有 `getTotalLeveragedDebt(verseId) > 0` 才调用：

```text
POLend.markRefundable(verseId)
```

无杠杆参与时，market 保持 `None`，不记录 `Refund`，因为没有杠杆利息可退。

`markRefundable`：

- 只由 `Launcher` 调用
- 只允许 market 处于 `Genesis`
- 不需要推导或保存债务
- 只把 market 状态改成 `Refund`

`claimRefund`：

- 只允许 `Refund`
- 权益和领取标记基于 `msg.sender`
- `to != address(0)`，退款转给 `to`
- real 部分：按 `leveragedInterestPaid[verseId][msg.sender]` 退回该 verse 的 `uAsset`（原路径，存储字段复用旧名承载 real 部分），退回成功 emit `ClaimRefund(verseId, user, to, amount)`
- credit 部分：按 `creditInterestPaid[verseId][msg.sender]` 从 POLend 托管余额 `GenesisCredit.transfer(to, amount)` 退回 GenesisCredit token（不凭空 materialize uAsset）
- 一次性领取（real 与 credit 合并一次 claim）
- 不清零 `leveragedInterestPaid` / `creditInterestPaid`
- 用 `refundClaimed` 标记
- `leveragedInterestPaid == 0 && creditInterestPaid == 0` 或重复领取 revert `InvalidClaim`
- credit 退回成功后 emit `CreditRefunded(verseId, user, to, amount)`
- 返回值 `refundedAmount` 仅承载 real-uAsset 退款额（credit-only 参与者为 0）；credit 退款额只由 `CreditRefunded` 事件承载。credit-only 参与者一次成功调用返回 0 且不 emit `ClaimRefund`——索引器/前端必须以 `ClaimRefund` 或 `CreditRefunded` 判定退款成功，不可单看 `refundedAmount > 0` 或仅监听 `ClaimRefund`

real 用户退 uAsset、credit 用户退 GenesisCredit，两条物理隔离；退的是托管中的真实 token，不凭空 materialize uAsset。

普通 refund、preorder refund、杠杆 `claimRefund` 三套账本独立，同一用户可分别领取自己参与过的部分。

## 5. Genesis -> Locked

`Launcher.changeStage` 从 `Genesis` 进入 `Locked` 时：

1. 若 `getTotalLeveragedDebt(verseId) > 0`，调用 `POLend.finalizeLeveragedGenesis(verseId)`
2. 调用 `POLSplitter.initializeVerse(verseId, pol, memecoin, uAsset, name, symbol)`
3. 部署 `memecoin/uAsset` 主池
4. 执行 preorder 首笔交易
5. Router 主池执行完成、主池实际消耗 `uAsset` 与主池 LP/POL raw amount 已知后，调用 `POLSplitter.recordPTBackingRatio(verseId, mainPoolUAssetUsed, mainPoolPOLAmount)`
6. split 用于辅助池的 `POL`，部署三个辅助池
7. 若 `getTotalLeveragedDebt(verseId) > 0`，转移杠杆初始 `YT` 给 `POLend`
8. 若 `getTotalLeveragedDebt(verseId) > 0`，调用 `POLend.recordLeveragedYT(verseId, yt, totalLeveragedYT)`

`POLSplitter.initializeVerse` 无论有没有杠杆参与都必须调用。PT/YT 是 POL 拆分体系，与是否有杠杆创世无关。

纯普通创世时：

- 不调用 `finalizeLeveragedGenesis`
- 不调用 `recordLeveragedYT`
- 所有初始 `YT` 都归普通初始 claim 池
- POLend 不托管 `YT`
- market 保持 `None`

### 5.1 finalizeLeveragedGenesis

`finalizeLeveragedGenesis`：

- 只允许 `Launcher` 调用
- 只允许 `Genesis -> Locked` 流程调用一次
- 只允许 market 处于 `Genesis`
- 只在 `getTotalLeveragedDebt(verseId) > 0` 时调用
- 先把 market 状态设为 `Locked`
- mint `totalLeveragedDebt` 数量的该 verse `uAsset` 到 `Launcher`（基于合计 `totalLeveragedInterest`，real + credit 一同推导）
- 把真付部分 realInterest 全额清扫至 `protocolTreasury`：`realInterest = market.totalLeveragedInterest - market.totalCreditInterest`，该 `uAsset` 全额转给 `POLend.protocolTreasury`，不做 reserve 拆分。settlement dust reserve 仅由 Launcher bootstrap unused `uAsset`（`_handleBootstrapResiduals` → `fundSettlementDustReserve`）与手动 `fundSettlementDustReserve` 注入。credit 部分无 token 流入，跳过 treasury 清扫
- 若 `market.totalCreditInterest > 0`：**burn 托管的 GenesisCredit** `GenesisCredit.burn(market.totalCreditInterest)`（POLend 烧自己托管的 credit 余额，permissionless 自烧，无需 burner 权限模型），并 emit `CreditBurned(verseId, uAsset, totalCreditInterest)`。`totalCreditInterest == 0` 的 real-only finalize 跳过 burn 与事件——`GenesisCredit.burn(0)` 会 `revert ZeroInput()`，且无销毁发生不应发审计事件
- `globalDebtByUAsset[market.uAsset] += totalLeveragedDebt`

mint 数量：

```text
mintedUAsset = totalLeveragedInterest * 1e18 / market.interestRate
```

`finalizeLeveragedGenesis` 不重复检查 debt cap。

混池 burn 安全性：POLend 对某 uAsset 的 GenesisCredit 托管余额是该 uAsset 所有 verse 的 credit 利息合计（混池）。`markRefundable` 与 `finalizeLeveragedGenesis` 都 `require market.state == Genesis` 并分别迁移到 `Refund` / `Locked`（状态机互斥），同一 verse 的 refund 与 finalize 不会都发生，故 finalize 时刻该 verse 的 `totalCreditInterest` 仍精确等于其未退走的托管量，按 `market.totalCreditInterest` burn 不会误烧其他 verse 的份额（详见 [core.md §6.3](core.md)）。

`finalizeLeveragedGenesis` 完成成功路径的利息 treasury 清扫后，`claimRefund` 不可用。

### 5.2 四池部署

四池部署先汇总普通创世资金与杠杆债务：

```text
totalGenesisFunds = totalNormalFunds + totalLeveragedDebt
```

再统一按 `70/30` 拆分：

```text
totalMemecoinFunds = totalGenesisFunds * 7 / 10
totalAuxiliaryFunds = totalGenesisFunds - totalMemecoinFunds
```

其中：

- `70%` 进入 `memecoin/uAsset` 主池
- `30%` 进入后续三个辅助池路径

不分别拆普通侧和杠杆侧。

`totalGenesisFunds` 只用于成功部署资金口径，不等于用户可 refund 的资金池，也不包含 preorder。

主池铸造 `POL`。主池 LP token 即为 POL。POL mint 数量由主池部署时的 uAsset 存入量和初始价格决定，初始价格由 `fundBasedAmount` 参数定义。`fundBasedAmount` 配置语义见 [docs/spec/verse/config-matrix.md](../verse/config-matrix.md)。

`ptBackingNumerator / ptBackingDenominator` 的唯一权威写入点是 `POLSplitter.recordPTBackingRatio(verseId, numerator, denominator)`。`Launcher` 必须在主池 LP/POL 实际 mint 后、任何 `split` 或 PT 相关辅助池创建前调用一次；之后不可变。

记录参数：

- `mainUAssetFunds` 仅表示主池 bootstrap budget / 计划投入额，不表示实际 backing
- `numerator = mainPoolUAssetUsed`
- `denominator = mainPoolPOLAmount`

PT backing ratio 的实际额约束见 [INV-19](../invariants.md#inv-19-pt-backing-ratio-实际额约束)：必须基于主池 Router / AMM 实际执行结果（而非期望预算），未使用 bootstrap 资金的处置规则（`uAsset` 走 [core.md §6.7](core.md) dust/treasury、`memecoin` burn）亦由 INV-19 收口。

`denominator` 必须使用 launch 实际 mint 出来的 main pool LP/POL raw amount，不能使用预估值。

`POL` 统一按：

- `2/7` 进入 `POL/uAsset`
- `3/7` 进入 `split(POL)` 得到 `PT + YT`
- `2/7` 进入 `PT/POL`

split 得到的 `PT` 再按：

- `1/3` 进入 `PT/uAsset`
- `2/3` 进入 `PT/POL`

PT 切分的整数取整差额归 PT/POL 侧（`ptForPtUAsset = totalPT / 3`，`ptForPtPol = totalPT - ptForPtUAsset`）。

辅助池 uAsset 侧分配（`totalAuxiliaryFunds` = `totalGenesisFunds * 30%`）：

- `POL/uAsset`: `totalAuxiliaryFunds * 2/3`（与 2/7 POL 等值配对）
- `PT/uAsset`: `totalAuxiliaryFunds * 1/3`（与 1/7 PT 按固定 backing ratio 对应的 `uAsset` 配对）
- `PT/POL`: 无 uAsset 侧

四池：

| 池子 | 组成 |
|---|---|
| `memecoin/uAsset` | 主池 |
| `POL/uAsset` | 辅助池 |
| `PT/uAsset` | 辅助池 |
| `PT/POL` | 辅助池 |

三个辅助池 LP 总量由 `Launcher` 记录：

- `polUAssetLpAmount`
- `ptUAssetLpAmount`
- `ptPolLpAmount`

不在部署时分别存普通 LP / 杠杆 LP。后续按资金占比切分。

### 5.3 初始 YT

四池部署时统一 split 得到的 `YT`，再按资金占比切初始 claim 池：

```text
totalNormalClaimableYT = totalYT * totalNormalFunds / totalGenesisFunds
totalLeveragedYT = totalYT - totalNormalClaimableYT
```

取整差额归杠杆侧。所有涉及普通侧 / 杠杆侧按比例切分的场景，统一使用减法得到一侧，floor 除法得到另一侧；本文档中每个切分公式会显式声明取整差额归属。

普通初始 `YT` 托管在 `Launcher`。

杠杆初始 `YT` 必须先转给 `POLend`，再调用：

```text
POLend.recordLeveragedYT(verseId, yt, totalLeveragedYT)
```

`recordLeveragedYT`：

- 只由 `Launcher` 调用
- 必须在同一笔 `Genesis -> Locked` 交易内完成
- 只允许 market 处于 `Locked`
- 用 `market.yt != address(0)` 防重复
- 只记录 `yt` 与 `totalLeveragedYT`
- 不转 token
- 不改变 market 主状态

## 6. PT / YT 生命周期

PT/YT 生命周期（`initializeVerse` / `recordPTBackingRatio` / `split`-`merge` / `redeem` / `preview`）的 canonical home 在 [pt-yt-splitter.md §1](pt-yt-splitter.md)。

## 7. 初始 YT claim

普通和杠杆初始 `YT` 都是一人一次性领取全部应得初始 `YT`，重复领取 revert `InvalidClaim`，领取后拿到的是同一个 verse 的同一个 `YT token`。

普通初始 `YT`：

- 依赖 `Launcher` 成功路径
- verse 成功进入 `Locked` 后永久可领
- verse 处于 `Locked` 或 `Unlocked` 后均可补领
- `Unlocked` 后补领也允许，补领后可立即 `redeemYT`

杠杆初始 `YT`：

- 依赖 `POLend` market 成功路径
- 只在 market 处于 `Locked` 或 `Settled` 状态时可领取
- `None / Genesis / Refund` 时 revert `InvalidState`
- `Unlocked` 后补领也允许，补领后可立即 `redeemYT`

```text
normalYT = totalNormalClaimableYT * userGenesisFund / totalNormalFunds
```

`userGenesisFund = 0` revert `InvalidClaim`。

```text
userInterestPaid = leveragedInterestPaid[verseId][msg.sender] + creditInterestPaid[verseId][msg.sender]
leveragedYT = totalLeveragedYT * userInterestPaid / totalLeveragedInterest
```

`totalLeveragedDebt` 含 credit 部分（mint 基于合计），故杠杆 YT 份额随之增大，credit 用户按合计切 YT 与 real 用户等价。

`leveragedInterestPaid == 0 && creditInterestPaid == 0` revert `InvalidClaim`。

`claimLeveragedYT` 的权益和领取标记基于 `msg.sender`；`to != address(0)`，`YT` 转给 `to`。

不存在独立的“claim 权资产”。只有领取规则：初始参与地址可以领取其应得初始 `YT`；领取后的 `YT token` 可自由转让。
