# MemeverseV2 跨模块不变量（产品真相层）

## 1. 说明

本文只记录跨模块不变量（跨合约/跨子系统），用于测试与审计。  
标签说明：

- `[代码已证]`：可直接由当前 `src/**` 证明
- `[未知]`：仓库内缺少部署级证据

## 2. 不变量清单

### INV-01 注册写入链路是单入口

- 约束：`MemeverseLauncher.registerMemeverse(...)` 只能由 `memeverseRegistrar` 调用；注册中心与 registrar 只能作为上游入口。`[代码已证]`
- 价值：保证 verse 创建不会被任意地址绕过中心化校验路径。
- 主要锚点：`src/verse/MemeverseLauncher.sol::registerMemeverse`，`src/verse/registration/MemeverseRegistrarAbstract.sol::_registerMemeverse`，`src/verse/registration/MemeverseRegistrationCenter.sol::registration`

### INV-02 `memecoin -> verseId` 映射在注册时建立且后续不重写

- 约束：注册时写入 `memecoinToIds[memecoin] = uniqueId`，后续无 setter 可改该映射。`[代码已证]`
- 价值：跨模块按 memecoin 反查 verse 的主键语义稳定。
- 主要锚点：`src/verse/MemeverseLauncher.sol::registerMemeverse`

### INV-03 治理链统一取 `omnichainIds[0]`

- 约束：launcher 费用分发与 interoperation staking 都把 `omnichainIds[0]` 解释为治理链。`[代码已证]`
- 价值：避免“治理链”在不同模块使用不同索引。
- 主要锚点：`src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees`（费用分发治理链分支：同链/跨链分流依据 `omnichainIds[0] == block.chainid`），`src/verse/MemeverseLaunchImpl.sol::_deployAndSetupMemeverse`（部署期治理链落地），`src/interoperation/MemeverseOmnichainInteroperation.sol::quoteMemecoinStaking`（staking 治理链）

### INV-04 启动结算必须走显式 `Launcher -> Hook` 结算路径

- 约束：
  - Launcher 在 preorder 结算时直接使用已配置且 write-once 的 `memeverseUniswapHook`，并显式调用 `executePreorderSettlement(...)`。`[代码已证]`
  - Hook 侧要求 `msg.sender == launcher`，不再依赖 Router 特殊 `hookData` marker 或双调用者兼容接线。`[代码已证]`
  - Executor 侧要求 `msg.sender == HOOK`（constructor 时 immutable 绑定的 hook proxy 地址），并额外校验入参 `params.key.hooks == HOOK`；不信任 caller-supplied `key.hooks`。`[代码已证]`
  - Launcher 配置 router / hook 时会做 set-time 三重校验：`router.hook() == hook`、`hook.launcher() == launcher`、`hook.poolInitializer() == router`；同时 launcher 侧 hook 绑定是 write-once。`Genesis -> Locked` 执行建池前会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
  - Launcher bootstrap 四池创建使用 desired budgets 作为计划输入，实际进入主池和辅助池的 token 数量以后续 actual spend 为准。`[代码已证]`
  - bootstrap auxiliary pool creation 以 actual spend 记账，不因 auxiliary underspend 本身触发单独的 bootstrap backing / equality guard，也不依赖单独文档化的 rounding-envelope accept/reject 规则。unused bootstrap `uAsset` 走 settlement dust reserve / treasury excess 路径，unused bootstrap `memecoin` 走 burn。`[目标规范]`
- 价值：防止任意调用者伪造启动结算路径，并避免 router / hook / launcher 绑定失配或 unlock 保护漂移到错误 hook namespace；同时杜绝任意地址冒充 hook（通过伪造 caller-supplied `key.hooks`）触发 settlement swap 抽走 executor 持有的 `netInput`——回调型 token（ERC-777/1363）作 `currencyIn` 时尤其关键，否则 `executePreorderSettlement` 内的 `transferFrom` 会触发攻击者重入 executor。
- 主要锚点：`src/verse/libraries/MemeverseLauncherLib.sol::validateSettlementWiring`，`src/swap/MemeverseUniswapHook.sol::executePreorderSettlement`，`src/swap/MemeversePreorderSettlementExecutor.sol::execute`、`::HOOK`，`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`（内部 delegatecall `MemeverseLiquidityImpl.sol::deployBootstrapLiquidity`）
- 设计假设：executor 是无状态合约——settlement 外不应持有任何 token 余额；settlement 资金由 launcher 通过 `transferFrom` 注入，结算完成后 executor 余额归零。无 sweep 函数，外部误转入的 token 将永久锁定。

### INV-04A 预购结算 executor 路径完整性保障

