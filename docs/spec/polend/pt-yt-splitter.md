# POLend PT/YT Splitter

本文件覆盖 POLSplitter 的 PT/YT 生命周期（`recordPTBackingRatio` / `split` / `merge` / `preview`）、settle 编排与 PT/YT 兑付。POLend 子系统整体导航见 [polend/README.md](README.md)。

## 1. PT / YT 生命周期

`POLSplitter.initializeVerse`：

- 只由 `Launcher` 调用
- 每个 `verseId` 只能调用一次
- 在 `Genesis -> Locked`、四池部署前调用
- 从 `Launcher` 传入 `pol / memecoin / uAsset / name / symbol`
- 创建该 verse 的 `PT / YT`
- 绑定该 verse 的 `uAsset / memecoin / pol / pt / yt`
- 允许纯普通创世调用

`POLSplitter.recordPTBackingRatio`：

- 只由 `Launcher` 调用
- 每个 `verseId` 只能调用一次
- 只能在 `POLSplitter.initializeVerse` 后调用
- 必须在任何 `split / preRedeemPTFee / redeemPT / redeemYT` 路径前调用
- `numerator > 0`
- `denominator > 0`
- 记录 `ptBackingNumerator = numerator` 与 `ptBackingDenominator = denominator`
- `numerator` 必须等于 Router 执行后主池实际消耗的 `uAsset` raw amount，不得直接使用 bootstrap budget `mainUAssetFunds`
- 不 mint、burn 或转移 token

`split / merge`：

- 只在 `POLSplitter.initializeVerse` 后开放
- 只在 `recordPTBackingRatio` 后开放
- 只在 `settled=false` 时开放
- 只在 Launcher verse 尚未 `Unlocked` 时开放
- `Locked` 阶段可继续 `split / merge`
- `settle` 执行后关闭（`settle` 在 `Locked -> Unlocked` 转换交易内执行）
- `split(0)` 与 `merge(0)` revert `ZeroInput`

这意味着 `PT/YT` 不只在 `Locked` 初始部署时 mint。用户在 `Locked` 期间仍可主动 `split POL` 得到新的 `PT/YT`。

后续主动 split 得到的 `PT/YT`：

- 直接转移到 split 用户地址
- 不进入普通/杠杆初始 claim 账本
- `Unlocked` 后与其他 `PT/YT` 一样从 `Splitter` 结算池兑付

`PT/YT` 的 burn 权限只授予 `Splitter`。

`redeemPT / redeemYT` 由 `Splitter` burn `msg.sender` 持有的 token，不需要 approve。

`Splitter.preRedeemPTFee` 只用于固定 burn `Launcher` 持有的杠杆侧 PT fee，不接受任意 account 作为 burn 来源，也不需要 `Launcher` approve。

`Splitter` 必须暴露并使用 PT raw -> uAsset backing raw 的 preview：

```text
previewPTToUAsset(verseId, ptAmount) = FullMath.mulDiv(ptAmount, ptBackingNumerator, ptBackingDenominator)
```

所有 `preRedeemPTFee`、`redeemPT`、`redeemYT` 的 PT reserve、settle 时预兑付 backing burn、`POLend.executeGlobalSettlement` 回收 PT settlement 都必须使用该转换后的 `uAsset` 数量，不得直接把 `ptAmount` 当作 `uAsset` 数量。

`mintPOLToken` 在 `Locked` 后继续 mint 新 POL 时，不再执行运行时 `InvalidPOLBacking` 风格的 strict backing equality 检查。

当前产品规则是：

- fixed PT backing ratio 仍由启动时记录的 `ptBackingNumerator / ptBackingDenominator` 定义
- `mintPOLToken` 继续走 exact-liquidity minting
- 若报价后的实际执行无法 mint 出请求的 LP/POL 数量，则整笔 mint fail closed
- 不存在一个单独的“bootstrap 式 underbacking”运行时豁免路径，也不存在一个允许额外 backing 改写 PT/YT 经济的路径

## 2. POLSplitter settle

`settle` 语义：

