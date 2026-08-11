# POLend Settlement & Fees

本文件覆盖 POLend 的辅助池/普通 fee 归集与领取、Locked→Unlocked 结算编排、杠杆残值领取、YieldDispatcher 分发、uAsset mint/repay 权限、权限配置与 Target ABI。POLend 子系统整体导航见 [polend/README.md](README.md)。

## Fee

### 1. 辅助池 fee

`memecoin/uAsset` 主池 fee 按以下规则分流：

- `uAsset` fee 走 Memeverse DAO governor 路径
- `memecoin` fee 给 `yieldVault`

以下规则覆盖三个辅助池：

- `POL/uAsset`
- `PT/uAsset`
- `PT/POL`

#### 1.1 token 级处理

`POL` fee 不区分普通侧 / 杠杆侧，全部永久 burn。

`uAsset fee / PT fee` 在 `Locked` 阶段按普通侧 / 杠杆侧切分，直接按金额计算，不保存或使用整数比例：

```text
totalGenesisFunds = totalNormalFunds + totalLeveragedDebt

govUAssetFee = fullPrecisionMulDiv(totalUAssetFee, totalLeveragedDebt, totalGenesisFunds)
normalUAssetFee = totalUAssetFee - govUAssetFee

govPTFee = fullPrecisionMulDiv(totalPTFee, totalLeveragedDebt, totalGenesisFunds)
normalPTFee = totalPTFee - govPTFee

取整差额归普通侧。
```

普通侧进入 `normalFeeStates`。

杠杆侧最终发给 Memeverse DAO governor：

- 杠杆侧 `uAsset fee` 走 Memeverse DAO governor 分发
- 杠杆侧 `PT fee` 必须转换成等值 `uAsset` 后走 Memeverse DAO governor 分发
- 杠杆侧 fee 不进入 `POLend.protocolTreasury`
- 杠杆侧 fee 不进入普通 fee 累计池

#### 1.2 Locked 阶段主动分发

`redeemAndDistributeFees` 在 `Locked` 阶段主动调用时：

- 捕获三个辅助池 fee
- `POL fee` burn
- 普通侧 `uAsset fee / PT fee` 写入 `normalFeeStates`
- 杠杆侧 `uAsset fee` 本次直接分发
- 杠杆侧 `PT fee` 必须走 `POLend.preRedeemPTFee` 预兑付成 `uAsset` 后本次直接分发
- 不写 `pendingAuxiliaryGovFeeStates`

#### 1.3 Locked -> Unlocked 最后捕获

`Locked -> Unlocked` 时，facade `src/verse/MemeverseLauncher.sol::changeStage` 经 delegatecall 入 `src/verse/MemeverseLaunchImpl.sol::changeStage` dispatcher，dispatcher 在 Locked 分支经嵌套 delegatecall 调用 `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked(verseId, polSplitter, hook)`，其内部首步 `_captureLockedAuxiliaryFees` 作为 `Locked` 阶段最后一次辅助池 fee 捕获（stage 翻转为 `Unlocked` 之前完成）。

`_captureLockedAuxiliaryFees`：

- 只在 `Locked -> Unlocked` 调用一次
- 捕获三个辅助池 fee
- `POL fee` burn
- 普通侧 `uAsset fee / PT fee` 写入 `normalFeeStates`
- 杠杆侧 `uAsset fee / PT fee` 写入 `pendingAuxiliaryGovFeeStates`
- 不调用 `preRedeemPTFee`

`pendingAuxiliaryGovFeeStates` 只承接这次切阶段时捕获但尚未分发的杠杆侧 fee：

```text
pendingUAssetFee
pendingPTFee
```

`pendingPTFee` 对应的 PT token 托管在 `Launcher` 地址上（从辅助池 claim 后直接持有）。

`pendingUAssetFee` 对应的 uAsset 同样托管在 `Launcher` 地址上，后续 `redeemAndDistributeFees` 调用时直接分发。

`pendingPTFee` 虽然是在 settle 前捕获，但后续会在 `Splitter` 已 settled 后分发，因此走 `Splitter.redeemPT`，不进入 `preRedeemedPT`。

若 `previewPTToUAsset(verseId, currentAuxiliaryGovPTFee + pendingPTFee) == 0`：

- 本次不调用 `preRedeemPTFee` / `redeemPT`
- 合并后的 PT fee 继续保留在 `pendingPTFee`
- 同次可分发的 `uAsset fee` / `memecoin fee` 继续正常分发
- 后续 `redeemAndDistributeFees` 再次尝试该 PT fee 的兑现

#### 1.4 Unlocked 后 fee

`Unlocked` 后：

- 新产生的辅助池非 `POL` fee 全部归 Memeverse DAO governor
- `POL fee` 继续 burn
- 普通用户仍可补领 `Locked` 阶段已累计但未领取的普通侧 fee

#### 1.5 quoteDistributionLzFee

`quoteDistributionLzFee`（由 `MemeverseFeePreviewReader` 暴露，地址取 `getLauncherContracts().feePreviewReader`）是计算 `redeemAndDistributeFees`（Launcher facade）所需跨链 fee 的 view；二者分处不同合约，算术必须逐字镜像，否则 quote 偏离实际执行。

异链分发 quote 必须覆盖：

- 主池 gov fee
- `pendingAuxiliaryGovFeeStates`
- 本次 preview 出的辅助池 governor fee
- settle 前 PT fee 预兑付后需要跨链发送的等值 `uAsset`
- settle 后 PT fee redeemPT 后需要跨链发送的等值 `uAsset`

### 2. 普通 fee 领取

普通 fee 是持续累计池，必须保存用户已领快照。

累计池：

```text
accUAssetFee
accPTFee
```

用户已领：

```text
claimedUAssetFee
claimedPTFee
```

领取公式：

```text
entitledUAsset = accUAssetFee * userGenesisFund / totalNormalFunds
claimableUAsset = entitledUAsset - claimedUAssetFee

entitledPT = accPTFee * userGenesisFund / totalNormalFunds
claimablePT = entitledPT - claimedPTFee
```

普通 fee 分配基准始终是 `userGenesisFund / totalNormalFunds`，不依赖 `YT` 持仓。

`accUAssetFee / accPTFee` 只累加，不随用户领取减少。

`claimNormalFees`：

- 只允许 `Stage.Locked` 及之后调用
- `Refund` 不允许
- `userGenesisFund = 0` 时 revert `InvalidClaim`
- 没有新增可领时返回 `(0, 0)`
- 只在 `claimableUAsset > 0` 时更新 `claimedUAssetFee`
- 只在 `claimablePT > 0` 时更新 `claimedPTFee`
- 先更新 claimed 状态，再转账或 redeem
- 在 `Unlocked` 后只补领历史 `Locked` 阶段累计的普通侧 fee