- 约束：
  - transient executor marker 在 `executor.execute()` 调用前通过 `setPreorderSettlementExecutor(address(executor))` 写入，调用后通过 `setPreorderSettlementExecutor(address(0))` 清除；marker 覆盖整个 executor 调用窗口，包括嵌套的 poolManager 回调。`[代码已证]`
  - `_beforeSwap` 仅在 `sender == isExpectedPreorderSettlementExecutor(sender)` 时跳过 public-swap fee 路径；攻击者通过回调型 token（ERC-777/1363）重入时 `sender` 为攻击者地址，不匹配 marker，走正常收费路径。`[代码已证]`
  - Hook 从自身 fee rate（`protocolFeeBps`）与 executor 返回的实际 `swapDelta` 重算 output-side protocol fee（`expectedProtocolFeeOutputAmount`），与 executor 自报的 `protocolFeeOutputAmount` 必须严格一致，否则 revert `PreorderSettlementFeeMismatch`。`[代码已证]`
- 价值：防止 executor 结算路径上的重入攻击与 fee 伪造——transient marker 阻断攻击者重入走 fee-neutral 路径，fee 自洽校验防止 executor 报告虚假 output-side fee。
- 主要锚点：`src/swap/libraries/MemeverseTransientState.sol::setPreorderSettlementExecutor`、`::isExpectedPreorderSettlementExecutor`，`src/swap/MemeverseUniswapHook.sol::executePreorderSettlement`（marker set/clear + fee mismatch check），`src/swap/MemeverseUniswapHook.sol::_beforeSwap`（sender 门）

### INV-05 Locked 费用分发恒等式

- 约束：主池 `memecoin/uAsset` 的 `uAssetFee = executorReward + govFee`，其中 `executorReward` 必须按 full-precision `mulDiv` 或等价 overflow-safe 语义计算：`fullPrecisionMulDiv(uAssetFee, executorRewardRate, 10000)`，`govFee = uAssetFee - executorReward` 且减法保持 checked arithmetic 语义；quote/redeem 路径必须共享同一分账算术语义。主池 `memecoin` fee 进入 yield 路径。辅助池 fee 按 POLend 四池目标规则分流：POL fee burn，普通侧 `uAsset/PT` fee 进入普通领取账本，杠杆侧 `uAsset` fee 进入 governor treasury 路径，杠杆侧 `PT` fee 在 settle 前按固定 PT backing ratio 预兑付或 settle 后 redeem 后分发。`[目标规范]`
- 价值：保证主池与辅助池 fee 分账守恒、burn 顺序和 PT fee pending/settle 语义可审计。
- 主要真源：[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)，[docs/spec/verse/accounting.md](verse/accounting.md)

### INV-06 远端分发与远端 staking 要求 `msg.value` 精确匹配报价

- 约束：跨链分发与跨链 staking 都不是“至少足额”，而是“严格等于报价”。`[代码已证]`
- 价值：调用方与脚本必须先 quote，再按精确值提交交易。
- 主要锚点：`src/verse/MemeverseLauncher.sol::redeemAndDistributeFees`，`src/interoperation/MemeverseOmnichainInteroperation.sol::memecoinStaking`

### INV-07 关键业务动作受阶段机约束

- 约束：`genesis/preorder` 仅 `Genesis`；`refund/refundPreorder` 仅 `Refund`；`claimNormalYT/claimNormalFees/mintPOLToken/redeemAndDistributeFees` 至少 `Locked`；LP 赎回仅 `Unlocked`。`[代码已证]`
- 约束：Router/Hook 的 ERC20 payout helper 都对 `recipient == address(0)` fail-close；`removeLiquidity(...)`、`removeLiquidityWithPermit2(...)` 与 Hook fee payout 不允许把代币发送到零地址。`[代码已证]`
- 价值：跨模块资金动作不会越阶段执行。
- 主要锚点：`src/verse/MemeverseLauncher.sol::genesis`，`::preorder`，`::refund`，`::refundPreorder`，`::changeStage`，`::claimNormalYT`，`::claimNormalFees`

### INV-07A Locked -> Unlocked 结算与公开 swap 保护必须同交易落地

