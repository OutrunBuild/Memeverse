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
  - Hook 侧要求 `msg.sender == launcher`，preorder settlement 权限由该 launcher-only 入口直接约束。`[代码已证]`
  - settlement logic 经 Router entry `executePreorderSettlement` delegatecall `SettlementFacet.executeSettlementLogic` 在 hook 代理地址下执行（facet 挂 `onlyViaRouter` 防 direct CALL）；netInput 经 `transferFrom(launcher, hook proxy)` 托管于 hook 代理，settle 时从 hook 自身余额结清。入口以 `if (address(params.key.hooks) != address(this)) revert HookAddressMismatch;` 显式强制 PoolKey 绑定本 hook；随后用 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)` 发起 unlock。Router 只接受当前明确支持的 raw callback kind，typed settlement returndata 原样返回并由外层逻辑一次解码，不依赖 transient routing state（见 INV-04A）。`[代码已证]`
  - Launcher 配置 router / hook 时会做 set-time 三重校验：`router.hook() == hook`、`hook.launcher() == launcher`、`hook.poolInitializer() == router`；同时 launcher 侧 hook 绑定是 write-once。`Genesis -> Locked` 执行建池前会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
  - Launcher bootstrap 四池创建使用 desired budgets 作为计划输入，实际进入主池和辅助池的 token 数量以后续 actual spend 为准。`[代码已证]`
  - bootstrap auxiliary pool creation 以 actual spend 记账，不因 auxiliary underspend 本身触发单独的 bootstrap backing / equality guard，也不依赖单独文档化的 rounding-envelope accept/reject 规则。unused bootstrap `uAsset` 走 settlement dust reserve / treasury excess 路径，unused bootstrap `memecoin` 走 burn。`[目标规范]`
- 价值：防止任意调用者伪造启动结算路径，并避免 router / hook / launcher 绑定失配或 unlock 保护漂移到错误 hook namespace；netInput 托管在 hook 代理。settlement swap 是 hook self-call，v4 不执行其 swap callbacks；回调型 token 发起的外部重入 swap 不是 hook self-call，必须执行普通 callbacks 并走公开收费，无法取得 settlement fee-neutral 语义。
- 主要锚点：`src/verse/MemeverseLauncher.sol::setMemeverseUniswapHook`（write-once + `validateSettlementWiring` + `boundLauncher == address(this)`）、`src/verse/libraries/MemeverseLauncherLib.sol::validateSettlementWiring`，`src/swap/MemeverseUniswapHook.sol::executePreorderSettlement`（`onlyLauncher` entry）、`::unlockCallback`（typed discriminator dispatch），`src/swap/interfaces/IMemeverseUniswapHook.sol::UnlockCallbackKind`，`src/swap/interfaces/ISettlementFacet.sol`（typed callback structs），`src/swap/SettlementFacet.sol::executeSettlementLogic`、`::settlementUnlockCallback`，`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`（内部 delegatecall `MemeverseLiquidityImpl.sol::deployBootstrapLiquidity`）
- 设计假设：netInput 在 `executeSettlementLogic` 内拉入 hook 代理、`settlementUnlockCallback` 内经 `CurrencySettler.settle` 从 hook 自身余额结清，结算完成后 hook 代理在该 currency 下的临时余额归零。hook 代理是常驻合约，承载 LP per-share 账本、rebate 账本等持久状态；误转入 hook 代理的 token 由 hook 自身治理范围处置。

### INV-04A 预购结算 swap 路径完整性保障


- 约束（显式 typed unlock 路由 + v4 self-call 语义）：
  - 共享 Hook 接口定义 `UnlockCallbackKind { ModifyLiquidity, Settlement }`。每个 unlock caller 直接编码 `abi.encode(kind, typedStruct)`，不把 typed struct 再包进动态 `bytes` envelope。外部 `unlockCallback(bytes)` ABI 保持 v4 要求的固定签名。`[代码已证]`
  - Router 先用 calldata slice `uint256(bytes32(rawData[:32]))` 读 payload 首个 ABI word 作为 raw `uint256`，分别与 `uint256(UnlockCallbackKind.ModifyLiquidity)`、`uint256(UnlockCallbackKind.Settlement)` 比较；只在命中当前已实现值后进入对应分支。ModifyLiquidity 仍解码完整 typed tuple；Settlement 在 `SettlementCallbackData` 当前全静态前提下，kind 校验后即可切片前缀转发，无需再解码完整 typed tuple。未知值统一回退 `InvalidUnlockCallbackKind(rawKind)`，不得用 `type(UnlockCallbackKind).max` 代替“当前已支持分支”校验，也不得在支持性检查前把任意 raw 值转换为 enum。结构损坏的 payload 保持标准 ABI decode failure。`[代码已证]`
  - discriminator 读取实现：`MemeverseUniswapHook.unlockCallback` 用 calldata slice `uint256(bytes32(rawData[:32]))` 读首个 ABI word 作为 raw `uint256`（SOLC 对 `rawData[:32]` 隐式插入 length>=32 边界校验；`onlyPoolManager` 入口保证 rawData 即本合约自产 `abi.encode(UnlockCallbackKind, ...)` 的 unlock payload，length 结构性 >= 32，短数据触发隐式 revert）。后续 ModifyLiquidity 分支仍走标准 typed abi.decode，结构损坏的 payload 在该 decode 处保持标准 ABI decode failure。`[代码已证]`
  - `SettlementCallbackData` 与 `SettlementResult` 定义在 `ISettlementFacet`；`settlementUnlockCallback` 接受 typed calldata 并返回 typed result。因 `SettlementCallbackData` 当前全静态，Router 在 kind 校验后用 `bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])` 前缀转发构造 delegatecall（跳过 memory decode + 二次 encode；与 `abi.encodeCall` 字节等价），把 `_facetDelegatecall` 的原始 ABI returndata 直接作为 `unlockCallback(bytes)` 返回内容；PoolManager 原样传回，`executeSettlementLogic` 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。`[代码已证]`
  - `executeSettlementLogic` 在 unlock 前显式校验 `address(params.key.hooks) == address(this)`。其内部 swap 由 hook proxy 发起，因此 v4 同时跳过 `SwapFacet.beforeSwapLogic` 与 `SwapFacet.afterSwapLogic`；固定 1% settlement fee、LP/protocol 分账、动态状态更新与 output-side fee 扣减继续由 settlement 路径完成，不需要任何 settlement-specific transient routing slot、helper 或 error。`[代码已证]`
  - 回调型 token 在 input `transferFrom`、PoolManager settle/take 或 token transfer 期间发起的外部重入 swap，其 PoolManager caller 不是 hook proxy，不能取得 self-call skip。跨池的外部重入 swap 完整进入普通 `beforeSwap` / `afterSwap` 与 public fee 路径；**同池**的生命周期重入（outer swap 的 `beforeSwap` 已 acquire 该池的 per-pool transient lock，回调期间对同一 poolId 再次进入 `beforeSwapLogic`（在 `_revertIfPublicSwapBlocked` 校验之后）会触发 `SwapLifecycleReentrant` revert（仍在保护期内的同池重入优先回退 `PublicSwapDisabled`））被阻断。是否处于 settlement unlock 内不改变这条规则，因而不存在 hidden flag 被重入抢先消费或错误继承的问题。per-pool lock 基于 transient storage（`tstore`/`tload`），事务结束自动清除，settlement self-call 因 v4 跳过 callback 不进 `beforeSwapLogic`/`afterSwapLogic`，因此 SettlementFacet 在 `executeSettlementLogic` 内自行 `acquireSwapLifecycleLock(poolId)`（Phase 1 `transferFrom` 之前）与 `releaseSwapLifecycleLock(poolId)`（Phase 3 `_updateAfterSwap` 之后的函数末尾），覆盖 Phase 1 transferFrom → Phase 3 `_updateAfterSwap` 全窗口（含 swap → settle/take）；这样 callback token 在 settlement 的 transferFrom 窗口（Phase 1/2，pre-unlock）或 settle/take transfer 期间对同池发起的 reentrant swap 均会进入 `SwapFacet.beforeSwapLogic` 并触发 `SwapLifecycleReentrant`。transferFrom 窗口的 reenterer 通常用 try/catch 吞掉 inner revert，故外层 settlement 仍正常完成，但 inner 同池 reentrant swap 被阻断、`dynamicFeeState` 未被推进。`[代码已证]`
  - fee 自洽校验保留：当前授权的 `settlementUnlockCallback` 将 `PoolManager.swap` 返回值写入 `SettlementResult.swapDelta`；`executeSettlementLogic` 再按固定 fee rate 从该返回 delta 重算 output-side protocol fee（`expectedProtocolFeeOutputAmount`），并与 `SettlementResult.protocolFeeOutputAmount` 比较，不一致则回退 `PreorderSettlementFeeMismatch`。这是对当前授权 facet 返回字段的内部一致性检查；owner 可通过 `setFacet(SETTLEMENT_FACET_ROLE, ...)` 替换 SettlementFacet，因此它不是针对恶意或错误 owner-controlled facet replacement 的独立防线。`[代码已证]`
- 价值：callback 类型由调用数据显式决定，swap callback 是否执行由 v4 的真实 caller 规则决定；两者都可从局部输入直接验证，不依赖跨调用隐藏状态。这样既保证 settlement 自身不会重复收 public fee，也保证外部重入 swap 不能获得 fee-neutral 路径；同池生命周期重入被 per-pool lock 阻断，防止 callback token 在 outer swap 报价已固定后推进 `dynamicFeeState` 造成费率失真；typed result 与 fee 对账可检测当前授权 facet 返回的 output-side fee 字段不一致。`onlyOwner` facet replacement 仍是信任边界：恶意或错误替换可同时控制 `swapDelta` 与 `protocolFeeOutputAmount`，不由该自洽检查防住。
- 主要锚点：`src/swap/interfaces/IMemeverseUniswapHook.sol::UnlockCallbackKind`，`src/swap/interfaces/ISettlementFacet.sol::SettlementCallbackData`、`::SettlementResult`，`src/swap/MemeverseUniswapHook.sol::unlockCallback`（raw discriminator 校验与 typed dispatch），`src/swap/SettlementFacet.sol::executeSettlementLogic`、`::settlementUnlockCallback`，`lib/v4-core/src/libraries/Hooks.sol::beforeSwap`、`::afterSwap`, `src/swap/libraries/MemeverseTransientState.sol::acquireSwapLifecycleLock`、`::releaseSwapLifecycleLock`
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
- 主要锚点：`src/swap/MemeverseSwapRouter.sol::_hookPoolKey`，`src/swap/SwapFacet.sol::beforeInitializeLogic`

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
- 约束：保护窗口使用固定产品常量，并通过 `Stage.Unlocked + hook 按 pool-level resume time 阻断公开 swap` 落地；赎回路径与公开 swap 可用性由不同模块分离控制，owner 无配置入口。`[代码已证]`
- 主要锚点：`src/verse/MemeverseSettlementImpl.sol::UNLOCK_PROTECTION_WINDOW`，`src/verse/MemeverseSettlementImpl.sol::_activatePostUnlockPublicSwapProtection`（Locked→Unlocked 解算内写入），`src/swap/SwapFacet.sol::beforeSwapLogic`，`src/swap/SwapFacet.sol::_revertIfPublicSwapBlocked`，`src/swap/libraries/SwapGuardMath.sol::PublicSwapDisabled`

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
- 约束：`mintPOLToken` 以 verse 固定 PT backing ratio 与 exact-liquidity minting 的 fail-closed 语义为约束：ratio 不可改写，报价后无法 mint 出请求的 LP/POL 数量时必须 revert；该不变量不要求额外的运行时严格等式校验。`[目标规范]`
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

- 约束（偿付能力）：每笔返佣累计或领取交易成功完成后，对每个 rebate currency `c`，`MemeverseUniswapHook`(Router) 在 `c` 下的 ERC20 余额必须 ≥ Σ 所有 referrer 的 `pendingRebate[r][c]`。`pendingRebate` 与 `referrerRebateBps` 位于 hook 的 ERC7201 namespace `outrun.storage.MemeverseUniswapHook`；`pendingRebate` 账本与 LP per-share accounting 字段隔离，但共享 hook proxy 的 token custody。`SwapFacet::_settleProtocolFee` 先内联执行 `pendingRebate[referrer][currency] += amount` 并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take`（interaction），最后 emit `ProtocolFeeCollected`；记账这一步是纯 storage effect，无 PoolManager 调用、外部调用或 facet→facet delegatecall。ledger effect 先于 treasury take 与调用方的 rebate take；该顺序仅定义 CEI 的账本与交互顺序，本条余额覆盖只在返佣累计或领取交易成功完成后评估，不对执行中间点作断言。该 helper 现为严格 CEI（effect → interaction → event）：treasury take 不触发 v4 hook callback，ERC20 currency 仍会执行外部 `transfer` token 代码。安全性依赖 fee currency 为标准 ERC20（注册的协议费代币；普通池下为输入代币）、treasury 是被动收款方，以及任一 take 或 token transfer 失败时整笔事务原子回滚，账本、事件和 token 转账不会部分提交。beforeSwap 主路径将 rebate 与 LP fee 合并 take，afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。合并 take 中 LP fee 由 LP per-share accounting 独立记账，不属 rebate liability；成功交易完成后，rebate 分量与 `pendingRebate` 增量同步。`claimRebate` 清零 `pendingRebate[r][c]` 后再 external transfer（严格 CEI），transfer 失败时清零一并回滚。hook UUPS 升级必须遵守 storage 冻结约束；正常升级保留 `pendingRebate` / `referrerRebateBps`。`[代码已证]`
- 约束（费率拆分守恒，币种无关）：动态 fee 费率必须满足 `lpFeeBps + protocolFeeBps = totalFeeBps`，由 `FeeMath.splitFeeBps` 用 `protocolFeeBps = mulDiv(feeBps, PROTOCOL_FEE_SHARE_BPS, BPS_BASE)` 后 `lpFeeBps = feeBps - protocolFeeBps`（`unchecked` 减法；安全由 `PROTOCOL_FEE_SHARE_BPS < BPS_BASE` ⇒ `protocolFeeBps <= feeBps` 保证，不会下溢）保证，纯整数运算无舍入差。此约束只作用于 bps 配置层，不涉及任何 token amount。`[代码已证]`
- 约束（protocol fee 分配守恒，同币种）：`protocolFeeAmount`、`toTreasuryAmount`、`rebateAmount` 三者必须同属一个 protocol fee currency（`protocolFeeOnInput==true` 时为 input token，`==false` 时为 output token），并满足 `toTreasuryAmount + rebateAmount = protocolFeeAmount`，其中 `toTreasury = protocolFee - rebate`、`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（有 referrer 且 `referrerRebateBps != 0` 时；否则 rebate = 0）。等价地 `ProtocolFeeCollected.amount（on hook, = toTreasury） + ReferralRebateAccrued.amount（on hook, = rebate） = protocolFee`。无 referrer 时只有 `ProtocolFeeCollected` 且 amount = 完整 protocolFee。LP fee 始终以 input token 独立计量，不参与此等式；当 `protocolFeeOnInput==false` 时 LP fee 与 protocol fee 币种不同，不存在跨币种 amount 总守恒。舍入方向：`protocolFee = FeeMath.feeOnAmount(amount, protocolFeeBps)`（内部 `FullMath.mulDiv` 向下取整；例外：exact-output + `protocolFeeOnInput==false` 路径下 protocolFee 来自 beforeSwap 的 grossup 差值 `estimatedGrossOutputAmount - absSpecified`，非 `feeOnAmount`，但作为 `protocolFeeAmount` 传入 `_settleProtocolFee` 后守恒与 rebate 舍入分析与下文一致），`rebate = FullMath.mulDiv(protocolFee, rebateBps, PROTOCOL_FEE_SHARE_BPS)` 也向下取整；两级向下舍入对 referrer 不利、treasury 受益（`toTreasury = protocolFee - rebate` 在 checked 减法下吸收 rebate 的向下舍入差）。守恒等式 `rebate + toTreasury == protocolFee`（等价于上文 `ProtocolFeeCollected.amount + ReferralRebateAccrued.amount = protocolFee`），按链上 emit 的舍入后 amount 成立，不是按理论无限精度 ratio 成立；作为索引器/财务对账锚点。`[代码已证]`
- 约束（上限）：`referrerRebateBps <= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`），否则 `MemeverseUniswapHook::setReferrerRebateBps`（Router 直接实现，写 hook storage）revert `RebateExceedsProtocolShare`；保证单次 swap 的 rebate ≤ protocolFee，不会透支 protocol share。`[代码已证]`
- 约束（coverage）：返佣只在普通 swap 触发（beforeSwap 主路径 `lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0` 走 `_computeRebate` + `_settleProtocolFee` + 合并 take；beforeSwap 边界 lpFee==0、protocolFee==0、或 effectiveSupply==0（drained pool）+ afterSwap 3 点走 `_collectProtocolFee`，位于 `SwapFacet::beforeSwapLogic` / `afterSwapLogic`）；preorder settlement（`MemeverseUniswapHook::executePreorderSettlement`）不携带 referrer，其 `ProtocolFeeCollected.amount` 仍是完整 protocolFee，不参与守恒等式的 rebate 项。`[代码已证]`
- 价值：保证返佣账本字段与 LP per-share accounting 隔离、共享 hook proxy token custody、相对 treasury 地址隔离；偿付靠 hook 在各 rebate currency 下的 ERC20 余额覆盖 Σ`pendingRebate[r][c]`；且 protocol fee 守恒；索引器 / 财务对账按 swap 维度统计 protocol 总收入时必须把 `ProtocolFeeCollected` 与 `ReferralRebateAccrued` 求和，否则漏计 rebate。
- 主要锚点：`src/swap/libraries/FeeMath.sol::PROTOCOL_FEE_SHARE_BPS`、`::splitFeeBps`；`src/swap/MemeverseUniswapHook.sol::claimRebate`（Router 直接实现，CEI）、`::pendingRebateOf`（Router）、`::setReferrerRebateBps`、`::RebateExceedsProtocolShare`；`src/swap/SwapFacet.sol::beforeSwapLogic`、`::afterSwapLogic`、`::_computeRebate`（view，reb 公式）、`::_settleProtocolFee`（内联写 `pendingRebate` + emit `ReferralRebateAccrued`；`_collectProtocolFee` 与 beforeSwap 主路径均调）、`::_collectProtocolFee`（rebate take recipient = `address(this)`；`_collectProtocolFee` = `_computeRebate` + `_settleProtocolFee` + 独立 rebate take）、`::_takeToTreasury`、`::_decodeReferrer`

### INV-21 GenesisCredit 利息分栏与混池 burn 会计不变量

- 约束（real/credit 分栏存储）：用户级杠杆利息按来源分两栏独立累加，互不扣减：`leveragedInterestPaid[verseId][user]` 存储 `leveragedGenesis` 路径真付的 uAsset 利息，`creditInterestPaid[verseId][user]` 存储 `leveragedGenesisWithCredit` 路径抵扣的 GenesisCredit 利息；同一用户对同一 verse 可同时累积两栏。`[代码已证]`
- 约束（market 级合计与切分）：`market.totalLeveragedInterest` 保留为 real + credit 合计存储；`market.totalCreditInterest` 独立累计 credit 利息；real 部分用差值推导 `realInterest = market.totalLeveragedInterest - market.totalCreditInterest`。`totalCreditInterest` / `totalLeveragedInterest` 都是只增累计量，refund 路径不扣减（用 `refundClaimed` 防重复）。`[代码已证]`
- 约束（每 verse 上限）：对每个 verse，必须始终满足 `market.totalLeveragedInterest >= market.totalCreditInterest`。若该不变量被破坏，差值推导的 `realInterest` 会下溢或得到非真实 token 流入量，破坏 treasury 清扫与 burn 量。`[代码已证]`
- 约束（finalize burn 量）：`POLend.finalizeLeveragedGenesis(verseId)` 必须把该 verse 托管的 GenesisCredit burn 掉，burn 量精确等于该 verse 的 `market.totalCreditInterest`（不是 `totalLeveragedInterest`，也不是用户级 `creditInterestPaid` 的链上动态求和）。`[代码已证]`
- 约束（状态机互斥保证混池 burn 安全）：`POLend.markRefundable` 与 `POLend.finalizeLeveragedGenesis` 都 `require market.state == Genesis` 并分别迁移到 `Refund` / `Locked` 终态；状态机互斥保证同一 verse 的 refund 与 finalize 不会都发生。POLend 对某 `uAsset` 的 GenesisCredit 托管余额是该 `uAsset` 所有 verse 的 credit 利息合计（混池），因此 finalize 时刻该 verse 的 `totalCreditInterest` 仍精确等于其未退走的 GenesisCredit 托管量，按 `market.totalCreditInterest` burn 不会误烧其他 verse 的份额。`[代码已证]`
- 约束（pro-rata claim 路径读合计）：`claimLeveragedYT` 切 YT 份额、`claimResidual` 的权益基数若依赖用户杠杆利息，必须读 `leveragedInterestPaid + creditInterestPaid` 合计（与 `getUserLeveragedDebt` 合计口径一致）；存储层拆栏、view/pro-rata-claim 层合计。`[代码已证]`
- 约束（claimRefund 分栏原币退回，不走合计）：`claimRefund` 是物理隔离的 split routing，不读合计——real 部分按 `leveragedInterestPaid[verseId][msg.sender]` 退该 verse 的 `uAsset`，credit 部分按 `creditInterestPaid[verseId][msg.sender]` 退 `market.creditToken`（GenesisCredit）；两条分栏各自独立、互不串读（与 genesis.md §4 一致）。混池下 POLend 对某 `uAsset` 的 GenesisCredit 托管余额仅来自各 verse 的 credit 利息合计，不含 real 利息（real 利息以 `uAsset` 形式付入，未进 credit token 托管池）；若 credit 退款误读合计（`realPaid + creditPaid`）会从其他用户/verse 的托管份额多付 credit token。`[代码已证]`
- 约束（credit 路径不产生 token 流入）：`leveragedGenesisWithCredit` 的 `GenesisCredit.transferFrom(msg.sender, POLend, creditAmount)` 只移动 GenesisCredit token；不 mint 该 verse 的 `uAsset`，不增加该 `uAsset` 的 `globalDebtByUAsset`（mint 只在 `finalizeLeveragedGenesis` 基于合计 `totalLeveragedInterest` 统一发生）；故 credit 利息在 finalize 时无对应 `uAsset` token 流入，必须跳过 treasury 清扫。`[代码已证]`
- 约束（credit token 地址锁定）：`market.creditToken` 在该 verse 首次 `leveragedGenesisWithCredit` 时缓存 `GenesisCreditFactory.creditOf(uAsset)` 解析结果；此后 `finalizeLeveragedGenesis` 的 burn 与 `claimRefund` 的退 credit 必须读 `market.creditToken` 缓存值，不重新解析 `creditFactory` 指针。这锁定 credit token 身份，防止 `setCreditFactory` 中途变更（owner-only）导致 finalize / claimRefund 解析到 `address(0)`（静默 burn no-op + 假事件）或不同 token（烧错 token / 退款 revert）。门控于“本次实际需要 burn/退 credit”：`finalizeLeveragedGenesis` 仅当 verse 级 `market.totalCreditInterest != 0` 时、`claimRefund` 仅当调用方级 `creditInterestPaid[verseId][msg.sender] != 0` 时，才检查 `market.creditToken`；此时若读到 `address(0)`（defense-in-depth 分支，正常路径不可达——有 credit 参与的 verse 在首次 `leveragedGenesisWithCredit` 即写入缓存，finalize/claimRefund 时必已填），必须 revert `NoCreditForUAsset`，绝不静默跳过 burn/退款。real-only 情形（verse 级 `totalCreditInterest == 0` / 调用方级 `creditInterestPaid == 0`）不进入此分支，正常退 `uAsset` / 跳过 burn，不触发该 revert。`[代码已证]`
- 约束（credit / uAsset 单位一致性）：`market.totalCreditInterest` 能与真付 `uAsset` 利息 raw-unit 同栏并入 `totalLeveragedInterest`、参与 launch gate / debt 推导 / YT / residual 分配，前提是 GenesisCredit 与该 verse `uAsset` 同 raw-unit 会计口径。当前 GenesisCredit 固定 18 decimals，故 credit path 只支持 `uAsset.decimals() == 18`。`GenesisCreditFactory.deployCredit` 必须拒绝非 18-dec `uAsset`（revert `InvalidUAssetDecimals`）；`leveragedGenesisWithCredit` 在该 verse 首次解析 credit token 的流程内（经 `creditOf(uAsset)` 取得地址后、写入 `market.creditToken` 缓存前）校验 `uAsset` 与 GenesisCredit 均为 18 decimals，不满足时 revert `CreditDecimalsMismatch`。非 18-dec `uAsset` 仍可走普通 `genesis` / `leveragedGenesis`，但不得启用 credit path。若该约束被破坏（例如非 18-dec `uAsset` 通过错误配置接入 credit path），`1e18` raw credit 会被当作 `1e18` raw uAsset 利息，导致 debt / launch gate / YT / residual 权益按错误数量级计算。
- 价值：保证 GenesisCredit 抵扣路径与正常杠杆路径的会计对齐、债务推导守恒、treasury 清扫只对真实 token 流入执行，并保证混池 burn 量精确隔离到单 verse。
- 去重关系：本条与 [docs/spec/polend/core.md §6.3](polend/core.md) 共享同一分栏存储语义——core.md 聚焦"字段定义与 refund 不扣减口径"，本条聚焦"作为不变量的会计等式与状态机互斥保证"。两者交叉引用，不互相替代。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)，[docs/spec/polend/genesis.md](polend/genesis.md)，[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)
- credit token 地址锁定锚点：`src/polend/POLend.sol::leveragedGenesisWithCredit`（缓存写入）、`::finalizeLeveragedGenesis`（读缓存 burn）、`::claimRefund`（读缓存退 credit）；`src/polend/interfaces/IPOLend.sol::LendMarket.creditToken`
- 分栏存储锚点：`src/polend/POLend.sol::leveragedInterestPaid`（real 部分分栏）、`::creditInterestPaid`（credit 抵扣分栏）

## 3. 确定性边界

- 高确定性：以上不变量均有函数级源码锚点。
- `[未知]`：生产环境是否额外加多签/时锁/脚本守护进程，不在仓库源码证据范围内。