```text
settled = true                     （重入守卫，在外部调用前设置）
burn POL collateral
-> 得到 totalRedeemedUAsset + settlementMemecoin
-> 若 preRedeemedPT > 0：
     preRedeemedUAssetBacking = preRedeemedPT.uAssetBacking
     Splitter approve 该 verse uAsset 给 POLend，金额为 preRedeemedUAssetBacking
     POLend repay Splitter 持有的 preRedeemedUAssetBacking
     settlementUAsset = totalRedeemedUAsset - preRedeemedUAssetBacking
     delete preRedeemedPT
-> 写入 settlementUAsset / settlementMemecoin
```

`totalRedeemedUAsset` 表示 burn `POL collateral` 后赎回出的全部 `uAsset`，尚未扣除已预兑付 `PT fee` backing。

`preRedeemedPT` 逻辑上是 `{ ptAmount, uAssetBacking }` 结构，包含 `Locked` 阶段主动分发时已经预兑付给 Memeverse DAO governor 路径的杠杆侧 PT fee raw 数量及其固定 ratio 转换后的 backing。不得用两个互不关联的 mapping 表达该状态。

> **代码实现说明：** 代码中 `preRedeemedPT(verseId)` 是便利 getter，仅返回 `ptAmount`（`uint256`）；完整的 `{ ptAmount, uAssetBacking }` 结构体通过 `preRedeemedStates(verseId)` 访问，返回 `PreRedeemedState`。

`preRedeemedPT` 不包含：

- 普通用户领取到地址上的 PT fee
- 普通用户后续 `redeemPT`
- `executeGlobalSettlement` 后真实 `redeemPT`
- `src/verse/MemeverseSettlementImpl.sol::_captureLockedAuxiliaryFees` 捕获进 `pendingAuxiliaryGovFeeStates.pendingPTFee` 的 PT fee

不变量：

```text
preRedeemedPT.uAssetBacking <= totalRedeemedUAsset
totalRedeemedUAsset >= preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())
settlementUAsset >= previewPTToUAsset(PT.totalSupply())
```

这些不变量由以下产品设计保证：

- settle 时 burn 全部 POL collateral 赎回底层 uAsset
- `PT` 按固定 backing ratio 预留 `uAsset`
- settle 前，`preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())` 是 still-held POL collateral 需要覆盖的固定 PT backing
- settlement 必须满足 `totalRedeemedUAsset >= preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())`
- 扣除 `preRedeemedPT.uAssetBacking` 后，才能推出 `settlementUAsset >= previewPTToUAsset(PT.totalSupply())`

自然产品路径的安全依赖主池 POL 回收满足上述 solvency / backing invariant：

- `Locked` 阶段 `preRedeemPTFee` 的 `PT fee` 必须来自真实 `PT` supply，不能凭空生成。
- `Splitter.preRedeemPTFee` 固定 burn `Launcher` 持有的该部分 `PT`，并记录 `{ ptAmount, uAssetBacking }`。
- 被 burn 的 `PT` 已经从后续 `PT.totalSupply()` 中移除；settlement 只需要继续为剩余 `PT.totalSupply()` 保留 backing。
- settle 中扣 `preRedeemedPT.uAssetBacking` 不是重复扣 backing，而是把已经提前 mint / distributed 给 governor 路径的 backing 从 `totalRedeemedUAsset` 中结清 / repay。
- 结清后必须满足 `settlementUAsset >= previewPTToUAsset(PT.totalSupply())`。

### 2.1 INV-18 验证结果