- 约束：`changeStage()` 执行 `Locked -> Unlocked` 时，完整原子编排（共 5 步：`_captureLockedAuxiliaryFees` → `verse.currentStage = Unlocked` → `POLSplitter.settle` → 可选 `POLend.executeGlobalSettlement` → 写入 `publicSwapResumeTime`）见 [docs/spec/polend/settlement-and-fees.md §4](polend/settlement-and-fees.md)；本不变式保证该 5 步全部在同一次解锁迁移的同一笔交易内原子落地，避免 settlement 与保护窗口出现时间分叉。其中 `publicSwapResumeTime = block.timestamp + UNLOCK_PROTECTION_WINDOW`（窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md)）；hook-side public swap protection 自该写入后生效，由 `hook.beforeSwap` 按 pool-level `publicSwapResumeTime` 阻断公开 swap。该 settlement callback window 不由 launcher-side transient gate 或已生效的公开 swap block 保护。进入 `Unlocked` 后，赎回可用性由阶段与各函数自身条件决定。`[代码已证]`
- 价值：保证全局结算状态与受保护池公开 swap 恢复时间锚定同一次解锁迁移，避免 settlement 与保护窗口出现时间分叉。
- 主要锚点：`src/verse/MemeverseLaunchImpl.sol::changeStage` 的 `Locked -> Unlocked` 分支（delegatecall 入 `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked`）、POLSplitter/POLend settlement 调用、hook 公开 swap 恢复时间写入路径；完整 5 步顺序以 [docs/spec/polend/settlement-and-fees.md §4](polend/settlement-and-fees.md) 为单一事实源

### INV-08 Router/Hook 只操作动态费池且固定 tickSpacing

- 约束：Router 构造的池 key 固定 `LPFeeLibrary.DYNAMIC_FEE_FLAG` 与 `tickSpacing=200`；Hook 初始化也要求同样约束。`[代码已证]`
- 价值：防止同一对资产被错误路由到非预期费率池。
- 主要锚点：`src/swap/MemeverseSwapRouter.sol::_hookPoolKey`，`src/swap/MemeverseUniswapHook.sol::_beforeInitialize`

### INV-09 代币增发权限集中在 Launcher

- 约束：`Memecoin.mint`、`MemePol.mint`、`MemePol.setPoolId` 仅 launcher 可调用。`[代码已证]`
- 价值：保证发行与 LP 凭证配置只通过 launcher 生命周期执行。
- 主要锚点：`src/token/Memecoin.sol::mint`，`src/token/MemePol.sol::onlyMemeverseLauncher (modifier)`，`src/token/MemePol.sol::setPoolId`，`src/token/MemePol.sol::mint`

### INV-10 OFT compose 回调具备 replay 防护

- 约束：`YieldDispatcher` 与 `OmnichainMemecoinStaker` 都在 endpoint 路径下检查 `guid` 未执行，再标记执行。`[代码已证]`
- 价值：跨链到账处理不可重复记账。
- 主要锚点：`src/verse/YieldDispatcher.sol::lzCompose`，`src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`

### INV-11 注册时间权威值来自注册中心写入