返回值：

```text
(uAssetAmount, ptAmount)
```

`Splitter` 尚未 settle：

- `uAssetAmount = claimableUAsset`
- `ptAmount = claimablePT`
- `PT fee` 直接发 `PT` 给用户

`Splitter` 已 settle：

- `Launcher` 用 `claimablePT` 调 `Splitter.redeemPT`
- `uAssetAmount = claimableUAsset + redeemedPTUAsset`
- `ptAmount = 0`
- 不处理用户已领取到自己地址上的 `PT`

若 `settled=true` 且 `previewPTToUAsset(verseId, claimablePT) == 0`：

- 本次不调用 `redeemPT`
- 本次不更新 `claimedPTFee`
- `claimableUAsset` 仍按正常路径领取
- `claimablePT` 继续保持未领取状态，后续 `claimNormalFees` 可再次尝试
- 返回值中的 `ptAmount` 表示本次仍未兑现的 PT fee，不表示已实际转给用户

该判断基于 `Splitter` per-verse settled 状态，不基于 Launcher stage。

用户在 `settled=false` 已领取 PT fee 到自己地址后，后续 `claimNormalFees` 不再处理这部分 PT；用户自己调用 `redeemPT`。

### 3. 普通辅助池 LP 领取

`redeemAuxiliaryLiquidity`：

- 只允许普通创世参与者调用
- 只在 `Stage.Unlocked` 后开放
- `Refund` 下不可调用
- 一次性领取三个辅助池普通份额 LP token
- 不 remove liquidity
- 不赎回 `POL / PT / uAsset / memecoin`
- 用 `isRedeemed` 防重复
- `userGenesisFund = 0`、`totalNormalFunds = 0` 或重复领取 revert `InvalidClaim`

返回值只包含三个 LP token 数量：

```text
polUAssetLpAmount
ptUAssetLpAmount
ptPolLpAmount
```

不返回 `polAmount / ptAmount / uAssetAmount / memecoinAmount`。

领取公式：

```text
polUAssetLpAmount = auxiliaryLiquidities.polUAssetLpAmount * userGenesisFund / totalNormalFunds
ptUAssetLpAmount = auxiliaryLiquidities.ptUAssetLpAmount * userGenesisFund / totalNormalFunds
ptPolLpAmount = auxiliaryLiquidities.ptPolLpAmount * userGenesisFund / totalNormalFunds
```

普通用户领取后不更新 `auxiliaryLiquidities`，只用 `isRedeemed` 防双领。

除三个辅助池普通份额 LP 外，该路径还必须分发 bootstrap pre-LP residual 的 normal share：

```text
normalResidualPOL = totalResidualPOL - floor(totalResidualPOL * totalLeveragedDebt / totalGenesisFunds)
normalResidualPT = totalResidualPT - floor(totalResidualPT * totalLeveragedDebt / totalGenesisFunds)
```

用户领取 normal residual 的公式与普通 LP 一样，按：

```text
userGenesisFund / totalNormalFunds
```

做一次 floor 分配。只有这里最终按用户比例 floor 后的尾差 dust 可以残留。

若 `totalLeveragedDebt > 0`，`changeStage Locked -> Unlocked` 同一笔交易内完成 `executeGlobalSettlement`，用户无法在杠杆 LP 切走前领取普通 LP；原因是 `redeemAuxiliaryLiquidity` 在 `Locked` 阶段不可调用，`changeStage` 原子完成后才进入 `Unlocked`。

`executeGlobalSettlement` 会先切走杠杆份额 LP，并把 `auxiliaryLiquidities` 更新为剩余普通份额 LP。普通用户只能领取剩余普通份额。
同一条 leveraged auxiliary settlement 输出还必须包含 bootstrap pre-LP residual 的 leveraged share：`leveragedResidualPOL` 与 `leveragedResidualPT`。这两个量不是新的永久托管桶，而是 leveraged side 在现有 settlement/claim 流程里的附加输出。

bootstrap pre-LP residual `POL/PT` 不是这里的普通 auxiliary LP split dust。它必须在更早的 bootstrap accounting 阶段先单独记录为四个量：

```text
normalResidualPOL
normalResidualPT
leveragedResidualPOL
leveragedResidualPT
```

其中：

```text
leveragedResidualPOL = floor(totalResidualPOL * totalLeveragedDebt / totalGenesisFunds)
leveragedResidualPT = floor(totalResidualPT * totalLeveragedDebt / totalGenesisFunds)
```

normal share 取余数，不能另建永久 launcher bucket。

纯普通创世时不调用 `executeGlobalSettlement`，三个辅助池 LP 全部留在 `auxiliaryLiquidities` 供普通用户领取。

纯杠杆创世时三个辅助池 LP 在 `executeGlobalSettlement` 中 100% 切给杠杆侧，普通侧 `auxiliaryLiquidities` 最终为 0。

## Settlement

### 4. Locked -> Unlocked 编排

`Launcher.changeStage` 在 `Locked -> Unlocked` 时按顺序执行（以下步骤在同一笔交易内原子执行，任一步骤失败则全部回滚）：

1. 经 delegatecall 委托 `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked(verseId, polSplitter, hook)`（由 facade `src/verse/MemeverseLauncher.sol::changeStage` 经 `src/verse/MemeverseLaunchImpl.sol::changeStage` dispatcher 的 Locked 分支嵌套 delegatecall 发起；`unlockFromLocked` 内部首步 `_captureLockedAuxiliaryFees` 完成捕获，stage 翻转为 Unlocked 之前完成）
2. `verse.currentStage = Unlocked`
3. `POLSplitter.settle(verseId)`
4. 若 `getTotalLeveragedDebt(verseId) > 0`，调用 `POLend.executeGlobalSettlement(verseId)`
5. 激活 unlock 后 public swap protection

`Splitter.settle` 只由 `Launcher` 调一次。

`POLend.executeGlobalSettlement` 只由 `Launcher` 调一次。纯普通创世没有杠杆份额 LP，不调用该函数。

无杠杆参与时不调用：

- `markRefundable`
- `finalizeLeveragedGenesis`
- `recordLeveragedYT`
- `executeGlobalSettlement`

### 5. PT fee 预兑付与分发

#### 5.1 settle 前：preRedeemPTFee

`Locked` 阶段主动调用 `redeemAndDistributeFees` 时，若捕获到杠杆侧 PT fee，由于 `Splitter` 尚未 settle，必须走预兑付：

```text
POLend.preRedeemPTFee(verseId, ptAmount, mintTo)
```