[INV-18](../invariants.md#inv-18-pt-settlement-backing-偿还不变量) 已按真实产品路径验证，不接受任意 mocked settlement 数字作为结论依据。

验证结论是产品模型 / 不变量证据，不是任意 mocked settlement 数字推演：

- 初始与 `Locked` 后新增的 `PT` 都来自真实 `split(POL)`。
- `preRedeemPTFee` burn 的是 `Launcher` 实际持有的真实 `PT`，因此 `preRedeemedPT.uAssetBacking` 对应的 backing 需求已从后续 `PT.totalSupply()` 中移除。
- 成功 settlement 的既有不变量是：先偿还 `preRedeemedPT.uAssetBacking`，偿还后剩余 `settlementUAsset` 继续覆盖 `previewPTToUAsset(PT.totalSupply())`。
- 对应关系为：

```text
totalRedeemedUAsset >= preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())
settlementUAsset = totalRedeemedUAsset - preRedeemedPT.uAssetBacking
settlementUAsset >= previewPTToUAsset(PT.totalSupply())
```

验证证据：

- `forge test --match-path test/verse/MemeverseLauncherPOLendSettlementInvariant.t.sol --match-test 'testRealPathFundBasedAmountAboveOneCoversSettlementPTBacking|testRealPathLockedPreRedeemPTFeeSettlementBacking|testRealPathMixedFundsCoversSettlementDustAndLeavesNormalAuxiliaryRemainder' -vv` 通过 3 个测试。
- `forge test --match-contract MemeverseLauncherPOLendSettlementStdInvariantTest -vv` 通过 7 个 invariant 测试。
- 其中 `invariant_successfulSplitterSettlementBacksPTSupply` 明确验证 successful splitter settlement 后剩余 `PT.totalSupply()` 仍被足额 backing。

因此，`preRedeemedPT.uAssetBacking > totalRedeemedUAsset` 或 `totalRedeemedUAsset < preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())` 只能来自以下破坏：

- `PT fee` 不是从真实 `PT` supply 转入并被 burn，而是被伪造。
- 主池 `POL -> uAsset` 回收低于固定 PT backing 总需求，形成 solvency / backing boundary failure。

上述两类都不是合法自然产品路径，不能作为 `settle` 的正常业务分支。若后续有真实产品路径 / router 数学被证明会产生 `totalRedeemedUAsset < preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())`，该情形属于 solvency / boundary failure；它不能被归类为 `preRedeemPTFee` deficit，也不能被归类为 settlement dust。处理该边界需要单独的显式 enforcement 决策 / guard，不能按正常流程静默接受。

不作为正常业务分支处理。

`settlementMemecoin` 不受 `preRedeemedPT` 影响。

settle 后：

- `redeemPT / redeemYT` 开放
- `split / merge` 关闭

错误命名：

- `AlreadyUnlocked`：`split / merge` 已关闭（verse 已 Unlocked 或 settle 已完成）
- `NotUnlocked`：`settle` 阶段不正确（verse 尚未 Unlocked）
- `NotSettled`：redeem 前尚未 settle
- `AlreadyDeployed`：`initializeVerse` 重复调用
- 不保留 `InsufficientSettlementUAsset`

## 3. PT / YT 兑付

### 3.1 redeemPT

`redeemPT`：

- 只在 `settled=true` 后开放
- 允许任意 `PT` 持有人调用
- `to` 可指定接收地址
- `ptAmount = 0` revert `ZeroInput`
- burn `msg.sender` 的 `PT`
- `uAssetAmount = previewPTToUAsset(verseId, ptAmount)`
- 若 `ptAmount > 0` 但 `uAssetAmount == 0`，revert，不得 burn PT
- `settlementUAsset -= uAssetAmount`
- 向 `to` 转出 `uAssetAmount`
- 不需要 approve
- 不额外读取 `PT.totalSupply()`
- 不使用 `preRedeemedPT`

公式：

```text
uAssetAmount = FullMath.mulDiv(ptAmount, actualMainUAssetUsed, ptBackingDenominator)
```

### 3.2 redeemYT

`redeemYT`：

- 只在 `settled=true` 后开放
- 允许任意 `YT` 持有人调用
- `to` 可指定接收地址
- `ytAmount = 0` revert `ZeroInput`
- 不需要 approve
- 必须先用本次扣减前状态计算，再 burn

计算：

```text
outstandingYT = YT.totalSupply()
reservedUAssetForPT = previewPTToUAsset(verseId, PT.totalSupply())
ytRedeemableUAssetPool = settlementUAsset - reservedUAssetForPT

uAssetAmount = ytRedeemableUAssetPool * ytAmount / outstandingYT
memecoinAmount = settlementMemecoin * ytAmount / outstandingYT
```

若 `uAssetAmount == 0 && memecoinAmount == 0`，必须在 burn YT 前 revert，不得销毁无法兑付任何输出的 YT。

执行顺序：

```text
1. 用 burn 前状态计算 uAssetAmount 和 memecoinAmount
2. burn YT
3. settlementUAsset -= uAssetAmount
4. settlementMemecoin -= memecoinAmount
5. transfer uAssetAmount + memecoinAmount to
```

`outstandingYT = 0` 时 revert。

`redeemYT` 不得动 PT 本金准备金。

`redeemPT / redeemYT` 的整数舍入 dust 永久留在 `Splitter`，不设计 sweep。