- 约束：launcher 不自行重算 `endTime/unlockTime`，以 registrar 传入值为准；本地报价读取注册中心 `DAY`，中心写入为最终来源，并写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`。`[代码已证]`
- 价值：链上最终时间语义由中心写入决定，报价仅供参考。
- 主要锚点：`src/verse/MemeverseLaunchImpl.sol::_storeRegisteredMemeverse`，`src/verse/registration/MemeverseRegistrarAtLocal.sol::FIXED_LOCKUP_DURATION (constant)`，`src/verse/registration/MemeverseRegistrarAtLocal.sol::quoteRegister`，`src/verse/registration/MemeverseRegistrationCenter.sol::DAY (constant)`，`src/verse/registration/MemeverseRegistrationCenter.sol::registration`

### INV-12 解锁后必须先经过保护窗口，再恢复公开 swap

- 约束：`Locked -> Unlocked` 同交易 settlement 顺序与公开 swap 恢复时间写入的机械口径已并入 INV-07A；本条仅保留该窗口的存在性论证与产品安全理由。窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md) `UNLOCK_PROTECTION_WINDOW`。
- 价值：保证 POL / genesis liquidity 的赎回公平性，并为 POL Lend / PT-YT 语义提供一致的全局结算窗口。
- 违反后果：先行动者可通过先赎回并抛售底层资产，把损失外部化给后续赎回者，造成用户重大亏损。`[产品安全要求]`
- 当前实现状态：保护窗口没有单独阶段，而是通过 `Stage.Unlocked + hook 按 pool-level resume time 阻断公开 swap` 落地；赎回路径与公开 swap 可用性由不同模块分离控制。保护窗口为固定产品常量，不再存在 owner 配置面。`[代码已证]`
- 主要锚点：`src/verse/MemeverseSettlementImpl.sol::UNLOCK_PROTECTION_WINDOW`，`src/verse/MemeverseSettlementImpl.sol::_activatePostUnlockPublicSwapProtection`，`src/swap/MemeverseUniswapHook.sol::_beforeSwap`，`src/swap/MemeverseUniswapHook.sol::_revertIfPublicSwapBlocked`，`src/swap/MemeverseUniswapHook.sol::PublicSwapDisabled (error)`

### INV-13 POLend 全局结算只能用 bounded reserve 覆盖 dust

- 约束：`settlementDustStates[uAsset].reserve <= settlementDustStates[uAsset].maxReserve` 必须始终成立。`maxReserve == 0` 表示该 `uAsset` 未完成 POLend reserve 配置，`POLend.registerLendMarket` 必须拒绝使用该 `uAsset` 的 verse。`[目标规范]`
- 约束：`POLend.executeGlobalSettlement(verseId)` 的债务偿还必须满足 `recoveredUAsset + consumedSettlementDustReserve >= verseDebt`。若 `recoveredUAsset < verseDebt`，则 `consumedSettlementDustReserve == verseDebt - recoveredUAsset`，且必须满足 `consumedSettlementDustReserve <= reserveBeforeSettlement`，其中 `reserveBeforeSettlement` 是执行前读取的 `settlementDustStates[uAsset].reserve` 快照。settlement 成功后只扣减实际消耗量，不清零该 `uAsset` 的全局 reserve。`[目标规范]`
- 约束：settlement dust reserve 只来自 `fundSettlementDustReserve(address,uint256)` 手动注入、Launcher bootstrap unused `uAsset` 注入；不得通过 mint、残值扣减、普通侧 LP 扣减或 treasury 隐式透支产生。`[目标规范]`
- 约束：settlement dust reserve 只覆盖正确执行 `previewPTToUAsset` 固定 backing ratio 转换后的整数舍入 dust；不得覆盖 PT backing ratio / 模型错误。`[目标规范]`
- 约束：bootstrap pre-LP residual `POL/PT` 与普通 auxiliary LP split dust 是两个不同类别。前者必须先按 funding share 切分：`leveragedShare = floor(totalResidual * totalLeveragedDebt / totalGenesisFunds)`，`normalShare = totalResidual - leveragedShare`；不能把它们当成永久 launcher bucket 或未分类 dust。`[目标规范]`
- 价值：C1 只允许 wei 级整数舍入缺口通过 reserve 解决，不把真实资不抵债、价格模型错误、PT backing ratio 错误或资金流错误伪装成 dust。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)

### INV-14 POLend PT raw 与 uAsset backing 必须分离

- 约束：raw-unit identity 固定为 `POL raw = main pool LP raw`，`PT raw = POL raw`，`YT raw = POL raw`。`1 raw PT` 不等于 `1 raw uAsset`。`PT` 的 uAsset backing 必须使用 verse 固定 ratio：`FullMath.mulDiv(ptAmount, ptBackingNumerator, ptBackingDenominator)`。`[目标规范]`
- 约束：`preRedeemPTFee`、`redeemPT`、`redeemYT` 的 PT reserve、settle 时预兑付 backing burn、`POLend.executeGlobalSettlement` 回收 PT settlement 都必须使用转换后的 `uAsset` 数量，不得直接用 `ptAmount`。`[目标规范]`
- 约束：主池 PT backing ratio 的记录口径是“主池实际执行 spend / 主池实际产出的 POL raw amount”，不是 bootstrap 想要的 budget 或内部 quote budget。`[代码已证]`
- 约束：`mintPOLToken` 不再执行运行时 `InvalidPOLBacking` 式严格等式校验。产品仍要求固定 PT backing ratio 不被改写，并要求 exact-liquidity minting 在报价后若无法 mint 出请求的 LP/POL 数量时 fail closed。`[目标规范]`
- 价值：保证 `fundBasedAmount > 1` 等自然路径下 PT/YT 经济不被 raw 数量误当 uAsset 数量破坏。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)

### INV-15 预兑付 PT fee 必须由真实 PT supply 结清

- 约束：`Locked` 阶段 `preRedeemPTFee` 的 `PT fee` 必须来自真实 `PT` supply；`Splitter.preRedeemPTFee` 必须 burn `Launcher` 持有的该部分 `PT`，并记录同一笔 `{ ptAmount, uAssetBacking }`。`[目标规范]`
- 约束：被 burn 的 `PT` 必须从后续 `PT.totalSupply()` 中移除；settlement 只为剩余 `PT.totalSupply()` 保留 backing。`settle()` 中扣 `preRedeemedPT.uAssetBacking` 是把已经提前 mint / distributed 给 governor 路径的 backing 从 `totalRedeemedUAsset` 中结清 / repay，不是重复扣 backing。`[目标规范]`
- 约束：settlement 必须满足 `totalRedeemedUAsset >= preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())`；扣除 `preRedeemedPT.uAssetBacking` 后，才推出 `settlementUAsset >= previewPTToUAsset(PT.totalSupply())`。自然产品模型下，`preRedeemedPT.uAssetBacking > totalRedeemedUAsset` 或主池 `POL -> uAsset` 回收低于固定 PT backing 总需求属于 solvency / backing boundary failure，必须 revert / 被测试捕获，不能归类为合法预兑付缺口，也不是由 `preRedeemPTFee` 自身制造。`[目标规范]`
- 约束：`src/verse/MemeverseSettlementImpl.sol::_captureLockedAuxiliaryFees` 在 unlock transaction 捕获的 pending `PT fee` 不进入 `preRedeemedPT`；该 `PT fee` 在 settled 后走 `redeemPT`，不得增加 settle 前扣减。`[目标规范]`
- 价值：保证提前分发给 governor 路径的 PT backing 与 settlement 结清一一对应，防止把伪造 supply 或主池回收不足解释为合法预兑付缺口。
- 测试证据：`testRealPathLockedPreRedeemPTFeeSettlementBacking` 覆盖 `genesis + leveragedGenesis -> Locked -> mintPOLToken -> split -> real PT transferred to hook -> redeemAndDistributeFees -> preRedeemPTFee -> unlock settlement`。
- 主要真源：[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)

### INV-16 normal fee entitlement 与 zero-backing dust 必须保持可领取语义

- 约束：普通侧 `claimNormalFees` 计算 `entitledUAsset` 与 `entitledPT` 时必须使用 full-precision `mulDiv`，不能因中间乘法溢出把已可表示的累计账本变成不可领取。`[代码已证]`
- 约束：普通侧 PT fee 在 `settled=false` 时直接转 `PT`；在 `settled=true` 时改走 `previewPTToUAsset -> redeemPT -> uAsset`。若 `previewPTToUAsset(...) == 0`，本次不得把该 PT 份额标记为已领，而要保持未领取状态等待后续重试。`[代码已证]`
- 约束：governor 路径的 `pending auxiliary gov PT fee` 也必须遵守同样的 zero-backing 保留语义；可分发的其它 `uAsset/memecoin/POL` fee 不因此被阻断。`[代码已证]`
- 价值：保证 normal fee 账本在大数情况下可领取，并保证 settling 后的 PT dust 不会被错误吞掉或提前记为已处理。
- 主要锚点：`src/verse/MemeverseLauncher.sol::claimNormalFees`，`src/verse/MemeverseSettlementImpl.sol::_mergePendingAuxiliaryGovFees`

### INV-17 创世总资金聚合上限必须保持累计且排除 preorder

- 约束：成功部署资金口径固定为 `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt`，且不包含 preorder。`[目标规范]`
- 约束：`MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max`，并且必须始终满足 `totalGenesisFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`。`[目标规范]`
- 约束：成功 `genesis` / `leveragedGenesis` 写入后都必须保持上述 aggregate cap；其中 `leveragedGenesis` 写入前必须按累计 `nextTotalLeveragedInterest = totalLeveragedInterest + interestAmount` 推导 `previewDebt`，并同时满足 `previewDebt <= debtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，不能只检查当前调用 delta。`[目标规范]`
- 价值：保证普通创世与杠杆创世共享同一聚合资金上限，避免成功写入把总创世资金推进到不支持的数值域。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)，[docs/spec/verse/accounting.md](verse/accounting.md)，[docs/spec/verse/lifecycle-details.md](verse/lifecycle-details.md)