`POLend.preRedeemPTFee`：

- 只由 `Launcher` 调用
- `mintTo != address(0)`
- 返回 `uAssetBacking`
- 不调用 `YieldDispatcher.distributeSameChain`
- 不调用 `IOFT.send`
- 不重新 claim fee
- 不重新拆分普通侧 / 杠杆侧
- 只处理 `Launcher` 传入的 `ptAmount`
- 只能在 `Splitter` 尚未 settled 时按产品路径调用

流程：

```text
POLend.preRedeemPTFee
-> uAssetBacking = Splitter.preRedeemPTFee(verseId, ptAmount)
-> POLend mint uAssetBacking uAsset 到 mintTo
-> globalDebtByUAsset[market.uAsset] += uAssetBacking
-> emit PreRedeemPTFee(verseId, market.uAsset, ptAmount, uAssetBacking, mintTo)
```

`Splitter.preRedeemPTFee`：

- 只允许 `POLend` 调用
- burn account 固定为 `Launcher`
- 返回 `uAssetBacking = previewPTToUAsset(verseId, ptAmount)`
- 若 `ptAmount > 0` 但 `uAssetBacking == 0`，revert，不得 burn PT 或记录预兑付
- burn `Launcher` 当前持有的 `ptAmount` PT
- `preRedeemedPT.ptAmount += ptAmount`
- `preRedeemedPT.uAssetBacking += uAssetBacking`
- 不修改 `settlementUAsset`

settle 前还没有 settlement pool。

`preRedeemPTFee` 只处理已经进入 `Launcher` 的真实杠杆侧 `PT fee`。该路径的产品证据为：

```text
genesis + leveragedGenesis
-> Locked
-> mintPOLToken
-> split
-> real PT transferred to hook
-> redeemAndDistributeFees
-> preRedeemPTFee
-> unlock settlement
```

测试 `testRealPathLockedPreRedeemPTFeeSettlementBacking` 覆盖上述路径，并验证真实 `PT` 被转入 hook、分发时被 `Launcher` 持有、预兑付时被 burn、unlock settlement 后仍满足剩余 `PT.totalSupply()` 的 backing 要求。

`preRedeemPTFee` 的 `mintTo` 是 token 接收地址，不是最终业务 receiver：

- 本链：`mintTo = YieldDispatcher`
- 异链：`mintTo = Launcher`

本链路径：

```text
POLend.preRedeemPTFee(..., mintTo=yieldDispatcher)
Launcher 同笔调用 YieldDispatcher.distributeSameChain(uAsset, governor, TokenType.UASSET, amount)
```

异链路径：

```text
POLend.preRedeemPTFee(..., mintTo=Launcher)
Launcher 同笔 IOFT.send 到远端 YieldDispatcher
LayerZero endpoint 在远端调用 YieldDispatcher.lzCompose
compose receiver = governor
```

源链 / 本链同交易本地分发步骤失败时，整笔交易 revert，`preRedeemPTFee` 的 PT burn、`preRedeemedPT` 累计、uAsset mint、`globalDebtByUAsset` 增加都回滚。

异链路径中，`IOFT.send` 调用本身失败时整笔源链交易 revert；`IOFT.send` 成功后，目标链 `lzReceive / lzCompose` 失败不会回滚源链状态，由 LayerZero retry 机制处理目标链重试。

事件：

```solidity
event PreRedeemPTFee(uint256 indexed verseId, address indexed uAsset, uint256 ptAmount, uint256 uAssetBacking, address mintTo);
```

#### 5.2 settle 时：burnPreRedeemedBacking

`Splitter.settle` 遇到 `preRedeemedPT > 0` 时：

1. `Splitter` approve 该 verse `uAsset` 给 `POLend`，金额为 `preRedeemedPT.uAssetBacking`
2. `Splitter` 调用 `POLend.burnPreRedeemedBacking(verseId, preRedeemedPT.uAssetBacking)`
3. `POLend` 调 `uAsset.repay(address(splitter), preRedeemedPT.uAssetBacking)`
4. `globalDebtByUAsset[market.uAsset] -= preRedeemedPT.uAssetBacking`
5. `Splitter` 设置 `settlementUAsset = totalRedeemedUAsset - preRedeemedPT.uAssetBacking`
6. `Splitter` delete `preRedeemedPT[verseId]`

`burnPreRedeemedBacking`：

- 只允许 `Splitter` 调用
- 只能在该 verse settle 流程中调用
- 使用该 verse 记录的 `uAsset`
- 不能由调用方传入 token 地址

`preRedeemedPT = 0` 时，`Splitter.settle` 直接跳过 `burnPreRedeemedBacking`。

#### 5.3 settle 后：直接 redeemPT

Splitter 已 settled 后，杠杆侧 PT fee 直接走：

```text
Splitter.redeemPT(verseId, ptAmount, receiver)
```

本链：

- `receiver = YieldDispatcher`
- Launcher 同笔调用 `YieldDispatcher.distributeSameChain(... governor ...)`

异链：

- `receiver = Launcher`
- Launcher 同笔 `IOFT.send` 到远端 `YieldDispatcher`
- LayerZero endpoint 在远端调用 `YieldDispatcher.lzCompose`
- compose receiver 是 `governor`

settle 后这条路径：

- 不更新 `preRedeemedPT`
- 不 mint
- 不 repay backing
- 不改 `globalDebtByUAsset`
- 本链同交易本地分发失败则 `redeemPT` 回滚
- 异链 `IOFT.send` 成功后目标链 `lzReceive / lzCompose` 失败不回滚源链 `redeemPT`，由 LayerZero retry 处理

`pendingAuxiliaryGovFeeStates.pendingPTFee` 在后续 settled 后分发时走本路径。

### 6. POLend 全局结算

`POLend.executeGlobalSettlement(verseId)`：

- 只由 `Launcher` 调用
- 只在 `Locked -> Unlocked` 编排中调用一次
- 只处理杠杆份额的三个辅助池 LP
- 不处理普通份额 LP
- 纯普通创世不调用

`Launcher` 按杠杆资金占比切出三个辅助池 LP 并平仓：

```text
totalFunds = totalNormalFunds + totalLeveragedDebt

leveragedPolUAssetLpAmount = polUAssetLpAmount * totalLeveragedDebt / totalFunds
leveragedPtUAssetLpAmount = ptUAssetLpAmount * totalLeveragedDebt / totalFunds
leveragedPtPolLpAmount = ptPolLpAmount * totalLeveragedDebt / totalFunds

remainingPolUAssetLpAmount = polUAssetLpAmount - leveragedPolUAssetLpAmount
remainingPtUAssetLpAmount = ptUAssetLpAmount - leveragedPtUAssetLpAmount
remainingPtPolLpAmount = ptPolLpAmount - leveragedPtPolLpAmount
```

