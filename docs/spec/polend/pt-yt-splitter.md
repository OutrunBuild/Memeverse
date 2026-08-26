# POLendUpgradeable PT/YT Splitter

本文件覆盖 POLSplitterUpgradeable 的 PT/YT 生命周期（`recordPTBackingRatio` / `split` / `merge` / `preview`）、settle 编排与 PT/YT 兑付。POLendUpgradeable 子系统整体导航见 [polend/README.md](README.md)。

## 1. PT / YT 生命周期

`POLSplitterUpgradeable.initializeVerse`：

- 只由 `Launcher` 调用
- 每个 `verseId` 只能调用一次
- 在 `Genesis -> Locked`、四池部署前调用
- 从 `Launcher` 传入 `pol / memecoin / uAsset / name / symbol`
- 创建该 verse 的 `PT / YT`
- 绑定该 verse 的 `uAsset / memecoin / pol / pt / yt`
- 允许纯普通创世调用

`POLSplitterUpgradeable.recordPTBackingRatio`：

- 只由 `Launcher` 调用
- 每个 `verseId` 只能调用一次
- 只能在 `POLSplitterUpgradeable.initializeVerse` 后调用
- 必须在任何 `split / preRedeemPTFee / redeemPT / redeemYT` 路径前调用
- `numerator > 0`
- `denominator > 0`
- 记录 `ptBackingNumerator = numerator` 与 `ptBackingDenominator = denominator`
- `numerator` 必须等于 Router 执行后主池实际消耗的 `uAsset` raw amount，不得直接使用 bootstrap budget `mainUAssetFunds`
- 不 mint、burn 或转移 token

`split / merge`：

- 只在 `POLSplitterUpgradeable.initializeVerse` 后开放
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

`PT / YT` 合约是 `SplitterToken`（`PrincipalToken` / `YieldToken` 继承它）。`SplitterToken.initialize(name, symbol, splitter)` 把 `splitter` 设为 `mint / burn` 的唯一授权地址（`onlySplitter` 修饰符）；`POLSplitterUpgradeable.initializeVerse` 为每个 verse 部署 PT/YT 实例时把自身设为该 `splitter`，因此只有 `POLSplitterUpgradeable` 能 mint/burn 用户持有的 PT/YT。`SplitterToken` 不继承 `OutrunOwnableInit`，PT/YT 无 owner 角色、无 `transferOwnership`、不可升级；访问控制仅由 `splitter` 字段 + `onlySplitter` 修饰符承担。

`Splitter.preRedeemPTFee` 只用于固定 burn `Launcher` 持有的杠杆侧 PT fee，不接受任意 account 作为 burn 来源，也不需要 `Launcher` approve。

`Splitter` 必须暴露并使用 PT raw -> uAsset backing raw 的 preview：

```text
previewPTToUAsset(verseId, ptAmount) = Math.mulDiv(ptAmount, ptBackingNumerator, ptBackingDenominator)
```

`Splitter` 的 YT preview 语义：

- `POLSplitterUpgradeable.sol::previewRedeemYTUAsset` 在 settle 前恒返回 0（settle 前 `settlementUAsset` 未写入，YT 可赎回池定义上为 0，与 `outstandingYT == 0` 的零返回同族）
- settle 后才按 §3.2（即本文件「PT / YT 兑付」节的公式 `ytRedeemableUAssetPool = settlementUAsset - reservedUAssetForPT`）计算

所有 `preRedeemPTFee`、`redeemPT`、`redeemYT` 的 PT reserve、settle 时预兑付 backing burn、`POLendUpgradeable.executeGlobalSettlement` 回收 PT settlement 都必须使用该转换后的 `uAsset` 数量，不得直接把 `ptAmount` 当作 `uAsset` 数量。

`mintPOLToken` 在 `Locked` 后使用 exact-liquidity minting。fixed PT backing ratio 由启动时记录的 `ptBackingNumerator / ptBackingDenominator` 定义；报价后的实际执行必须 mint 出请求的 LP/POL 数量，否则整笔 mint fail closed（exact 模式，`amountOutDesired != 0` 时适用；`amountOutDesired == 0` 的自动模式不设该 fail-close）。额外 backing 不得改写该 PT/YT 经济关系。