### INV-18 PT settlement backing 偿还不变量

- 约束：POLend settlement 必须先偿还 `preRedeemedPT.uAssetBacking`，偿还后剩余 `settlementUAsset` 必须继续覆盖 `previewPTToUAsset(PT.totalSupply())`。完整 solvency 不变量为：`[目标规范]`

```text
totalRedeemedUAsset >= preRedeemedPT.uAssetBacking + previewPTToUAsset(PT.totalSupply())
settlementUAsset = totalRedeemedUAsset - preRedeemedPT.uAssetBacking
settlementUAsset >= previewPTToUAsset(PT.totalSupply())
```

- 约束：settlement 前扣 `preRedeemedPT.uAssetBacking` 不是重复扣 backing，而是把已经提前 mint / distributed 给 governor 路径的 backing 从 `totalRedeemedUAsset` 中结清 / repay；结清后才推出 `settlementUAsset >= previewPTToUAsset(PT.totalSupply())`。`[目标规范]`
- 约束：自然产品路径下，`preRedeemedPT.uAssetBacking > totalRedeemedUAsset` 或主池 `POL -> uAsset` 回收低于固定 PT backing 总需求属于 solvency / backing boundary failure，必须 revert / 被测试捕获，不能归类为合法预兑付缺口。`[目标规范]`
- 价值：把"settlement 偿还顺序与剩余 solvency"作为独立可审计不变量收口，避免被拆成多个分散陈述；保证预兑付 backing 与 settlement 结清一一对应。
- 去重关系：本条与 INV-15（预兑付 PT fee 必须由真实 PT supply 结清）共享同一 solvency 公式与 `preRedeemedPT` 结清语义。INV-15 聚焦"PT fee 来源真实性"，本条聚焦"settlement 偿还顺序与剩余覆盖"。两者交叉引用，不互相替代。
- 主要真源：[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)