`auxiliaryLiquidities` 更新为三个 `remaining...` 数量。用减法得到普通剩余 LP，避免比例取整导致 LP 丢失。取整差额归普通侧。

平仓结果进入 `POLend`：

- `POL`
- `PT`
- `uAsset`

回收的自由 `POL`：

- 不经过 `Splitter.settle`
- 直接调用 `Launcher.redeemMemecoinLiquidity(..., unwrap=true)` burn POL LP token
- 取回底层 `uAsset + memecoin`
- 输出进入 `POLend`

回收的 `PT`：

- 调用 `Splitter.redeemPT(verseId, ptAmount, address(POLend))`
- 按 `previewPTToUAsset(verseId, ptAmount)` 兑回 `uAsset`
- 不得把非零 `PT` 静默当作 0 backing 处理
- 输出进入 `POLend`

回收的 `uAsset` 汇总后先偿还该 verse 全部债务。若出现有上限的整数舍入缺口，只能由对应 `uAsset` 的全局 settlement dust reserve 补足：

```text
verseDebt = totalLeveragedInterest * 1e18 / market.interestRate
deficit = verseDebt > recoveredUAsset ? verseDebt - recoveredUAsset : 0

if deficit == 0:
    consumedSettlementDustReserve = 0
    residualUAsset = recoveredUAsset - verseDebt

if deficit > 0:
    if deficit > settlementDustStates[market.uAsset].reserve:
        revert SettlementDustInsufficient(deficit, settlementDustStates[market.uAsset].reserve)
    consumedSettlementDustReserve = deficit
    settlementDustStates[market.uAsset].reserve -= deficit
    residualUAsset = 0

globalDebtByUAsset[market.uAsset] -= verseDebt
uAsset.repay(address(POLend), verseDebt)
```

`recoveredUAsset + consumedSettlementDustReserve >= verseDebt` 是必须成立的产品不变量。`consumedSettlementDustReserve` 只能覆盖正确执行固定 PT backing ratio 转换后的辅助 LP unwind、POL 赎回、PT 兑付和 full-range LP 数学中的整数舍入 dust；不得覆盖真实资不抵债、PT backing ratio / 模型错误、错误 LP 份额或 fee 账务缺口。

如果 `deficit > settlementDustStates[market.uAsset].reserve`，该缺口超出可补偿 dust 边界，`executeGlobalSettlement` 必须 revert。该 revert 边界由 `POLend.executeGlobalSettlement`（`POLend.sol` 的 `if (deficit > reserveBeforeSettlement) revert SettlementDustInsufficient(...)`）实现，并由 `MemeverseLauncherPOLendSettlementInvariant` 不变量套件证明：覆盖辅助 LP unwind、POL 赎回、PT 兑付、fee、整数舍入、极端价格状态，并断言任意允许 dust 补偿都被 `maxReserve` 全局容量约束（`assertLe(consumedSettlementDust, maxReserve)`）。

不设计：

- `remainingDebt`
- `badDebt`
- `unrepaidDebt`
- 部分偿还
- reserve 超上限兜底

剩余净资产写入 `ResidualState`：

```text
residualUAsset = recoveredUAsset > verseDebt ? recoveredUAsset - verseDebt : 0
residualMemecoin = recoveredMemecoin
```

若使用 reserve 补足 dust，`residualUAsset = 0`。`residualUAsset / residualMemecoin` 只从实际回收数量记录，任一项都可以为 0。

settlement 成功后不得清空该 `uAsset` 的全局 reserve，也不得把未消耗 reserve 转入 `POLend.protocolTreasury`。全局 reserve 只扣减实际消耗量，剩余余额保留给后续使用同一 `uAsset` 的 settlement。

完成后 market state 变为 `Settled`。

安全要求：

- `POLend.executeGlobalSettlement` 和 `POLSplitter.redeemYT` 必须使用重入锁
- `executeGlobalSettlement` 分三阶段执行，阶段之间不可交叉：
  1. **资产回收**：外部调用回收辅助池 LP、burn POL 赎回底层资产、PT→uAsset 兑付，获取 `totalRecoveredUAsset`
  2. **状态写入**：写入 `market.state = Settled`、防重复 settlement 状态、全局 reserve 实际消耗量、`residualStates`、`globalDebtByUAsset`
  3. **债务偿还与转账**：`uAsset.repay` 偿还 verseDebt；若流程中存在 treasury 收入，只能转已定义为 treasury 的金额，不能转未消耗 reserve；这两步必须在阶段 2 完成之后执行
- `redeemYT` 必须在 transfer 前完成所有状态更新（CEI 模式）

### 7. 杠杆残值领取

`claimResidual`：

- 只允许 `Settled`
- 只允许参与过杠杆创世的用户
- 权益和领取标记基于 `msg.sender`
- `to != address(0)`，残值转给 `to`
- 一次性领取
- 用 `residualClaimed` 防重复
- `userInterestPaid = 0` 或重复领取 revert `InvalidClaim`

领取公式：

```text
userInterestPaid = leveragedInterestPaid[verseId][msg.sender] + creditInterestPaid[verseId][msg.sender]
uAssetAmount = residualUAsset * userInterestPaid / totalLeveragedInterest
memecoinAmount = residualMemecoin * userInterestPaid / totalLeveragedInterest
```

`totalLeveragedInterest` 是 real + credit 合计，credit 用户按合计切残值与 real 用户等价。`leveragedInterestPaid == 0 && creditInterestPaid == 0` 或重复领取 revert `InvalidClaim`。

`residualUAsset / residualMemecoin` 是初始总残值基数，claim 后不递减。

`ResidualState` 不包含：

- 用户支付的利息
- `Splitter` 结算池中的 PT/YT 兑付资产
- 用户初始 claim 或后续 split 得到的 `YT` 对应权益

所有 `YT` 的价值兑现都从 `Splitter.redeemYT` 完成，和残值无关。

残值整数舍入 dust 永久留在 `POLend`，不提供 sweep。`claimResidual` 永久可领，不能用 owner sweep 或 last claimer 规则改变用户残值分配。

#### 7.1 用户级 floor dust 统一规则

所有用户级 floor allocation 产生的 dust 永久留在相关 custody contract，不提供 sweep，不给 last claimer：

- 普通初始 `YT` dust 留在 `Launcher`
- 杠杆初始 `YT` dust 留在 `POLend`
- 普通 fee dust 留在 `Launcher`
- 普通辅助 LP dust 留在 `Launcher`
- 杠杆残值 dust 留在 `POLend`
- `PT / YT` redeem dust 留在 `Splitter`