### 1.1 PT/YT 克隆模板与换代（setTokenImplementations）

`POLSplitterUpgradeable.initialize` 在 proxy 初始化时部署默认 `PrincipalToken` / `YieldToken` 模板并写入 `principalTokenImplementation` / `yieldTokenImplementation` 指针（同名 getter 暴露）；`POLSplitterUpgradeable.initializeVerse` 每次调用都现读这两个 storage 指针，以 `cloneDeterministic(bytes32(verseId))` 为该 verse 克隆 PT/YT。

owner 可经 `POLSplitterUpgradeable.sol::setTokenImplementations` 成对原子替换两个模板指针（一次调用同时换 PT 与 YT，避免同一 verse 混用两代模板）。链上校验仅覆盖：两个地址均 `!= address(0)`（违反 revert `ZeroInput`）且 `code.length > 0`（违反 revert `TokenImplementationCodeNotReady`）。

替换只影响**之后** `initializeVerse` 创建的 verse：已存在的 per-verse PT/YT clone 是 EIP-1167 minimal proxy，克隆时即固化模板地址，永久指向旧模板，无迁移路径。多代 PT/YT 并存是设计边界，不是缺陷。

新模板的 ABI 兼容责任在 owner：模板必须实现 `SplitterToken.initialize(name, symbol, splitter)`、onlySplitter `mint` / `burn` 与完整 ERC20 表面（clone 走 delegatecall 路径，链上无 ABI 检查）。执行该操作的 owner 应为多签。

替换成功 emit：

```solidity
event TokenImplementationsUpdated(address oldPrincipalToken, address oldYieldToken, address newPrincipalToken, address newYieldToken);
```

该 setter 复用既有 `principalTokenImplementation` / `yieldTokenImplementation` storage 字段，零新增 storage。

## 2. POLSplitterUpgradeable settle

`settle` 语义：

```text
settled = true                     （重入守卫，在外部调用前设置）
burn POL collateral
-> 得到 totalRedeemedUAsset + settlementMemecoin
-> 若 preRedeemedPT > 0：
     preRedeemedUAssetBacking = preRedeemedPT.uAssetBacking
     Splitter approve 该 verse uAsset 给 POLendUpgradeable，金额为 preRedeemedUAssetBacking
     POLendUpgradeable repay Splitter 持有的 preRedeemedUAssetBacking
     settlementUAsset = totalRedeemedUAsset - preRedeemedUAssetBacking
     delete preRedeemedPT
-> 写入 settlementUAsset / settlementMemecoin
```

`totalRedeemedUAsset` 表示 burn `POL collateral` 后赎回出的全部 `uAsset`，尚未扣除已预兑付 `PT fee` backing。

`preRedeemedPT` 逻辑上是 `{ ptAmount, uAssetBacking }` 结构，包含 `Locked` 阶段主动分发时已经预兑付给 Memeverse DAO governor 路径的杠杆侧 PT fee raw 数量及其固定 ratio 转换后的 backing。不得用两个互不关联的 mapping 表达该状态。

> **代码实现说明：** `preRedeemedPT` 是逻辑状态名（`{ ptAmount, uAssetBacking }` 结构）；代码通过 `preRedeemedStates(verseId)` 访问完整 `PreRedeemedState` 结构体，标量 `ptAmount` 经 `.ptAmount` 字段读取。

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

（solvency 公式与 `preRedeemedPT.uAssetBacking` 结清语义见 §2 与 [docs/spec/invariants.md](../invariants.md) INV-15/INV-18）

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
- `TokenImplementationCodeNotReady`：`setTokenImplementations` 目标模板地址无代码
- 统一 revert `InvalidClaim`

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
uAssetAmount = Math.mulDiv(ptAmount, actualMainUAssetUsed, ptBackingDenominator)
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