### INV-19 PT backing ratio 实际额约束

- 约束：PT backing ratio 必须基于主池 Router / AMM 实际执行结果，而不是基于期望预算。若 Router 或 AMM 在主池创建过程中退回未使用的 bootstrap `uAsset` / `memecoin`，该未使用部分不计入 PT backing。`[目标规范]`
- 约束：`POLSplitter.recordPTBackingRatio(verseId, numerator, denominator)` 记录的 `numerator = mainPoolUAssetUsed` 必须是主池实际执行 spend，`denominator = mainPoolPOLAmount` 必须是 launch 实际 mint 出来的 main pool LP/POL raw amount，不能使用预估值或 bootstrap budget。`[代码已证]`
- 约束：auxiliary pool actual spend 低于 desired budget 形成的未使用 bootstrap `uAsset` 必须按 §6.7 注入 POLend settlement dust reserve / treasury excess 路径，未使用 bootstrap `memecoin` 必须 burn。`[目标规范]`
- 价值：把"PT backing 只能认实际执行额"作为独立 invariant 收口，避免 backing ratio 被预算/quote 数字污染导致 PT 经济失真。
- 去重关系：本条与 INV-14（POLend PT raw 与 uAsset backing 必须分离）共享"实际执行口径"语义——INV-14 约束 3 已规定记录口径为"主池实际执行 spend / 主池实际产出的 POL raw amount"。本条进一步聚合 genesis 部署时序（[genesis.md §5.2](polend/genesis.md)）中 PT backing 实际额规则的完整约束集（含未使用资金处置）。未使用 `uAsset` 处置见 INV-13 约束 3，未使用 `memecoin` burn 见 INV-04 约束 5。本条作为聚合锚点，不替代上述 INV。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)

### INV-20 返佣偿付能力与 protocol fee 拆分守恒