Settlement dust reserve 不属于用户级 floor allocation dust。它只在 `executeGlobalSettlement` 中按 `settlementDustStates[uAsset].reserve` 可用余额消耗，未消耗部分继续留在该 `uAsset` 全局 reserve 池中。

该全局池无主动回收面：余额只增（`POLend.sol::fundSettlementDustReserve`）只减（bounded deficit 消耗），上限不可归零、下调不得低于当前 reserve（`POLend.sol::setMaxSettlementDustReserve`）；退役 uAsset 的未消耗余额永久滞留，唯一回收通道是协议升级。完整生命周期约束见 [core.md §6.7](core.md)。

## Dispatch

### 8. YieldDispatcher 分发路径

Memeverse DAO governor fee 无论本链还是异链，都统一经过 `YieldDispatcher`。

本链路径：

```text
Launcher / POLend 使 uAsset 到达 YieldDispatcher
Launcher 调 YieldDispatcher.distributeSameChain(
    uAsset,
    governor,
    TokenType.UASSET,
    amount
)
YieldDispatcher 调 Governor.receiveTreasuryIncome
```

`distributeSameChain` 的 `amount` 是**两桶合计**（见 `MemeverseSettlementImpl._distributeRedeemedFees` 的双桶注释），对账时不能只按「launcher 转入 dispatcher 的 `Transfer` 事件金额」核对 governor 入账，否则会漏算 PT 赎回直达桶：

- **持币桶**：launcher 物理持有的 uAsset（`govFee` 基数 + 快照的 `auxiliaryGovUAssetFee`），经 `_transferOut` 转账到 dispatcher，产生可见的 `Transfer` 事件。
- **PT 赎回直达桶**：杠杆侧 PT fee 经 `preRedeemPTFee`（settle 前）/ `redeemPT`（settle 后）兑换成 uAsset，第三参 `mintTo = YieldDispatcher`，兑换出的 uAsset **直接 mint/redeem 到 dispatcher**，不经过 launcher 余额，无 launcher→dispatcher 的 `Transfer` 事件。

链下对账 governor 的 `TreasuryIncomeRecorded` 入账时，须把两桶相加，不能仅凭 launcher→dispatcher 的 `Transfer` 金额核对。`amount` 口径的接口层同步见 `IYieldDispatcher.distributeSameChain` @dev。

异链路径：

```text
Launcher 持有待发送 uAsset
Launcher 构造 OFT SendParam
SendParam.to = remote YieldDispatcher
SendParam.composeMsg = abi.encode(governor, TokenType.UASSET)
Launcher 调 IOFT.send
LayerZero endpoint 在远端调用 YieldDispatcher.lzCompose
YieldDispatcher 调 Governor.receiveTreasuryIncome
```

最终业务接收者是 DAO governor。

`YieldDispatcher` 是 token 落点和 compose 分发器。

`POLend.protocolTreasury` 与 Memeverse DAO governor fee 没有任何关系。

## Interfaces

### 9. uAsset mint / repay 权限

每个 verse 的 `uAsset` 必须是受支持的 mint / repay / OFT 资产，由注册中心或 `Launcher` 在注册阶段保证。

`POLend` 不重复维护 supported asset 鉴权。

#### 9.1 uAsset 信任边界（无回调要求）

`uAsset` 必须是受信任且**无外部回调**语义的资产实现。

具体要求：

- `transfer / transferFrom / approve / mint / repay` 不得在执行过程中触发任意外部回调（包括但不限于对调用方、接收方、第三方 hook 的同步可重入调用）。
- 不支持带“转账钩子 / 回调执行器 / 可插拔外部逻辑”的 `uAsset` 变体作为产品资产。
- 该约束由注册中心、部署流程与治理配置共同保证；违反该约束的资产不属于本协议支持范围。

该要求是产品级前置条件，不依赖运行时检测；其目的是确保 `POLend` 与 `Launcher` 的资金路径在面对 `uAsset` 调用时不引入额外可重入攻击面。

`POLend` 必须拥有对所有 supported `uAsset` 的 mint 权限，用于：

- `finalizeLeveragedGenesis`
- settle 前 `preRedeemPTFee`

`POLend` 必须能对所有 supported `uAsset` 执行 repay，用于：

- `executeGlobalSettlement` 偿还 verseDebt
- `burnPreRedeemedBacking` 偿还预兑付 PT fee backing

最小接口：

```solidity
interface IUniversalAssets {
    function mint(address to, uint256 amount) external;
    function repay(address account, uint256 amount) external;
}
```

`uAsset` 偿还统一使用 `IUniversalAssets.repay(account, amount)` 语义：

```text
msg.sender 是债务 owner
repay(account, amount) burn account 的 uAsset
repay(account, amount) 减少 mintingStatusTable[msg.sender].amountInMinted
```

`mint(to, amount)` 增加 `mintingStatusTable[msg.sender].amountInMinted`；`repay(account, amount)` 只减少同一个 debt owner 即 `msg.sender` 的 minted amount，不减少 `account` 的 owner 额度。

`repay` 的 burn account 语义：

- `account == msg.sender` 时不需要 allowance
- `account != msg.sender` 时，`account` 必须给 `msg.sender` 足额 allowance
- `account` 余额不足、allowance 不足、或 `mintingStatusTable[msg.sender].amountInMinted < amount` 时 revert

`executeGlobalSettlement` 偿还 verseDebt：

```text
uAsset.repay(address(POLend), verseDebt)
```

POLend 自己 repay 自己持有的 recovered `uAsset` 不需要 self-approve。

`burnPreRedeemedBacking` 偿还预兑付 PT fee backing：

```text
Splitter approve POLend exact converted uAssetBacking amount
POLend calls uAsset.repay(address(splitter), amount)
```

Splitter 给 POLend 的 allowance 只在 `preRedeemedPT > 0` 时设置精确金额，用完后不为兼容未知 token 做额外 approve-to-zero。`uAsset` 由实现了 `IUniversalAssets` 的合约发行，支持非零到非零的 approve 变更。

### 10. 权限与配置

`POLend.initialize` 必须配置：

- `initialOwner`
- `defaultInterestRate`
- `leveragedDebtFactor`
- `protocolTreasury`
- `launcher`
- `splitter`
- `creditFactory`（`GenesisCreditFactory` 地址，用于按 `uAsset` 查 GenesisCredit 地址）

`protocolTreasury` 必须非零。

`creditFactory` 是可选运行态：若该 `uAsset` 未部署对应 GenesisCredit，`leveragedGenesisWithCredit` revert `NoCreditForUAsset`，正常 `leveragedGenesis` 路径不受影响。`creditFactory` setter（owner-only）emit `CreditFactoryChanged(old, new)`。

`fullPrecisionMulDiv(leveragedDebtFactor, interestRate, 1) >= 1e36`。market 注册在复制当前默认配置前校验该约束；全局配置 setter 也必须保持同一约束，保证后续注册可用。`initialize` 输入的 `leveragedDebtFactor` 还必须满足 `<= MAX_LEVERAGED_DEBT_FACTOR`，其中 `MAX_LEVERAGED_DEBT_FACTOR = uint128.max * 1e18`；超出即 `InvalidConfig`。

`setProtocolTreasury(newTreasury)`：

- 仅 owner
- `newTreasury != address(0)`
- 只影响未来杠杆利息 treasury 份额与 Launcher over-capacity funding excess 的接收地址
- 事件 `event ProtocolTreasuryChanged(address indexed oldTreasury, address indexed newTreasury);`

`setDefaultInterestRate(newRate)`：

- 仅 owner
- `0 < newRate <= 1e18`
- 使用当前 `leveragedDebtFactor` 与 `newRate` 校验 `fullPrecisionMulDiv(leveragedDebtFactor, newRate, 1) >= 1e36`
- 只影响未来注册 market
- 事件 `event DefaultInterestRateChanged(uint256 oldRate, uint256 newRate);`

`setLeveragedDebtFactor(newFactor)`：

- 仅 owner
- `newFactor != 0`
- 使用 `newFactor` 与当前 `defaultInterestRate` 校验 `fullPrecisionMulDiv(newFactor, defaultInterestRate, 1) >= 1e36`
- `newFactor <= MAX_LEVERAGED_DEBT_FACTOR`，其中 `MAX_LEVERAGED_DEBT_FACTOR = uint128.max * 1e18`；超出即 `InvalidConfig`
- 相关计算使用全精度 `mulDiv` 或等价 overflow-safe 实现；该校验不能依赖 `minTotalFund`、`totalNormalFunds` 或 `totalLeveragedInterest` 被统一限制到 `2^64 - 1`
- 只影响仍处于 `None / Genesis` 且 Launcher verse 仍处于 `Genesis` 的 market 后续 debt cap / `remainingAdditionalInterest` 计算；不改变已注册 market 利率、已 mint 债务或 `Locked / Settled / Refund` 结算 / claim 语义
- 事件 `event LeveragedDebtFactorChanged(uint256 oldFactor, uint256 newFactor);`

`setMaxSettlementDustReserve(address uAsset, uint128 maxReserve)`：

- 仅 owner
- `uAsset != address(0)`
- `maxReserve > 0`
- 按 supported `uAsset` 配置全局 reserve 总上限；setter 不通过募资参数推断 supported 状态
- 若下调上限，必须满足当前 `reserve <= maxReserve`
- 只影响之后执行的 market 注册检查、reserve credit 容量和 `executeGlobalSettlement` reserve 可用余额校验
- 事件 `event SettlementDustReserveConfigured(address indexed uAsset, uint128 oldMaxReserve, uint128 newMaxReserve);`

`fundSettlementDustReserve(address uAsset, amount)`：

- permissionless
- `amount > 0`
- 该 `uAsset` 必须已完成 reserve 配置
- 从调用者转入该 `uAsset`
- 非 `Launcher` 调用者必须在 transfer 前满足 `amount <= remaining capacity`
- `Launcher` 可以 over-capacity；credited 进入 reserve，`excess` 转入 treasury
- 不受 pause 阻断，作为 settlement dust reserve 不足时的 unlock / repay 安全出口
- 事件 `event SettlementDustReserveFunded(address indexed uAsset, address indexed funder, uint256 amount, uint256 credited, uint256 excess);`

#### 10.1 权限 / 配置矩阵