- 约束（偿付能力）：对每个 rebate currency `c`，`MemeverseDynamicFeeEngine` 在 `c` 下的 ERC20 余额必须始终 ≥ Σ 所有 referrer 的 `pendingRebate[r][c]`。`accrueRebate` 是纯记账（`pendingRebate[referrer][currency] += amount` + emit，无 PoolManager 调用）；rebate token 由 hook 在 `_collectProtocolFee` 内 `poolManager.take(feeCurrency, address(engine), rebate)` 拉到 engine 地址（token 进 engine custody，v4 `PoolManager.take` delta 记调用者 hook，被 beforeSwap specifiedDelta credit 抵消），先于 `accrueRebate` 记账，因此 accrual 不破坏偿付能力；`claimRebate` 清零 `pendingRebate[r][c]` 后再 external transfer（CEI），transfer 失败 revert 保证账本与余额同步。唯一破坏路径是 engine pointer 替换（`upgradeDynamicFeeEngine`）——旧 engine 的 `pendingRebate` 不迁移到新 engine，但旧 engine 仍独立部署、其 `claimRebate` 不经 hook，存量 rebate 仍可对旧 engine 领取，因此偿付能力对旧 engine 仍成立（只是不再增长）。`[代码已证]`
- 约束（fee 拆分守恒）：每次普通 swap 的 protocol fee 必须满足 `lpFee + toTreasury + rebate = totalFee`，其中 `toTreasury = protocolFee - rebate`、`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（有 referrer 且 `referrerRebateBps != 0` 时；否则 rebate = 0）。等价地 `ProtocolFeeCollected.amount（on hook, = toTreasury） + ReferralRebateAccrued.amount（on engine, = rebate） = protocolFee`。无 referrer 时只有 `ProtocolFeeCollected` 且 amount = 完整 protocolFee。舍入方向：`protocolFee = FeeMath.feeOnAmount(amount, protocolFeeBps)`（内部 `FullMath.mulDiv` 向下取整），`rebate = FullMath.mulDiv(protocolFee, rebateBps, PROTOCOL_FEE_SHARE_BPS)` 也向下取整；两级向下舍入对 referrer 不利、treasury 受益（`toTreasury = protocolFee - rebate` 在 checked 减法下吸收 rebate 的向下舍入差）。守恒等式按链上 emit 的舍入后 amount 成立，不是按理论无限精度 ratio 成立。`[代码已证]`
- 约束（上限）：`referrerRebateBps <= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`），否则 `setReferrerRebateBps` revert `RebateExceedsProtocolShare`；保证单次 swap 的 rebate ≤ protocolFee，不会透支 protocol share。`[代码已证]`
- 约束（coverage）：返佣只在普通 swap（`_beforeSwap` / `_afterSwap` 的 4 个 `_collectProtocolFee` 调用点）触发；preorder settlement（`executePreorderSettlement`）不携带 referrer，其 `ProtocolFeeCollected.amount` 仍是完整 protocolFee，不参与守恒等式的 rebate 项。`[代码已证]`
- 价值：保证返佣 custody 与 LP fee / treasury 收入严格隔离且守恒；索引器 / 财务对账按 swap 维度统计 protocol 总收入时必须把 `ProtocolFeeCollected` 与 `ReferralRebateAccrued` 求和，否则漏计 rebate。
- 主要锚点：`src/swap/libraries/FeeMath.sol::PROTOCOL_FEE_SHARE_BPS`、`::splitFeeBps`；`src/swap/MemeverseUniswapHook.sol::_decodeReferrer`、`::_collectProtocolFee`、`::_takeToTreasury`；`src/swap/MemeverseDynamicFeeEngine.sol::accrueRebate`、`::claimRebate`、`::setReferrerRebateBps`、`::RebateExceedsProtocolShare`

### INV-21 GenesisCredit 利息分栏与混池 burn 会计不变量

- 约束（real/credit 分栏存储）：用户级杠杆利息按来源分两栏独立累加，互不扣减：`leveragedInterestPaid[verseId][user]`（真付 uAsset 利息，`leveragedGenesis` 路径，字段名复用旧名承载 real 部分）与 `creditInterestPaid[verseId][user]`（GenesisCredit 抵扣利息，`leveragedGenesisWithCredit` 路径）；同一用户对同一 verse 可同时累积两栏。`[代码已证]`
- 约束（market 级合计与切分）：`market.totalLeveragedInterest` 保留为 real + credit 合计存储；`market.totalCreditInterest` 独立累计 credit 利息；real 部分用差值推导 `realInterest = market.totalLeveragedInterest - market.totalCreditInterest`。`totalCreditInterest` / `totalLeveragedInterest` 都是只增累计量，refund 路径不扣减（用 `refundClaimed` 防重复）。`[代码已证]`
- 约束（每 verse 上限）：对每个 verse，必须始终满足 `market.totalLeveragedInterest >= market.totalCreditInterest`。若该不变量被破坏，差值推导的 `realInterest` 会下溢或得到非真实 token 流入量，破坏 treasury 清扫与 burn 量。`[代码已证]`
- 约束（finalize burn 量）：`POLend.finalizeLeveragedGenesis(verseId)` 必须把该 verse 托管的 GenesisCredit burn 掉，burn 量精确等于该 verse 的 `market.totalCreditInterest`（不是 `totalLeveragedInterest`，也不是用户级 `creditInterestPaid` 的链上动态求和）。`[代码已证]`
- 约束（状态机互斥保证混池 burn 安全）：`POLend.markRefundable` 与 `POLend.finalizeLeveragedGenesis` 都 `require market.state == Genesis` 并分别迁移到 `Refund` / `Locked` 终态；状态机互斥保证同一 verse 的 refund 与 finalize 不会都发生。POLend 对某 `uAsset` 的 GenesisCredit 托管余额是该 `uAsset` 所有 verse 的 credit 利息合计（混池），因此 finalize 时刻该 verse 的 `totalCreditInterest` 仍精确等于其未退走的 GenesisCredit 托管量，按 `market.totalCreditInterest` burn 不会误烧其他 verse 的份额。`[代码已证]`
- 约束（pro-rata claim 路径读合计）：`claimLeveragedYT` 切 YT 份额、`claimResidual` 的权益基数若依赖用户杠杆利息，必须读 `leveragedInterestPaid + creditInterestPaid` 合计（与 `getUserLeveragedDebt` 合计口径一致）；存储层拆栏、view/pro-rata-claim 层合计。`[代码已证]`
- 约束（claimRefund 原路径原币退回，不走合计）：`claimRefund` 是物理隔离的 split routing，不读合计——real 部分按 `leveragedInterestPaid[verseId][msg.sender]` 退该 verse 的 `uAsset`，credit 部分按 `creditInterestPaid[verseId][msg.sender]` 退 `market.creditToken`（GenesisCredit）；两条分栏各自独立、互不串读（与 genesis.md §4 一致）。混池下 POLend 对某 `uAsset` 的 GenesisCredit 托管余额仅来自各 verse 的 credit 利息合计，不含 real 利息（real 利息以 `uAsset` 形式付入，未进 credit token 托管池）；若 credit 退款误读合计（`realPaid + creditPaid`）会从其他用户/verse 的托管份额多付 credit token。`[代码已证]`
- 约束（credit 路径不产生 token 流入）：`leveragedGenesisWithCredit` 的 `GenesisCredit.transferFrom(msg.sender, POLend, creditAmount)` 只移动 GenesisCredit token；不 mint 该 verse 的 `uAsset`，不增加该 `uAsset` 的 `globalDebtByUAsset`（mint 只在 `finalizeLeveragedGenesis` 基于合计 `totalLeveragedInterest` 统一发生）；故 credit 利息在 finalize 时无对应 `uAsset` token 流入，必须跳过 treasury 清扫。`[代码已证]`
- 约束（credit token 地址锁定）：`market.creditToken` 在该 verse 首次 `leveragedGenesisWithCredit` 时缓存 `GenesisCreditFactory.creditOf(uAsset)` 解析结果；此后 `finalizeLeveragedGenesis` 的 burn 与 `claimRefund` 的退 credit 必须读 `market.creditToken` 缓存值，不重新解析 `creditFactory` 指针。这锁定 credit token 身份，防止 `setCreditFactory` 中途变更（owner-only）导致 finalize / claimRefund 解析到 `address(0)`（静默 burn no-op + 假事件）或不同 token（烧错 token / 退款 revert）。门控于“本次实际需要 burn/退 credit”：`finalizeLeveragedGenesis` 仅当 verse 级 `market.totalCreditInterest != 0` 时、`claimRefund` 仅当调用方级 `creditInterestPaid[verseId][msg.sender] != 0` 时，才检查 `market.creditToken`；此时若读到 `address(0)`（defense-in-depth 分支，正常路径不可达——有 credit 参与的 verse 在首次 `leveragedGenesisWithCredit` 即写入缓存，finalize/claimRefund 时必已填），必须 revert `NoCreditForUAsset`，绝不静默跳过 burn/退款。real-only 情形（verse 级 `totalCreditInterest == 0` / 调用方级 `creditInterestPaid == 0`）不进入此分支，正常退 `uAsset` / 跳过 burn，不触发该 revert。`[代码已证]`
- 约束（credit / uAsset 单位一致性）：`market.totalCreditInterest` 能与真付 `uAsset` 利息 raw-unit 同栏并入 `totalLeveragedInterest`、参与 launch gate / debt 推导 / YT / residual 分配，前提是 GenesisCredit 与该 verse `uAsset` 同 raw-unit 会计口径。当前 GenesisCredit 固定 18 decimals，故 credit path 只支持 `uAsset.decimals() == 18`。`GenesisCreditFactory.deployCredit` 必须拒绝非 18-dec `uAsset`（revert `InvalidUAssetDecimals`）；`leveragedGenesisWithCredit` 在该 verse 首次解析 credit token 的流程内（经 `creditOf(uAsset)` 取得地址后、写入 `market.creditToken` 缓存前）校验 `uAsset` 与 GenesisCredit 均为 18 decimals，不满足时 revert `CreditDecimalsMismatch`。非 18-dec `uAsset` 仍可走普通 `genesis` / `leveragedGenesis`，但不得启用 credit path。若该约束被破坏（例如非 18-dec `uAsset` 通过错误配置接入 credit path），`1e18` raw credit 会被当作 `1e18` raw uAsset 利息，导致 debt / launch gate / YT / residual 权益按错误数量级计算。
- 价值：保证 GenesisCredit 抵扣路径与正常杠杆路径的会计对齐、债务推导守恒、treasury 清扫只对真实 token 流入执行，并保证混池 burn 量精确隔离到单 verse。
- 去重关系：本条与 [docs/spec/polend/core.md §6.3](polend/core.md) 共享同一分栏存储语义——core.md 聚焦"字段定义与 refund 不扣减口径"，本条聚焦"作为不变量的会计等式与状态机互斥保证"。两者交叉引用，不互相替代。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)，[docs/spec/polend/genesis.md](polend/genesis.md)，[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)
- credit token 地址锁定锚点：`src/polend/POLend.sol::leveragedGenesisWithCredit`（缓存写入）、`::finalizeLeveragedGenesis`（读缓存 burn）、`::claimRefund`（读缓存退 credit）；`src/polend/interfaces/IPOLend.sol::LendMarket.creditToken`
- 分栏存储锚点：`src/polend/POLend.sol::leveragedInterestPaid`（real 部分分栏，字段名复用旧名）、`::creditInterestPaid`（credit 抵扣分栏）

## 3. 确定性边界

- 高确定性：以上不变量均有函数级源码锚点。
- `[未知]`：生产环境是否额外加多签/时锁/脚本守护进程，不在仓库源码证据范围内。