| 函数 | Caller | 状态要求 | 输入 / 零值检查 | 事件 / 配置语义 |
| --- | --- | --- | --- | --- |
| `registerLendMarket` | `Launcher` | market 未注册 | verse `uAsset` 必须有效，且 `settlementDustStates[uAsset].maxReserve > 0`；复制当前 `defaultInterestRate`，校验 `leveragedDebtFactor` 与利率约束 | 注册后利率固定;emit `LendMarketRegistered` |
| `leveragedGenesis` | 用户 | Launcher verse 为 `Genesis`；market 为 `None / Genesis` | `interestAmount > 0`；该 `uAsset` 已完成全局 reserve 配置；参与地址为 `msg.sender`，无 user-address 输入；累计 `nextTotalLeveragedInterest -> previewDebt` 预检必须同时满足 `previewDebt <= rawDebtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` | `LeveragedGenesis` |
| `leveragedGenesisWithCredit` | 用户 | Launcher verse 为 `Genesis`；market 为 `None / Genesis` | `creditAmount > 0`；该 `uAsset` 已完成全局 reserve 配置且在 `GenesisCreditFactory` 已部署对应 GenesisCredit（否则 `NoCreditForUAsset`）；参与地址为 `msg.sender`；累计 `nextTotalLeveragedInterest -> previewDebt` 预检同上（real + credit 合计吃 debt cap） | `LeveragedGenesisWithCredit` |
| `markRefundable` | `Launcher` | market 为 `Genesis` | 无金额输入 | 状态改为 `Refund`;emit `MarketRefundable` |
| `finalizeLeveragedGenesis` | `Launcher` | `Genesis -> Locked` 流程；market 为 `Genesis` | `totalLeveragedDebt > 0` | 状态改为 `Locked`，mint debt（基于合计 `totalLeveragedInterest`），真付部分 realInterest = totalLeveragedInterest - totalCreditInterest 全额转 `protocolTreasury`（credit 部分无 token 流入，跳过），burn 该 verse `totalCreditInterest` 对应的托管 GenesisCredit，emit `CreditBurned`。另无条件 emit `LeveragedGenesisFinalized`(real-only 市场 `creditBurned==0`)。finalize 不读 `maxReserve`，reserve 配置由 `registerLendMarket` 在注册时强制 |
| `recordLeveragedYT` | `Launcher` | market 为 `Locked` | `yt != address(0)`，`totalLeveragedYT > 0`，防重复 | 记录杠杆初始 `YT`;emit `LeveragedYTRecorded` |
| `preRedeemPTFee` | `Launcher` | market 为 `Locked`，Splitter 未 settled | `ptAmount > 0`，`mintTo != address(0)`，converted `uAssetBacking > 0` | `PreRedeemPTFee`，增加 debt |
| `burnPreRedeemedBacking` | `Splitter` | Splitter settle 流程 | `amount > 0`；`amount == preRedeemedPT.uAssetBacking` 由 `onlySplitter` 调用约束保证，不由 POLend 运行时校验 | 减少 debt |
| `executeGlobalSettlement` | `Launcher` | `Locked -> Unlocked` 编排；market 为 `Locked` | 只处理一次；若 `recoveredUAsset < verseDebt`，缺口必须等于实际 `deficit`，且 `<= settlementDustStates[uAsset].reserve` | 状态改为 `Settled`，只扣减实际 reserve 消耗，emit `SettlementDustReserveConsumed` 与 `GlobalSettlementExecuted` |
| `fundSettlementDustReserve` | 任意地址 | reserve 已配置；不受 pause 阻断 | `amount > 0`；非 `Launcher` 成功路径要求 `amount <= remaining capacity` | 注入该 `uAsset` 全局 settlement dust reserve，无 claim 权利 |
| `claimRefund` | 用户 | market 为 `Refund` | `to != address(0)`，有未领取利息 | 标记 `refundClaimed` |
| `claimLeveragedYT` | 用户 | market 为 `Locked / Settled` | `to != address(0)`，有未领取杠杆利息份额；四舍五入向下后 payout 可为 0 | 标记 `leveragedYTClaimed` |
| `claimResidual` | 用户 | market 为 `Settled` | `to != address(0)`，有有效利息且未领取；四舍五入向下后 payout 可为 0 | 标记 `residualClaimed` |
| `setProtocolTreasury` | owner | 任意 | `newTreasury != address(0)` | 仅影响未来杠杆利息 treasury 份额与 Launcher over-capacity funding excess 的接收地址 |
| `setDefaultInterestRate` | owner | 任意 | `0 < newRate <= 1e18`；当前 `leveragedDebtFactor` 与 `newRate` 满足杠杆约束 | 仅影响未来注册 market |
| `setLeveragedDebtFactor` | owner | 任意 | `newFactor != 0`；`newFactor <= uint128.max * 1e18`；`newFactor` 与当前 `defaultInterestRate` 满足杠杆约束 | 仅影响可继续新增杠杆创世的 `None / Genesis` market 后续 debt cap / `remainingAdditionalInterest` |
| `setMaxSettlementDustReserve` | owner | 任意 | `uAsset != address(0)`，`maxReserve > 0`，且下调时当前 `reserve <= maxReserve` | 配置该 `uAsset` 全局 settlement dust reserve 上限；不支持用 0 作为 launch-supported 运行模式 |
| upgrade authorization | owner（UUPS `_authorizeUpgrade`） | 按升级框架 | 新实现初始化与存储布局必须兼容 | 不改变既有 market 语义 |
| pause behavior | pauser / owner policy | 任意 | pause 不得阻断必要的 unlock / refund / repay 安全出口；`fundSettlementDustReserve` 视为 unlock / repay 安全出口 | pause 只限制新增资金入口和非必要领取入口。受 `whenNotPaused` 阻断的 Launcher 入口：`MemeverseLauncher.genesis`、`MemeverseLauncher.preorder`、`MemeverseLauncher.genesisAndPreorder`、`MemeverseLauncher.claimNormalYT`、`MemeverseLauncher.claimNormalFees`、`MemeverseLauncher.redeemAuxiliaryLiquidity`、`MemeverseLauncher.claimUnlockedPreorderMemecoin`、`MemeverseLauncher.redeemAndDistributeFees`、`MemeverseLauncher.mintPOLToken`、`MemeverseLauncher.registerMemeverse`。受 `whenNotPaused` 阻断的 POLend 入口：`POLend.leveragedGenesis`、`POLend.leveragedGenesisWithCredit`。不受 pause 阻断的安全出口：`POLend.claimRefund`、`POLend.claimLeveragedYT`、`POLend.claimResidual`、`POLend.fundSettlementDustReserve`、`POLend.executeGlobalSettlement`、`POLSplitter.redeemPT`、`POLSplitter.redeemYT`、`POLSplitter.settle` |

#### 10.2 输入校验矩阵

| 入口 | 必要校验 |
| --- | --- |
| `genesis` | `amount > 0`，`user != address(0)` |
| `preorder` | `amount > 0`，`user != address(0)`，`totalPreorderFunds + amount <= preorderCap` |
| `redeemPT` | `amount > 0`，`to != address(0)` |
| `redeemYT` | `amount > 0`，`to != address(0)` |
| `leveragedGenesis` | `interestAmount > 0`；该 `uAsset` 已完成全局 reserve 配置；参与地址为 `msg.sender`，无 user-address 输入；累计 `nextTotalLeveragedInterest -> previewDebt` 必须同时满足 `previewDebt <= rawDebtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` |
| `leveragedGenesisWithCredit` | `creditAmount > 0`；该 `uAsset` 已完成全局 reserve 配置且 `GenesisCreditFactory` 已部署对应 GenesisCredit；参与地址为 `msg.sender`；累计 `nextTotalLeveragedInterest -> previewDebt` 预检同 `leveragedGenesis` |
| `claimResidual` | 用户有有效利息且未领取时可标记 claimed，即使向下取整后的 payout 为 0 |
| `getUserLeveragedDebt` | `user != address(0)`，`ZeroInput`；market 未注册时 `InvalidState` |
| `getTotalDebtByUAsset` | `uAsset != address(0)`，`ZeroInput` |

### 11. Target ABI

本节区分 deployment / proxy 初始化 ABI 与 runtime integration ABI。

`initialize(...)` 是 proxy 初始化入口，用于部署编排和升级工具，不属于 Launcher / POLend / POLSplitter 运行期集成接口。`IPOLend` 与 `IPOLSplitter` 表达 runtime integration ABI；若部署脚本需要强类型 initializer，可使用单独的 initializer-only interface，不能把初始化入口误解为 per-verse 产品动作。

`POLend` deployment / proxy 初始化 ABI：

```solidity
function initialize(address initialOwner, uint256 interestRate_, uint256 leveragedDebtFactor_, address treasury_, address launcher_, address splitter_, address creditFactory_) external;
```

`POLend` runtime integration ABI：

```solidity
function registerLendMarket(uint256 verseId) external;
function leveragedGenesis(uint256 verseId, uint256 interestAmount) external returns (uint256 borrowedAmount);
function leveragedGenesisWithCredit(uint256 verseId, uint256 creditAmount) external returns (uint256 borrowedAmount);
function setCreditFactory(address creditFactory) external;
function markRefundable(uint256 verseId) external;
function finalizeLeveragedGenesis(uint256 verseId) external;
function recordLeveragedYT(uint256 verseId, address yt, uint256 totalLeveragedYT) external;
function preRedeemPTFee(uint256 verseId, uint256 ptAmount, address mintTo) external returns (uint256 uAssetBacking);
function burnPreRedeemedBacking(uint256 verseId, uint256 amount) external;
function executeGlobalSettlement(uint256 verseId) external;
function fundSettlementDustReserve(address uAsset, uint256 amount) external;
function claimRefund(uint256 verseId, address to) external returns (uint256 refundedAmount);
function claimLeveragedYT(uint256 verseId, address to) external returns (uint256 amount);
function claimResidual(uint256 verseId, address to) external returns (uint256 uAssetAmount, uint256 memecoinAmount);
function setProtocolTreasury(address newTreasury) external;
function setDefaultInterestRate(uint256 newRate) external;
function setLeveragedDebtFactor(uint256 newFactor) external;
function setMaxSettlementDustReserve(address uAsset, uint128 maxReserve) external;
function pause() external;
function unpause() external;
function getLendMarket(uint256 verseId) external view returns (LendMarket memory);
function getTotalLeveragedDebt(uint256 verseId) external view returns (uint256);
function getUserLeveragedDebt(uint256 verseId, address user) external view returns (uint256);
function getLeveragedDebtInfo(uint256 verseId) external view returns (LeveragedDebtInfo memory);
function getTotalDebtByUAsset(address uAsset) external view returns (uint256);
function getTotalLeveragedInterest(uint256 verseId) external view returns (uint256);
function getTotalCreditInterest(uint256 verseId) external view returns (uint256);
function settlementDustStates(address uAsset) external view returns (uint128 reserve, uint128 maxReserve);
```

`POLSplitter` deployment / proxy 初始化 ABI：

```solidity
function initialize(address initialOwner, address launcher) external;
```

`POLSplitter` runtime integration ABI：

```solidity
function initializeVerse(uint256 verseId, address pol, address memecoin, address uAsset, string calldata name, string calldata symbol) external returns (address pt, address yt);
function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external;
function split(uint256 verseId, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount);
function merge(uint256 verseId, uint256 amount) external returns (uint256 polAmount);
function settle(uint256 verseId) external returns (uint256 settlementUAsset, uint256 settlementMemecoin);
function preRedeemPTFee(uint256 verseId, uint256 ptAmount) external returns (uint256 uAssetBacking);
function redeemPT(uint256 verseId, uint256 ptAmount, address to) external returns (uint256 uAssetAmount);
function redeemYT(uint256 verseId, uint256 ytAmount, address to) external returns (uint256 uAssetAmount, uint256 memecoinAmount);
function previewPTToUAsset(uint256 verseId, uint256 ptAmount) external view returns (uint256 uAssetAmount);
function previewRedeemYTUAsset(uint256 verseId, uint256 ytAmount) external view returns (uint256 uAssetAmount);
function getPT(uint256 verseId) external view returns (address pt);
function getYT(uint256 verseId) external view returns (address yt);
function getMemecoin(uint256 verseId) external view returns (address memecoin);
function getPTAndYT(uint256 verseId) external view returns (address pt, address yt);
function getPTSettlementState(uint256 verseId) external view returns (address pt, bool settled);
function getPOLAndMemecoin(uint256 verseId) external view returns (address pol, address memecoin);
function splitInfos(uint256 verseId) external view returns (address pt, address yt, address pol, address memecoin, address uAsset, uint256 totalPOLCollateral, uint256 settlementUAsset, uint256 settlementMemecoin, uint256 ptBackingNumerator, uint256 ptBackingDenominator, bool settled);
function getPTAndYTAndPOL(uint256 verseId) external view returns (address pt, address yt, address pol);
function launcher() external view returns (address);
function polend() external view returns (address);
```

`POLSplitter.initialize` 是 proxy 初始化入口，不是 per-verse 产品动作：

- 只在 proxy 初始化时调用一次
- `initialOwner != address(0)`
- `launcher != address(0)`
- 写入 `launcher`
- 初始化 `PrincipalToken / YieldToken` implementation
- 必须先于任何 `initializeVerse / split / settle / redeem` 路径完成

`MemeverseSettlementImpl` 是 delegatecall-only sibling：无 owner 入口、无独立业务入口，由 facade `src/verse/MemeverseLauncher.sol` 经 delegatecall 调用。七个 facade 入口与 sibling selector 一一对应：`refund`→`refund`、`refundPreorder`→`refundPreorder`、`claimNormalYT`→`claimNormalYT`、`claimNormalFees`→`claimNormalFees`、`claimUnlockedPreorderMemecoin`→`claimUnlockedPreorderMemecoin`、`redeemAndDistributeFees`→`collectAndDistributeFees`、`changeStage`（经 `MemeverseLaunchImpl::changeStage` dispatcher 的 Locked 分支嵌套 delegatecall）→`unlockFromLocked`。runtime integration ABI（`IMemeverseSettlementImpl`）：

```solidity
function refund(uint256 verseId) external returns (uint256 genesisFund);
function refundPreorder(uint256 verseId) external returns (uint256 preorderFund);
function claimNormalYT(uint256 verseId) external returns (uint256 amount);
function claimNormalFees(uint256 verseId) external returns (uint256 uAssetAmount, uint256 ptAmount);
function claimUnlockedPreorderMemecoin(uint256 verseId) external returns (uint256 amount);
function collectAndDistributeFees(uint256 verseId, address rewardReceiver, address polSplitter) external payable returns (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward, bool hadFees);
function unlockFromLocked(uint256 verseId, address polSplitter, address hook) external;
```

- `collectAndDistributeFees` 标记 `payable`：跨链路径把 `msg.value` 作为 LayerZero native fee 消耗；`hadFees == false` 标识无 fee 早返回路径，facade 据此 gate `RedeemAndDistributeFees` 的 emit。
- `_captureLockedAuxiliaryFees` 是 §1.3 / §4 描述的 Locked→Unlocked 辅助池 fee 捕获逻辑，经 `unlockFromLocked` 入口在 stage 翻转前调用。

`MemeverseFeePreviewReader` 是独立 view 合约：无 owner gating，持有 immutable `PROXY`（Launcher proxy 地址），runtime 只 staticcall proxy getter。runtime integration ABI（`IMemeverseFeePreviewReader`）：

```solidity
function previewGenesisMakerFees(uint256 verseId) external view returns (uint256 uAssetFee, uint256 memecoinFee);
function quoteDistributionLzFee(uint256 verseId) external view returns (uint256 lzFee);
```

- `quoteDistributionLzFee` 在治理链为本链时返回 `0`。
