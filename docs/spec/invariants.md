# MemeverseV2 跨模块不变量（产品真相层）

## 1. 说明

本文只记录跨模块不变量（跨合约/跨子系统），用于测试与审计。  
标签说明：

- `[代码已证]`：可直接由当前 `src/**` 证明
- `[未知]`：仓库内缺少部署级证据

## 2. 不变量清单

### INV-01 注册写入链路是单入口

- 约束：`MemeverseLauncherUpgradeable.registerMemeverse(...)` 只能由 `memeverseRegistrar` 调用；注册中心与 registrar 只能作为上游入口。`[代码已证]`
- 约束（center 侧 origin 校验绑定当前配置的 registrar 指针）：`MemeverseRegistrationCenterUpgradeable.sol::_lzReceive` 校验 `_origin.sender ==` 当前 storage 指针；该指针 owner 可经 `MemeverseRegistrationCenterUpgradeable.sol::setMemeverseRegistrar` 变更（owner-mutable）。与旧 immutable 语义等价：OApp 基座 `peers[]`（`setPeer`，onlyOwner）与 launcher 侧 registrar 指针同属 owner 信任域。`[代码已证]`
- 价值：保证 verse 创建不会被任意地址绕过中心化校验路径。
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::registerMemeverse`，`src/verse/registration/MemeverseRegistrarAbstract.sol::_registerMemeverse`，`src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol::registration`、`::_lzReceive`、`::setMemeverseRegistrar`

### INV-02 `memecoin -> verseId` 映射在注册时建立且后续不重写

- 约束：注册时写入 `memecoinToIds[memecoin] = uniqueId`，后续无 setter 可改该映射。`[代码已证]`
- 价值：跨模块按 memecoin 反查 verse 的主键语义稳定。
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::registerMemeverse`

### INV-03 治理链统一取 `omnichainIds[0]`

- 约束：launcher 费用分发与 interoperation staking 都把 `omnichainIds[0]` 解释为治理链。`[代码已证]`
- 价值：避免“治理链”在不同模块使用不同索引。
- 主要锚点：`src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees`（费用分发治理链分支：同链/跨链分流依据 `omnichainIds[0] == block.chainid`），`src/verse/MemeverseLaunchImpl.sol::_deployAndSetupMemeverse`（部署期治理链落地），`src/interoperation/MemeverseOmnichainInteroperation.sol::quoteMemecoinStaking`（staking 治理链）

### INV-04 启动结算必须走显式 `Launcher -> Hook` 结算路径

- 约束：
  - Launcher 在 preorder 结算时直接使用已配置且 write-once 的 `memeverseUniswapHook`，并显式调用 `executePreorderSettlement(...)`。`[代码已证]`
  - Hook 侧要求 `msg.sender == launcher`，preorder settlement 权限由该 launcher-only 入口直接约束。`[代码已证]`
  - settlement logic 经 Router entry `executePreorderSettlement` delegatecall `SettlementFacet.executeSettlementLogic` 在 hook 代理地址下执行（facet 挂 `onlyViaRouter` 防 direct CALL）；netInput 经 `transferFrom(launcher, hook proxy)` 托管于 hook 代理，settle 时从 hook 自身余额结清。入口以 `if (address(params.key.hooks) != address(this)) revert HookAddressMismatch;` 显式强制 PoolKey 绑定本 hook；随后用 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)` 发起 unlock。Router 只接受当前明确支持的 raw callback kind，typed settlement returndata 原样返回并由外层逻辑一次解码，不依赖 transient routing state（见 INV-04A）。`[代码已证]`
  - Launcher 配置 router / hook 时会做 set-time 三重校验：`router.hook() == hook`、`hook.launcher() == launcher`、`hook.poolInitializer() == router`；同时 launcher 侧 hook 绑定是 write-once；hook 侧 launcher 绑定同样由 initialize 一次性固化（write-once via initializer modifier），两侧对称。`Genesis -> Locked` 执行建池前会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
  - Launcher bootstrap 四池创建使用 desired budgets 作为计划输入，实际进入主池和辅助池的 token 数量以后续 actual spend 为准。`[代码已证]`
  - bootstrap auxiliary pool creation 以 actual spend 记账，不因 auxiliary underspend 本身触发单独的 bootstrap backing / equality guard，也不依赖单独文档化的 rounding-envelope accept/reject 规则。unused bootstrap `uAsset` 走 settlement dust reserve / treasury excess 路径，unused bootstrap `memecoin` 走 burn。`[目标规范]`
- 价值：防止任意调用者伪造启动结算路径，并避免 router / hook 绑定失配（launcher binding 由 initialize 固化，运行时不可偏离）；netInput 托管在 hook 代理。settlement swap 是 hook self-call，v4 不执行其 swap callbacks；回调型 token 发起的外部重入 swap 不是 hook self-call，必须执行普通 callbacks 并走公开收费，无法取得 settlement fee-neutral 语义。
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::setMemeverseUniswapHook`（write-once + `validateSettlementWiring` + `boundLauncher == address(this)`）、`src/verse/libraries/MemeverseLauncherLib.sol::validateSettlementWiring`，`src/swap/MemeverseUniswapHookUpgradeable.sol::executePreorderSettlement`（`onlyLauncher` entry）、`::unlockCallback`（typed discriminator dispatch），`src/swap/interfaces/IMemeverseUniswapHook.sol::UnlockCallbackKind`，`src/swap/interfaces/ISettlementFacet.sol`（typed callback structs），`src/swap/SettlementFacet.sol::executeSettlementLogic`、`::settlementUnlockCallback`，`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`（内部 delegatecall `MemeverseLiquidityImpl.sol::deployBootstrapLiquidity`）
- 设计假设：netInput 在 `executeSettlementLogic` 内拉入 hook 代理、`settlementUnlockCallback` 内经 `CurrencySettler.settle` 从 hook 自身余额结清，结算完成后 hook 代理在该 currency 下的临时余额归零。hook 代理是常驻合约，承载 LP per-share 账本、rebate 账本等持久状态；误转入 hook 代理的 token 由 hook 自身治理范围处置。

### INV-04A 预购结算 swap 路径完整性保障


- 约束（显式 typed unlock 路由 + v4 self-call 语义）：
  - 共享 Hook 接口定义 `UnlockCallbackKind { ModifyLiquidity, Settlement }`。每个 unlock caller 直接编码 `abi.encode(kind, typedStruct)`，不把 typed struct 再包进动态 `bytes` envelope。外部 `unlockCallback(bytes)` ABI 保持 v4 要求的固定签名。`[代码已证]`
  - Router 先用 calldata slice `uint256(bytes32(rawData[:32]))` 读 payload 首个 ABI word 作为 raw `uint256`，分别与 `uint256(UnlockCallbackKind.ModifyLiquidity)`、`uint256(UnlockCallbackKind.Settlement)` 比较；只在命中当前已实现值后进入对应分支。ModifyLiquidity 仍解码完整 typed tuple；Settlement 在 `SettlementCallbackData` 当前全静态前提下，kind 校验后即可切片前缀转发，无需再解码完整 typed tuple。未知值统一回退 `InvalidUnlockCallbackKind(rawKind)`，不得用 `type(UnlockCallbackKind).max` 代替“当前已支持分支”校验，也不得在支持性检查前把任意 raw 值转换为 enum。结构损坏的 payload 保持标准 ABI decode failure。`[代码已证]`
  - discriminator 读取实现：`MemeverseUniswapHookUpgradeable.unlockCallback` 用 calldata slice `uint256(bytes32(rawData[:32]))` 读首个 ABI word 作为 raw `uint256`（SOLC 对 `rawData[:32]` 隐式插入 length>=32 边界校验；`onlyPoolManager` 入口保证 rawData 即本合约自产 `abi.encode(UnlockCallbackKind, ...)` 的 unlock payload，length 结构性 >= 32，短数据触发隐式 revert）。后续 ModifyLiquidity 分支仍走标准 typed abi.decode，结构损坏的 payload 在该 decode 处保持标准 ABI decode failure。`[代码已证]`
  - `SettlementCallbackData` 与 `SettlementResult` 定义在 `ISettlementFacet`；`settlementUnlockCallback` 接受 typed calldata 并返回 typed result。因 `SettlementCallbackData` 当前全静态，Router 在 kind 校验后用 `bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])` 前缀转发构造 delegatecall（跳过 memory decode + 二次 encode；与 `abi.encodeCall` 字节等价），把 `_facetDelegatecall` 的原始 ABI returndata 直接作为 `unlockCallback(bytes)` 返回内容；PoolManager 原样传回，`executeSettlementLogic` 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。`[代码已证]`
  - `executeSettlementLogic` 在 unlock 前显式校验 `address(params.key.hooks) == address(this)`。其内部 swap 由 hook proxy 发起，因此 v4 同时跳过 `SwapFacet.beforeSwapLogic` 与 `SwapFacet.afterSwapLogic`；固定 1% settlement fee、LP/protocol 分账、动态状态更新与 output-side fee 扣减继续由 settlement 路径完成，不需要任何 settlement-specific transient routing slot、helper 或 error。`[代码已证]`
  - 回调型 token 在 input `transferFrom`、PoolManager settle/take 或 token transfer 期间发起的外部重入 swap，其 PoolManager caller 不是 hook proxy，不能取得 self-call skip。重入 swap 进入 `SwapFacet.beforeSwapLogic` 后，第一条 gate 是 INV-23 session 门（`activePrincipal() == address(0)` 即回退 `AccountSessionNotActive`，在 `_revertIfPublicSwapBlocked` 与 `acquireSwapLifecycleLock` 之前）；因此下述 lock/block 选择子仅在「重入 swap 发生时 session 已 active」前提下成立。在生产 normal public swap 路径中，外层 smart-EOA 账户已 `beginAccountSession() -> Router -> endAccountSession()`（见 INV-23），session 全程 active，故：跨池的外部重入 swap 完整进入普通 `beforeSwap` / `afterSwap` 与 public fee 路径；**同池**的生命周期重入（outer swap 的 `beforeSwap` 已 acquire 该池的 per-pool transient lock，回调期间对同一 poolId 再次进入 `beforeSwapLogic`（在 `_revertIfPublicSwapBlocked` 校验之后）会触发 `SwapLifecycleReentrant` revert（仍在保护期内的同池重入优先回退 `PublicSwapDisabled`））被阻断。在生产 settlement 路径中，`SettlementFacet.executeSettlementLogic` 的调用链（Launcher -> Hook -> SettlementFacet）不开 session（session 由外层 smart-EOA 拥有，非 launcher bootstrap），故 settlement 的 transferFrom / settle / take 窗口内 callback-token 发起的外部重入 public swap 没有 active session，会先于 lock/block 回退 `AccountSessionNotActive`（仍被阻断，只是选择子更早、不同）。是否处于 settlement unlock 内不改变 lock 机制本身（hidden flag 不会被重入抢先消费或错误继承），只改变重入 swap 在无 session 生产路径上命中的回退选择子。per-pool lock 基于 transient storage（`tstore`/`tload`），事务结束自动清除，settlement self-call 因 v4 跳过 callback 不进 `beforeSwapLogic`/`afterSwapLogic`，因此 SettlementFacet 在 `executeSettlementLogic` 内自行 `acquireSwapLifecycleLock(poolId)`（Phase 1 `transferFrom` 之前）与 `releaseSwapLifecycleLock(poolId)`（Phase 3 `_updateAfterSwap` 之后的函数末尾），覆盖 Phase 1 transferFrom → Phase 3 `_updateAfterSwap` 全窗口（含 swap → settle/take）。transferFrom 窗口的 reenterer 通常用 try/catch 吞掉 inner revert（无论 inner 命中 `AccountSessionNotActive` 还是 `SwapLifecycleReentrant`），故外层 settlement 仍正常完成，但 inner 同池 reentrant swap 被阻断、`dynamicFeeState` 未被推进。`[代码已证]`
  - 加流动性路径使用同一 per-pool lifecycle lock 覆盖快照→settle→mint 全窗口：`src/swap/MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore` 在接收人 fee 快照（`MemeverseUniswapHookUpgradeable.sol::_updateUserSnapshotViaFacet`）之前 `MemeverseTransientState.sol::acquireSwapLifecycleLock(poolId)`（已持则 revert `SwapLifecycleReentrant`，与 `SwapFacet.sol::beforeSwapLogic` 同款检查）、在 LP mint 与 `cachedLpTotalSupply` 更新之后 `::releaseSwapLifecycleLock(poolId)`。该窗口内 callback-capable token 在 settle 的 `transferFrom` 期间对同池发起的外部重入 swap 在 session 已 active 且池不在保护窗口时，于 `SwapFacet.sol::beforeSwapLogic` 的 lock 检查处回退 `SwapLifecycleReentrant`；add-liquidity 路径本身不开 session，无 session 时该重入先命中 INV-23 session 门回退 `AccountSessionNotActive`（仍被阻断，只是选择子更早、不同），保护窗口内则先回退 `PublicSwapDisabled`。`MemeverseSwapFeeBase.sol::_accrueLpFee` 无法在快照与 mint 之间推进 per-share fee growth，接收人快照 offset 与 mint 时点 feePerShare 保持一致。`MemeverseUniswapHookUpgradeable.sol::_removeLiquidityCore` 无需持锁：其快照与 burn 先于 settle/take 窗口、窗口后无份额发行，不存在快照与 mint 之间的 per-share 超额 claim 路径。`[代码已证]`
  - fee 自洽校验保留：当前授权的 `settlementUnlockCallback` 将 `PoolManager.swap` 返回值写入 `SettlementResult.swapDelta`；`executeSettlementLogic` 再按固定 fee rate 从该返回 delta 重算 output-side protocol fee（`expectedProtocolFeeOutputAmount`），并与 `SettlementResult.protocolFeeOutputAmount` 比较，不一致则回退 `PreorderSettlementFeeMismatch`。这是对当前授权 facet 返回字段的内部一致性检查；owner 可通过 `setFacet(SETTLEMENT_FACET_ROLE, ...)` 替换 SettlementFacet，因此它不是针对恶意或错误 owner-controlled facet replacement 的独立防线。`[代码已证]`
- 价值：callback 类型由调用数据显式决定，swap callback 是否执行由 v4 的真实 caller 规则决定；两者都可从局部输入直接验证，不依赖跨调用隐藏状态。这样既保证 settlement 自身不会重复收 public fee，也保证外部重入 swap 不能获得 fee-neutral 路径；同池生命周期重入被阻断（session-active 路径由 per-pool lock 阻断、no-session 的 settlement 路径由 INV-23 session 门更早阻断，见上一条），防止 callback token 在 outer swap 报价已固定后推进 `dynamicFeeState` 造成费率失真；typed result 与 fee 对账可检测当前授权 facet 返回的 output-side fee 字段不一致。`onlyOwner` facet replacement 仍是信任边界：恶意或错误替换可同时控制 `swapDelta` 与 `protocolFeeOutputAmount`，不由该自洽检查防住。
- 主要锚点：`src/swap/interfaces/IMemeverseUniswapHook.sol::UnlockCallbackKind`，`src/swap/interfaces/ISettlementFacet.sol::SettlementCallbackData`、`::SettlementResult`，`src/swap/MemeverseUniswapHookUpgradeable.sol::unlockCallback`（raw discriminator 校验与 typed dispatch），`src/swap/SettlementFacet.sol::executeSettlementLogic`、`::settlementUnlockCallback`，`lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol::beforeSwap`、`::afterSwap`, `src/swap/libraries/MemeverseTransientState.sol::acquireSwapLifecycleLock`、`::releaseSwapLifecycleLock`，`src/swap/MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore`
### INV-05 Locked 费用分发恒等式

- 约束：主池 `memecoin/uAsset` 的 `uAssetFee = executorReward + govFee`，其中 `executorReward` 必须按 full-precision `mulDiv` 或等价 overflow-safe 语义计算：`fullPrecisionMulDiv(uAssetFee, executorRewardRate, 10000)`，`govFee = uAssetFee - executorReward` 且减法保持 checked arithmetic 语义；quote/redeem 路径必须共享同一分账算术语义。主池 `memecoin` fee 进入 yield 路径。辅助池 fee 按 POLendUpgradeable 四池目标规则分流：POL fee burn，普通侧 `uAsset/PT` fee 进入普通领取账本，杠杆侧 `uAsset` fee 进入 governor treasury 路径，杠杆侧 `PT` fee 在 settle 前按固定 PT backing ratio 预兑付或 settle 后 redeem 后分发。`[目标规范]`
- 价值：保证主池与辅助池 fee 分账守恒、burn 顺序和 PT fee pending/settle 语义可审计。
- 主要真源：[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)，[docs/spec/verse/accounting.md](verse/accounting.md)

### INV-06 远端分发与远端 staking 要求 `msg.value` 精确匹配报价

- 约束：跨链分发与跨链 staking 都不是“至少足额”，而是“严格等于报价”。`[代码已证]`
- 价值：调用方与脚本必须先 quote，再按精确值提交交易。
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::redeemAndDistributeFees`，`src/interoperation/MemeverseOmnichainInteroperation.sol::memecoinStaking`

### INV-07 关键业务动作受阶段机约束

- 约束：`genesis/preorder` 仅 `Genesis`；`refund/refundPreorder` 仅 `Refund`；`claimNormalYT/claimNormalFees/mintPOLToken/redeemAndDistributeFees` 至少 `Locked`；LP 赎回仅 `Unlocked`。`[代码已证]`
- 约束：Router/Hook 的 ERC20 payout helper 都对 `recipient == address(0)` fail-close；`swap(...)` 与 `swapWithPermit2(...)` 经共用内部汇聚点 `MemeverseSwapRouter.sol::_swap` 入口校验 recipient 非零（单点覆盖两个公开入口），`removeLiquidity(...)`、`removeLiquidityWithPermit2(...)` 与 Hook fee payout 不允许把代币发送到零地址。`[代码已证]`
- 价值：跨模块资金动作不会越阶段执行。
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::genesis`，`::preorder`，`::refund`，`::refundPreorder`，`::changeStage`，`::claimNormalYT`，`::claimNormalFees`

### INV-07A Locked -> Unlocked 结算与公开 swap 保护必须同交易落地

- 约束：`changeStage()` 执行 `Locked -> Unlocked` 时，完整原子编排（共 5 步：`_captureLockedAuxiliaryFees` → `verse.currentStage = Unlocked` → `POLSplitterUpgradeable.settle` → 可选 `POLendUpgradeable.executeGlobalSettlement` → 写入 `publicSwapResumeTime`）见 [docs/spec/polend/settlement-and-fees.md §4](polend/settlement-and-fees.md)；本不变式保证该 5 步全部在同一次解锁迁移的同一笔交易内原子落地，避免 settlement 与保护窗口出现时间分叉。其中 `publicSwapResumeTime = block.timestamp + UNLOCK_PROTECTION_WINDOW`（窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md)）；hook-side public swap protection 自该写入后生效，由 `hook.beforeSwap` 按 pool-level `publicSwapResumeTime` 阻断公开 swap。该 settlement callback window 不由 launcher-side transient gate 或已生效的公开 swap block 保护。进入 `Unlocked` 后，赎回可用性由阶段与各函数自身条件决定。`[代码已证]`
- 价值：保证全局结算状态与受保护池公开 swap 恢复时间锚定同一次解锁迁移，避免 settlement 与保护窗口出现时间分叉。
- 杠杆结算零滑点取舍(Accepted Risk, 非缺陷)：`MemeverseLiquidityImpl._removeLeveragedAuxiliaryLiquidity:775` 对 `POL/uAsset、PT/uAsset、PT/POL` 三池固定 `removeLiquidity(0,0)`。同交易内 quote 已污染且紧下限可被持续推价 grief 致解锁 DOS(`TooMuchSlippage` 持续回滚, `stage` 仍 `Locked` 可重调), 故以 0 保活性, 缺口由 INV-13 bounded `settlementDustReserve` 有界覆盖, 后腿 24h `publicSwapResumeTime` 阻断消除原子三明治；单腿推价仅 grief 无利可图。`[Accepted Risk, 非缺陷]` 主要锚点同上 + `MemeverseLiquidityImpl:794` `MemeverseSwapRouter:665` `POLendUpgradeable:400`
- 主要锚点：`src/verse/MemeverseLaunchImpl.sol::changeStage` 的 `Locked -> Unlocked` 分支（delegatecall 入 `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked`）、POLSplitterUpgradeable/POLendUpgradeable settlement 调用、hook 公开 swap 恢复时间写入路径；完整 5 步顺序以 [docs/spec/polend/settlement-and-fees.md §4](polend/settlement-and-fees.md) 为单一事实源

### INV-08 Router/Hook 只操作动态费池且固定 tickSpacing

- 约束：Router 构造的池 key 固定 `LPFeeLibrary.DYNAMIC_FEE_FLAG` 与 `tickSpacing=200`；Hook 初始化也要求同样约束。`[代码已证]`
- 价值：防止同一对资产被错误路由到非预期费率池。
- 主要锚点：`src/swap/libraries/MemeversePoolKeyLib.sol::hookPoolKey`，`src/swap/SwapFacet.sol::beforeInitializeLogic`

### INV-09 代币增发权限集中在 Launcher

- 约束：`Memecoin.mint`、`MemePol.mint` 仅 launcher 可调用。`[代码已证]`
- 价值：保证发行与 LP 凭证配置只通过 launcher 生命周期执行。
- 主要锚点：`src/token/Memecoin.sol::mint`，`src/token/MemePol.sol::onlyMemeverseLauncher (modifier)`，`src/token/MemePol.sol::mint`

### INV-09A token burn 守恒与 OFT 公开 send

- 约束（单通道供给）：`OutrunERC20Init._update`（`src/common/token/OutrunERC20Init.sol::_update`）对 `from == address(0)` 增 `_totalSupply`（mint 分支）、对 `to == address(0)` 减 `_totalSupply`（burn 分支），mint/burn 经此单一通道维护供给；token 层无独立供给字段，故各链 `totalSupply` 恒等于 Σmint − Σburn。`[代码已证]`
- 约束（OFT 公开 send 守恒）：OFT 公开 `send`（`OutrunOFTCoreInit.sol::send`）经 `_debit`→`_burn`（`OutrunOFTInit.sol::_debit`）在源端减供给、`_credit`→`_mint`（`OutrunOFTInit.sol::_credit`）在目的端增供给，跨链两端的 `_totalSupply` 各自变化。合并后 OFT 回归官方 LayerZero OFTCore，token 层 UBO 机制（`withdrawIfNotExecuted`/`ComposeTxStatus`）已删除，send 路径不再产生 compose 二次 mint——源端 burn 1X、目的端经 `_credit` 单次 mint 1X（`to = address(0)` 仅重映射到 `0xdead`，mint 即终态，见 [docs/spec/interoperation/layerzero-oapp-oft.md §3.2.1](interoperation/layerzero-oapp-oft.md)），跨链通胀例外已不存在。故该守恒**无例外条件**成立。`[代码已证]`
- 价值：保证 token 单通道供给守恒在 OFT 公开 send 路径下无例外成立；OFT 回归官方 OFTCore 后，不再存在对该守恒与 INV-09 mint 权限约束的共同例外。
- 主要锚点：`src/common/token/OutrunERC20Init.sol::_update`，`src/common/omnichain/oft/OutrunOFTInit.sol::_debit`、`::_credit`，`src/common/omnichain/oft/OutrunOFTCoreInit.sol::send`

### INV-10 OFT compose 回调具备 replay 防护

- 约束：`YieldDispatcherUpgradeable` 与 `OmnichainMemecoinStakerUpgradeable` 在 endpoint 路径的 `ComposeState.None` 状态下检查 `guid` 未执行、再置 `Settled`；`ComposeState.Released` 态下 `lzCompose` 幂等放行（no-op），不标记执行、不结算。`[代码已证]`
- 约束（staker 互斥锁现居 proxy storage）：`OmnichainMemecoinStakerUpgradeable` 改 UUPS（`ERC1967Proxy`）后，`composeStates` 互斥锁位于 ERC-7201 namespace `outrun.storage.OmnichainMemecoinStaker`，升级保留；该 namespace 字段只允许尾部追加、不得重排或插入。`[代码已证]`
- 价值：跨链到账处理不可重复记账。
- 主要锚点：`src/verse/YieldDispatcherUpgradeable.sol::lzCompose`，`src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::lzCompose`

### INV-11 注册时间权威值来自注册中心写入

- 约束：launcher 不自行重算 `endTime/unlockTime`，以 registrar 传入值为准；本地报价读取注册中心 `DAY`，中心写入为最终来源，并写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`。`[代码已证]`
- 价值：链上最终时间语义由中心写入决定，报价仅供参考。
- 主要锚点：`src/verse/MemeverseLaunchImpl.sol::_storeRegisteredMemeverse`，`src/verse/libraries/MemeverseRegistrationLib.sol::FIXED_LOCKUP_DURATION (constant)`（`RegistrarAtLocal` 与 `RegistrationCenter` 共享的单一来源），`src/verse/registration/MemeverseRegistrarAtLocal.sol::quoteRegister`，`src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol::DAY (constant)`，`src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol::registration`

### INV-12 解锁后必须先经过保护窗口，再恢复公开 swap

- 约束：`Locked -> Unlocked` 同交易 settlement 顺序与公开 swap 恢复时间写入的机械口径已并入 INV-07A；本条仅保留该窗口的存在性论证与产品安全理由。窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](verse/config-matrix.md) `UNLOCK_PROTECTION_WINDOW`。
- 价值：保证 POL / genesis liquidity 的赎回公平性，并为 POL Lend / PT-YT 语义提供一致的全局结算窗口。
- 违反后果：先行动者可通过先赎回并抛售底层资产，把损失外部化给后续赎回者，造成用户重大亏损。`[产品安全要求]`
- 约束：固定 24 小时保护窗口是正常 `Locked -> Unlocked` 路径写入 pool-level `publicSwapResumeTime` 的产品语义；`Stage.Unlocked + hook` 按该 pool-level resume time 阻断公开 swap，赎回路径与公开 swap 可用性由不同模块分离控制。launcher 由 hook initialize 一次性固化（initializer write-once），不可 retarget；resume time 写入仅正常 Locked→Unlocked 路径由绑定 Launcher 执行，无 retarget 覆写路径。`[代码已证]`
- 活性约束：launcher binding 由 initialize 固化，运行时不可偏离真实 Launcher proxy，无 retarget 导致的整笔回滚活性风险。`[代码已证]`
- 主要锚点：`src/verse/MemeverseSettlementImpl.sol::UNLOCK_PROTECTION_WINDOW`，`src/verse/MemeverseSettlementImpl.sol::_activatePostUnlockPublicSwapProtection`（Locked→Unlocked 解算内写入），`src/swap/SwapFacet.sol::beforeSwapLogic`，`src/swap/SwapFacet.sol::_revertIfPublicSwapBlocked`，`src/swap/libraries/SwapGuardMath.sol::PublicSwapDisabled`，`src/swap/MemeverseUniswapHookUpgradeable.sol::initialize`（launcher 绑定 write-once 落点）

### INV-13 POLendUpgradeable 全局结算只能用 bounded reserve 覆盖 dust

- 约束：`settlementDustStates[uAsset].reserve <= settlementDustStates[uAsset].maxReserve` 必须始终成立。`maxReserve == 0` 表示该 `uAsset` 未完成 POLendUpgradeable reserve 配置，`POLendUpgradeable.registerLendMarket` 必须拒绝使用该 `uAsset` 的 verse。`[目标规范]`
- 约束：`POLendUpgradeable.executeGlobalSettlement(verseId)` 的债务偿还必须满足 `recoveredUAsset + consumedSettlementDustReserve >= verseDebt`。若 `recoveredUAsset < verseDebt`，则 `consumedSettlementDustReserve == verseDebt - recoveredUAsset`，且必须满足 `consumedSettlementDustReserve <= reserveBeforeSettlement`，其中 `reserveBeforeSettlement` 是执行前读取的 `settlementDustStates[uAsset].reserve` 快照。settlement 成功后只扣减实际消耗量，不清零该 `uAsset` 的全局 reserve。`[目标规范]`
- 约束：settlement dust reserve 只来自 `fundSettlementDustReserve(address,uint256)` 手动注入、Launcher bootstrap unused `uAsset` 注入；不得通过 mint、残值扣减、普通侧 LP 扣减或 treasury 隐式透支产生。`[目标规范]`
- 约束：settlement dust reserve 主要覆盖正确执行 `previewPTToUAsset` 固定 backing ratio 转换后的整数舍入 dust；不得覆盖 PT backing ratio / 模型错误。INV-07A Accepted Risk 下 `MemeverseLiquidityImpl._removeLeveragedAuxiliaryLiquidity` 固定 `0,0` 产生的有界价格缺口亦由该 reserve 有界覆盖（仍受 `maxReserve` 与 `deficit <= reserveBeforeSettlement` 约束，`SettlementDustInsufficient` fail-closed），不视为对本约束的违背。`[目标规范]`
- 约束：bootstrap pre-LP residual `POL/PT` 与普通 auxiliary LP split dust 是两个不同类别。前者必须先按 funding share 切分：`leveragedShare = floor(totalResidual * totalLeveragedDebt / totalGenesisFunds)`，`normalShare = totalResidual - leveragedShare`；不能把它们当成永久 launcher bucket 或未分类 dust。`[目标规范]`
- 价值：本条约束主要允许 wei 级整数舍入缺口通过 reserve 解决；INV-07A 下有界零滑点推价缺口亦由同一 reserve 有界覆盖，均受 `maxReserve` 硬上界与 `SettlementDustInsufficient` fail-closed 约束，不把无界资不抵债或模型错误伪装成 dust。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)

### INV-14 POLendUpgradeable PT raw 与 uAsset backing 必须分离

- 约束：raw-unit identity 固定为 `POL raw = main pool LP raw`，`PT raw = POL raw`，`YT raw = POL raw`。`1 raw PT` 不等于 `1 raw uAsset`。`PT` 的 uAsset backing 必须使用 verse 固定 ratio：`Math.mulDiv(ptAmount, ptBackingNumerator, ptBackingDenominator)`。`[目标规范]`
- 约束：`preRedeemPTFee`、`redeemPT`、`redeemYT` 的 PT reserve、settle 时预兑付 backing burn、`POLendUpgradeable.executeGlobalSettlement` 回收 PT settlement 都必须使用转换后的 `uAsset` 数量，不得直接用 `ptAmount`。`[目标规范]`
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
- 主要锚点：`src/verse/MemeverseLauncherUpgradeable.sol::claimNormalFees`，`src/verse/MemeverseSettlementImpl.sol::_mergePendingAuxiliaryGovFees`

### INV-17 创世总资金聚合上限必须保持累计且排除 preorder

- 约束：成功部署资金口径固定为 `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt`，且不包含 preorder。`[目标规范]`
- 约束：`MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max`，并且必须始终满足 `totalGenesisFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`。`[目标规范]`
- 约束：成功 `genesis` / `leveragedGenesis` 写入后都必须保持上述 aggregate cap；其中 `leveragedGenesis` 写入前必须按累计 `nextTotalLeveragedInterest = totalLeveragedInterest + interestAmount` 推导 `previewDebt`，并同时满足 `previewDebt <= debtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，不能只检查当前调用 delta。`[目标规范]`
- 价值：保证普通创世与杠杆创世共享同一聚合资金上限，避免成功写入把总创世资金推进到不支持的数值域。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)，[docs/spec/verse/accounting.md](verse/accounting.md)，[docs/spec/verse/lifecycle-details.md](verse/lifecycle-details.md)

### INV-18 PT settlement backing 偿还不变量

- 约束：POLendUpgradeable settlement 必须先偿还 `preRedeemedPT.uAssetBacking`，偿还后剩余 `settlementUAsset` 必须继续覆盖 `previewPTToUAsset(PT.totalSupply())`。完整 solvency 不变量为：`[目标规范]`

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
- 约束：`POLSplitterUpgradeable.recordPTBackingRatio(verseId, numerator, denominator)` 记录的 `numerator = mainPoolUAssetUsed` 必须是主池实际执行 spend，`denominator = mainPoolPOLAmount` 必须是 launch 实际 mint 出来的 main pool LP/POL raw amount，不能使用预估值或 bootstrap budget。`[代码已证]`
- 约束：auxiliary pool actual spend 低于 desired budget 形成的未使用 bootstrap `uAsset` 必须按 §6.7 注入 POLendUpgradeable settlement dust reserve / treasury excess 路径，未使用 bootstrap `memecoin` 必须 burn。`[目标规范]`
- 价值：把"PT backing 只能认实际执行额"作为独立 invariant 收口，避免 backing ratio 被预算/quote 数字污染导致 PT 经济失真。
- 去重关系：本条与 INV-14（POLendUpgradeable PT raw 与 uAsset backing 必须分离）共享"实际执行口径"语义——INV-14 约束 3 已规定记录口径为"主池实际执行 spend / 主池实际产出的 POL raw amount"。本条进一步聚合 genesis 部署时序（[genesis.md §5.2](polend/genesis.md)）中 PT backing 实际额规则的完整约束集（含未使用资金处置）。未使用 `uAsset` 处置见 INV-13 约束 3，未使用 `memecoin` burn 见 INV-04 约束 5。本条作为聚合锚点，不替代上述 INV。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)

### INV-20 返佣偿付能力与 protocol fee 拆分守恒

- 约束（偿付能力）：每笔返佣累计或领取交易成功完成后，对每个 rebate currency `c`，`MemeverseUniswapHookUpgradeable`(Router) 在 `c` 下的 ERC20 余额必须 ≥ Σ 所有 referrer 的 `pendingRebate[r][c]`。`pendingRebate` 与 `referrerRebateBps` 位于 hook 的 ERC7201 namespace `outrun.storage.MemeverseUniswapHook`；`pendingRebate` 账本与 LP per-share accounting 字段隔离，但共享 hook proxy 的 token custody。`SwapFacet::_settleProtocolFee` 先内联执行 `pendingRebate[referrer][currency] += amount` 并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take`（interaction），最后 emit `ProtocolFeeCollected`；记账这一步是纯 storage effect，无 PoolManager 调用、外部调用或 facet→facet delegatecall。ledger effect 先于 treasury take 与调用方的 rebate take；该顺序仅定义 CEI 的账本与交互顺序，本条余额覆盖只在返佣累计或领取交易成功完成后评估，不对执行中间点作断言。该 helper 现为严格 CEI（effect → interaction → event）：treasury take 不触发 v4 hook callback，ERC20 currency 仍会执行外部 `transfer` token 代码。安全性依赖 fee currency 为标准 ERC20（注册的协议费代币；普通池下为输入代币）、treasury 是被动收款方，以及任一 take 或 token transfer 失败时整笔事务原子回滚，账本、事件和 token 转账不会部分提交。beforeSwap 主路径将 rebate 与 LP fee 合并 take，afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立 take rebate。合并 take 中 LP fee 由 LP per-share accounting 独立记账，不属 rebate liability；成功交易完成后，rebate 分量与 `pendingRebate` 增量同步。`claimRebate` 清零 `pendingRebate[r][c]` 后再 external transfer（严格 CEI），transfer 失败时清零一并回滚。hook UUPS 升级必须遵守 storage 冻结约束；正常升级保留 `pendingRebate` / `referrerRebateBps`。`[代码已证]`
- 约束（费率拆分守恒，币种无关）：动态 fee 费率必须满足 `lpFeeBps + protocolFeeBps = totalFeeBps`，由 `FeeMath.splitFeeBps` 用 `protocolFeeBps = mulDiv(feeBps, PROTOCOL_FEE_SHARE_BPS, BPS_BASE)` 后 `lpFeeBps = feeBps - protocolFeeBps`（`unchecked` 减法；安全由 `PROTOCOL_FEE_SHARE_BPS < BPS_BASE` ⇒ `protocolFeeBps <= feeBps` 保证，不会下溢）保证，纯整数运算无舍入差。此约束只作用于 bps 配置层，不涉及任何 token amount。`[代码已证]`
- 约束（普通动态 Swap protocol fee 分配守恒，同币种）：`actualProtocolFee`、`toTreasuryAmount`、`rebateAmount` 同属一个 protocol fee currency，并满足 `toTreasuryAmount + rebateAmount = actualProtocolFee`；其中 `toTreasury = protocolFee - rebate`，`rebate = FullMath.mulDiv(protocolFee, rebateBps, PROTOCOL_FEE_SHARE_BPS)` 向下取整。输入侧从已取整输入总费按 split 分配 `actualProtocolFee`；输出侧从实际核心毛输出或 exact-output 的固定毛输出推导它。LP fee 始终以 input token 独立计量，当 `protocolFeeOnInput==false` 时不得把两种币种的 amount 相加。普通动态路径由 `OrdinarySwapMath` 定义，不把 `FeeMath.feeOnAmount(amount, protocolFeeBps)` 作为通用计算；后者只用于固定费与 preorder。`[代码已证]`
- 约束（上限）：`referrerRebateBps <= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`），否则 `MemeverseUniswapHookUpgradeable::setReferrerRebateBps`（Router 直接实现，写 hook storage）revert `RebateExceedsProtocolShare`；保证单次 swap 的 rebate ≤ protocolFee，不会透支 protocol share。`[代码已证]`
- 约束（coverage）：返佣只在普通 swap 触发（beforeSwap 主路径 `knownLpInputFee > 0 && knownProtocolInputFee > 0 && effectiveSupply != 0` 走 `_computeRebate` + `_settleProtocolFee` + 合并 take；beforeSwap 边界 lpFee==0、protocolFee==0、或 effectiveSupply==0（drained pool）+ afterSwap 3 点走 `_collectProtocolFee`，位于 `SwapFacet::beforeSwapLogic` / `afterSwapLogic`）；preorder settlement（`MemeverseUniswapHookUpgradeable::executePreorderSettlement`）不携带 referrer，其 `ProtocolFeeCollected.amount` 仍是完整 protocolFee，不参与守恒等式的 rebate 项。`[代码已证]`
- 价值：保证返佣账本字段与 LP per-share accounting 隔离、共享 hook proxy token custody、相对 treasury 地址隔离；偿付靠 hook 在各 rebate currency 下的 ERC20 余额覆盖 Σ`pendingRebate[r][c]`；且 protocol fee 守恒；索引器 / 财务对账按 swap 维度统计 protocol 总收入时必须把 `ProtocolFeeCollected` 与 `ReferralRebateAccrued` 求和，否则漏计 rebate。
- 主要锚点：`src/swap/libraries/FeeMath.sol::PROTOCOL_FEE_SHARE_BPS`、`::splitFeeBps`；`src/swap/MemeverseUniswapHookUpgradeable.sol::claimRebate`（Router 直接实现，CEI）、`::pendingRebateOf`（Router）、`::setReferrerRebateBps`、`::RebateExceedsProtocolShare`；`src/swap/SwapFacet.sol::beforeSwapLogic`、`::afterSwapLogic`、`::_computeRebate`（view，reb 公式）、`::_settleProtocolFee`（内联写 `pendingRebate` + emit `ReferralRebateAccrued`；`_collectProtocolFee` 与 beforeSwap 主路径均调）、`::_collectProtocolFee`（rebate take recipient = `address(this)`；`_collectProtocolFee` = `_computeRebate` + `_settleProtocolFee` + 独立 rebate take）、`::_takeToTreasury`、`::_decodeReferrer`

### INV-21 GenesisCredit 利息分栏与混池 burn 会计不变量

- 约束（real/credit 分栏存储）：用户级杠杆利息按来源分两栏独立累加，互不扣减：`leveragedInterestPaid[verseId][user]` 存储 `leveragedGenesis` 路径真付的 uAsset 利息，`creditInterestPaid[verseId][user]` 存储 `leveragedGenesisWithCredit` 路径抵扣的 GenesisCredit 利息；同一用户对同一 verse 可同时累积两栏。`[代码已证]`
- 约束（market 级合计与切分）：`market.totalLeveragedInterest` 保留为 real + credit 合计存储；`market.totalCreditInterest` 独立累计 credit 利息；real 部分用差值推导 `realInterest = market.totalLeveragedInterest - market.totalCreditInterest`。`totalCreditInterest` / `totalLeveragedInterest` 都是只增累计量，refund 路径不扣减（用 `refundClaimed` 防重复）。`[代码已证]`
- 约束（每 verse 上限）：对每个 verse，必须始终满足 `market.totalLeveragedInterest >= market.totalCreditInterest`。若该不变量被破坏，差值推导的 `realInterest` 会下溢或得到非真实 token 流入量，破坏 treasury 清扫与 burn 量。`[代码已证]`
- 约束（finalize burn 量）：`POLendUpgradeable.finalizeLeveragedGenesis(verseId)` 必须把该 verse 托管的 GenesisCredit burn 掉，burn 量精确等于该 verse 的 `market.totalCreditInterest`（不是 `totalLeveragedInterest`，也不是用户级 `creditInterestPaid` 的链上动态求和）。`[代码已证]`
- 约束（状态机互斥保证混池 burn 安全）：`POLendUpgradeable.markRefundable` 与 `POLendUpgradeable.finalizeLeveragedGenesis` 都 `require market.state == Genesis` 并分别迁移到 `Refund` / `Locked` 终态；状态机互斥保证同一 verse 的 refund 与 finalize 不会都发生。POLendUpgradeable 对某 `uAsset` 的 GenesisCredit 托管余额是该 `uAsset` 所有 verse 的 credit 利息合计（混池），因此 finalize 时刻该 verse 的 `totalCreditInterest` 仍精确等于其未退走的 GenesisCredit 托管量，按 `market.totalCreditInterest` burn 不会误烧其他 verse 的份额。`[代码已证]`
- 约束（pro-rata claim 路径读合计）：`claimLeveragedYT` 切 YT 份额、`claimResidual` 的权益基数若依赖用户杠杆利息，必须读 `leveragedInterestPaid + creditInterestPaid` 合计（与 `getUserLeveragedDebt` 合计口径一致）；存储层拆栏、view/pro-rata-claim 层合计。`[代码已证]`
- 约束（claimRefund 分栏原币退回，不走合计）：`claimRefund` 是物理隔离的 split routing，不读合计——real 部分按 `leveragedInterestPaid[verseId][msg.sender]` 退该 verse 的 `uAsset`，credit 部分按 `creditInterestPaid[verseId][msg.sender]` 退 `market.creditToken`（GenesisCredit）；两条分栏各自独立、互不串读（与 genesis.md §4 一致）。混池下 POLendUpgradeable 对某 `uAsset` 的 GenesisCredit 托管余额仅来自各 verse 的 credit 利息合计，不含 real 利息（real 利息以 `uAsset` 形式付入，未进 credit token 托管池）；若 credit 退款误读合计（`realPaid + creditPaid`）会从其他用户/verse 的托管份额多付 credit token。`[代码已证]`
- 约束（credit 路径不产生 token 流入）：`leveragedGenesisWithCredit` 的 `GenesisCredit.transferFrom(msg.sender, POLendUpgradeable, creditAmount)` 只移动 GenesisCredit token；不 mint 该 verse 的 `uAsset`，不增加该 `uAsset` 的 `globalDebtByUAsset`（mint 只在 `finalizeLeveragedGenesis` 基于合计 `totalLeveragedInterest` 统一发生）；故 credit 利息在 finalize 时无对应 `uAsset` token 流入，必须跳过 treasury 清扫。`[代码已证]`
- 约束（credit token 地址锁定）：`market.creditToken` 在该 verse 首次 `leveragedGenesisWithCredit` 时缓存 `GenesisCreditFactory.creditOf(uAsset)` 解析结果；此后 `finalizeLeveragedGenesis` 的 burn 与 `claimRefund` 的退 credit 必须读 `market.creditToken` 缓存值，不重新解析 `creditFactory` 指针。这锁定 credit token 身份，防止 `setCreditFactory` 中途变更（owner-only）导致 finalize / claimRefund 解析到 `address(0)`（静默 burn no-op + 假事件）或不同 token（烧错 token / 退款 revert）。门控于“本次实际需要 burn/退 credit”：`finalizeLeveragedGenesis` 仅当 verse 级 `market.totalCreditInterest != 0` 时、`claimRefund` 仅当调用方级 `creditInterestPaid[verseId][msg.sender] != 0` 时，才检查 `market.creditToken`；此时若读到 `address(0)`（defense-in-depth 分支，正常路径不可达——有 credit 参与的 verse 在首次 `leveragedGenesisWithCredit` 即写入缓存，finalize/claimRefund 时必已填），必须 revert `NoCreditForUAsset`，绝不静默跳过 burn/退款。real-only 情形（verse 级 `totalCreditInterest == 0` / 调用方级 `creditInterestPaid == 0`）不进入此分支，正常退 `uAsset` / 跳过 burn，不触发该 revert。`[代码已证]`
- 约束（credit / uAsset 单位一致性）：`market.totalCreditInterest` 能与真付 `uAsset` 利息 raw-unit 同栏并入 `totalLeveragedInterest`、参与 launch gate / debt 推导 / YT / residual 分配，前提是 GenesisCredit 与该 verse `uAsset` 同 raw-unit 会计口径。当前 GenesisCredit 固定 18 decimals，故 credit path 只支持 `uAsset.decimals() == 18`。`GenesisCreditFactory.deployCredit` 必须拒绝非 18-dec `uAsset`（revert `InvalidUAssetDecimals`）；`leveragedGenesisWithCredit` 在该 verse 首次解析 credit token 的流程内（经 `creditOf(uAsset)` 取得地址后、写入 `market.creditToken` 缓存前）校验 `uAsset` 与 GenesisCredit 均为 18 decimals，不满足时 revert `CreditDecimalsMismatch`。非 18-dec `uAsset` 仍可走普通 `genesis` / `leveragedGenesis`，但不得启用 credit path。若该约束被破坏（例如非 18-dec `uAsset` 通过错误配置接入 credit path），`1e18` raw credit 会被当作 `1e18` raw uAsset 利息，导致 debt / launch gate / YT / residual 权益按错误数量级计算。
- 价值：保证 GenesisCredit 抵扣路径与正常杠杆路径的会计对齐、债务推导守恒、treasury 清扫只对真实 token 流入执行，并保证混池 burn 量精确隔离到单 verse。
- 去重关系：本条与 [docs/spec/polend/core.md §6.3](polend/core.md) 共享同一分栏存储语义——core.md 聚焦"字段定义与 refund 不扣减口径"，本条聚焦"作为不变量的会计等式与状态机互斥保证"。两者交叉引用，不互相替代。
- 主要真源：[docs/spec/polend/core.md](polend/core.md)，[docs/spec/polend/genesis.md](polend/genesis.md)，[docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md)
- credit token 地址锁定锚点：`src/polend/POLendUpgradeable.sol::leveragedGenesisWithCredit`（缓存写入）、`::finalizeLeveragedGenesis`（读缓存 burn）、`::claimRefund`（读缓存退 credit）；`src/polend/interfaces/IPOLend.sol::LendMarket.creditToken`

- 分栏存储锚点：`src/polend/POLendUpgradeable.sol::leveragedInterestPaid`（real 部分分栏）、`::creditInterestPaid`（credit 抵扣分栏）

### INV-22 普通动态 Swap 一次选费、四路径结算、报价与容量 `[代码已证]`

- 约束（唯一实现归属）：普通动态 Swap 的 exact-input/exact-output × 输入/输出侧 protocol fee 四条路径必须只由 `OrdinarySwapMath` 实现。`SwapFeeMath` 只保留方向、实际 `BalanceDelta` 与共用上下文；固定费才使用 `FeeMath.feeOnAmount`。普通动态路径不得调用 `feeOnAmount`、递归选费或多轮迭代。
- 约束（一次选费）：`totalFeeBps` 只由原始用户请求（exact-input 的 gross input 或 exact-output 的 net output）和执行前完整上下文选择一次。协议费币腿、变换后的核心目标、任一费用金额、fee-induced flow 与原始 `sqrtPriceLimitX96` 都不是本笔费率输入。
- 约束（四路径与币种）：输入侧协议费路径按已取整输入侧总费拆分 LP/protocol；输出侧协议费路径以实际核心毛输出结算 protocol fee，输出侧 protocol fee 按 totalFeeBps/lpFeeBps 生存率之比从核心毛输出扣除。LP fee 始终是输入币；protocol fee 可为输入币或输出币。不同币种 amount 不得相加为总费用、返佣或任何会计守恒式。
- 约束（实际与最终 delta）：PoolManager 传入 `afterSwap` 的实际核心 delta 是完整成交校验、动态费历史更新和四路径结算的唯一真实依据；Hook charging delta 调整后的最终用户 delta 才是 Router `amountOutMinimum` / `amountInMaximum` 的唯一依据。失败交易不得收费或更新历史。
- 约束（Referral）：每笔 `rebate <= actualProtocolFee`，且 rebate、treasury share 与实际 protocol fee 必须同币种并满足 `rebate + toTreasury == actualProtocolFee`。输出侧 protocol fee 必须从实际核心毛输出或 exact-output 的固定毛额推导，不得与输入侧 LP fee 跨币种相加。
- 约束（价格限制与容量）：原始价格限制只影响可执行性，不影响已选 `feeBps`。非零请求必须有活跃流动性，事前价格满足全范围下端点可等、上端点严格小于；用户内部有效停止价允许核心目标等于容量，但全范围端点只允许严格小于容量。非零 100% exact-output、不可完整成交、不可表示 delta 与全范围端点 equality 必须 revert。V4 `SwapMath` 的输出取整也可能把 post-swap 价格推到全范围端点；即使 core target 严格小于 capacity，此情形同样 revert `FinalTargetNotExecutable`，以避免端点仓位被取整差值耗尽。
- 约束（报价一致性）：非零 `quoteSwapFeeWithContext`、Lens 和执行在相同完整上下文必须一致地拒绝或给出相同最终用户金额。报价只读；静态或普通调用不得写 Hook/PoolManager、settle/take 资金或调用可写外部逻辑。零金额报价仅表示兼容预览，不表示可执行交易。
- 约束（v4 LP fee 代码事实）：新池将 v4 LP fee 初始化为零；当前源码没有 `updateDynamicLPFee`；普通 `beforeSwap` 不返回 fee override。它们是源码结构事实，不构成 runtime、deployment 或 governance check。`[代码已证]`
- 约束（PoolManager protocol fee 外部边界）：PoolManager protocol fee 是外部 controller 的行为，不受 Memeverse 权限或保证，也不属于本任务的 protocol fee 模型。
- 价值：将费率选择、资产归属、delta 边界、容量边界与代码结构事实收敛为可测试和可审计的一组规则，避免 fee-on-fee、跨币种守恒错误或 partial-fill 收费。
- 主要真源：仅 [docs/spec/swap/uniswap-v4.md §3.1–§3.2](swap/uniswap-v4.md) 是本不变量规则的唯一 canonical；[docs/spec/swap/swap-flow.md §1.1](swap/swap-flow.md) 与 [docs/spec/swap/swap-integration.md §2.3.1](swap/swap-integration.md) 仅为从属非规范流程摘要／集成导览，不是共同真源。

### INV-23 Smart EOA transient session 的动态费隔离 `[代码已证]`

- 约束（principal 作为执行 trader）：普通动态费的既有 `DynamicFeeFacet[trader][poolId]` 算法必须将执行 trader 替换为 Hook active session context 的 principal。`tx.origin` 不得作为 fallback，Router、`hookData` 与 PoolManager callback caller 也不得补充或覆盖该 principal。
- 约束（地址批次隔离）：同一 `handleOps` 内，合约账户 `A` 与 `V` 各自完成 `beginAccountSession() -> Router -> endAccountSession()` 后，动态费 address-batch state 必须分别归入 `[A][pool]` 与 `[V][pool]`；任一账户的历史、计数或费率结果不得污染另一账户。
- 约束（原子生命周期）：`beginAccountSession() -> 单一经济账户 Router -> endAccountSession()` 必须在同一不可捕获、全成全败的执行 frame 内完成；失败路径整笔 revert，transient storage 随之回滚，不得留下可被后续 callback 使用的 context。`end` 的语义是主动让出 session：显式 `end` 清除 Hook transient session context，使同一外层交易内的下一个 `beginAccountSession()` 能通过 `activePrincipal == address(0)` 校验（多账户串行场景，如 ERC-4337 bundler 一笔 `handleOps([A, V])`，A 必须显式 `end` 才能让 V 的 `begin` 成功）。省略 `end` 的唯一后果是：本笔外层交易后续的 `beginAccountSession()` 会因 `activePrincipal` 仍非零而回退 `AccountSessionAlreadyActive`；若无后续 `begin`，交易结束时 EIP-1153 transient storage 自动清零 `activePrincipal`，状态干净，显式 `end` 冗余。EVM 不提供交易后回调，Hook 无法、且无需在单账户省略 `end` 的交易上拒绝（无资金损失、无跨交易权限残留）。

### INV-24 YT Flash Swap 结算不变量 `[代码已证]`

约束 YT Flash Swap（POL↔YT 复用 PT/POL 池，详见 [yt-flash-swap.md](swap/yt-flash-swap.md)）的结算安全性。实现已由 `src/swap/MemeverseYTFlashSwapRouter.sol`、接口、Hook getter 与单元/集成/invariant 测试落地。

- 约束（恰好一次普通 swap）：每个用户入口在正常 PT/POL 池状态下必须完成且仅完成一次普通 PT/POL swap——买入为 exact-input `y PT -> R_actual POL`，卖出为 exact-output `Q_actual POL -> y PT`。不得产生第二次 swap、fee 修正或 Router 内报价循环。
- 约束（真实 BalanceDelta 唯一结算依据）：PoolManager 返回的真实 `BalanceDelta` 是唯一结算依据。买入真实 delta 必须恰好 `PT=-y, POL=+R_actual`；卖出真实 delta 必须恰好 `PT=+y, POL=-Q_actual`。`FlashDeltaMismatch` 只校验真实 delta 的币种、符号与完整成交结构，绝不与任何历史 quote、离线猜测值或搜索边界比较，也不要求真实结算等于历史报价。
- 约束（买入实际成本与 fail-closed）：买入必须先验证 `0 < R_actual < y`，再计算 `actualPOLIn = y - R_actual`，并要求 `actualPOLIn <= maxPOLIn`。`R_actual == y`（零成本）与 `R_actual > y`（负成本）都必须 fail closed，不得让 unsigned subtraction 下溢，也不得把接口变成「同时给用户 YT 和额外 POL」的双输出交易。买入只从 payer 拉取 `actualPOLIn`，不得预拉 `maxPOLIn`，无退款分支。
- 约束（卖出净输出与 minPOLOut 顺序）：卖出必须先验证 `0 < Q_actual < y`，再计算 `polOut = y - Q_actual`。`Q_actual == 0` 或 `Q_actual >= y` 必须回滚。`polOut >= minPOLOut` 的校验必须在 `take`、payer `pull`（`exactYTIn` YT）与 `merge` 之前完成；`polOut < minPOLOut` 在上述任一资金动作前原子回滚。
- 约束（三币 baseline 精确恢复）：用户入口在本地保存 PT、YT、POL 三个 `RouterBalances` baseline，`unlock` 返回、pending context hash 已清零且 callback result 已 decode 后，必须确认三者精确恢复。预存 dust 不可消费（正常部署后 baseline 应为零，任何交易不得动用），`recipient` 为 Router 被禁止，避免输出资产混入 baseline。Router 不使用预存 PT/POL/YT 补差。
- 约束（买入 Splitter POL allowance residual）：买入成功路径向 POLSplitterUpgradeable 批准恰好 `y` POL 后调用 `split(verseId, y)`（split/merge 第一参数恒为本入口的 verseId，签名见 `src/polend/POLSplitterUpgradeable.sol::split` / `::merge`）；split 后必须立即检查 Router→Splitter 的 POL allowance 为零。split 必须恰好消耗 `y`，非标准残余 allowance 一律 fail closed；成功路径不调用 `approve(0)`。卖出的 `merge(verseId, y)` 直接 burn Router 持有的 PT/YT，不经 ERC20 approval/transferFrom，无残余 allowance。
- 约束（split/merge 结果守卫的升级安全性质）：`SplitResultMismatch`（`_executeBuy`，post-call 校验 `split` 铸造的 PT/YT 是否精确等于 `y`）与 `MergeResultMismatch`（`_executeSell`，post-call 校验 `merge` 返回的 POL 是否精确等于 `y`）都是调用后的结果等式检查，不是调用前的 quote。对当前 Router 绑定的 canonical `POLSplitterUpgradeable`，这两个守卫都不可达：真实 `split`/`merge` 严格按请求数量返回（`split` 无条件 1:1 铸造 `y` PT 与 `y` YT，`merge` 无条件按 PT/YT 量返回对应 POL），且 `_validateAndResolve` 在每次入口锁定 canonical Splitter、Router `splitter` 字段 immutable 不可改写。因此它们是 defense-in-depth / 升级安全覆盖：仅覆盖 canonical `POLSplitterUpgradeable` 经 UUPS 升级后偏离 1:1、或绑定到非 canonical/畸形 Splitter 的场景，不覆盖当前 canonical Splitter 的运行时 split/merge 行为。**不应**被读作「split/merge 运行时记账对真实 Splitter 安全」的证明；针对真实 Splitter 记账安全性的可信边界由 canonical 锁定（`_validateAndResolve` + `splitter` immutable + 升级治理）承担，不由这两个 post-call 守卫承担。
- 约束（principal 绑定与 canonical dependency 顺序）：每个用户入口在任何资金动作（转账、take、settle、split、merge）之前，必须同时通过两项校验：`Hook.activeAccountSessionPrincipal() == msg.sender`（无 session 或不匹配回滚 Router 自身接口 `AccountSessionPrincipalMismatch`；与 Hook 同名 afterSwap error 的区分见 [yt-flash-swap.md §11](swap/yt-flash-swap.md)）；当前 launcher 的 `getLauncherContracts()` 返回的 `memeverseUniswapHook`/`polSplitter` 与 Router immutable 一致（否则 `CanonicalDependencyMismatch`）；外调前必须先校验 `hook.launcher()` 返回的 launcher 非零且有 deployed code（否则 `LauncherCodeNotReady`，镜像构造期 `HookCodeNotReady` 的 code-length-first 顺序）。每个入口只外调一次 `getLauncherContracts()` 复用结果完成 canonical 比较；Router 不缓存 launcher 配置。payer 固定为 `msg.sender`，无独立 payer 参数。
- 约束（unlock context hash 一次性消费与重入保护）：`unlock` 前以 transient storage 写入无动态 `hookData` 的 context hash（context 仅含 action、payer、recipient、verse/tokens、amount/limit/price limit、referrer 等执行字段，不含 `RouterBalances`）。callback 只接受 PoolManager，验证原始 data hash 后立即清零，再 decode 或外调，保证 one-shot 一次性消费。用户入口具有重入保护；外部 callback、token 操作与 Splitter 操作都不能重入另一笔用户交易。
- 约束（构造期 PoolManager 对角不变量）：构造成功前，Router 在零地址检查之后、读取 `hook_.poolManager()` 并进行 manager 对角比较之前，必须按 `manager_`、`hook_`、`splitter_` 顺序确认三个 immutable executable dependency 均有 deployed code；`manager_`、`hook_`、`splitter_` 分别无 code 时回滚命名错误 `PoolManagerCodeNotReady`、`HookCodeNotReady`、`SplitterCodeNotReady`。随后 Router 构造器必须校验 immutable `manager_` 与 Hook 的 immutable `poolManager`（经 `SafeCallback`/`ImmutableState`）相同，不满足回滚命名错误 `RouterPoolManagerMismatch`。`SafeCallback(manager_)` 在构造器 body 前已绑定 manager immutable，因此上述 body 内检查不是发生在该绑定之前，而是确保部署成功前完成 code-ready 校验、读取 getter 与对角比较。否则 Router 会在自身 manager 上 `unlock`→`swap`，该 manager 回调 `key.hooks = address(hook)`，而 Hook 的 `onlyPoolManager` 只接受自身 manager，使两条 YT Flash Swap 入口永久回滚（`NotPoolManager` 或先 `PoolNotInitialized`），且 manager immutable 不可恢复。镜像代码库对 facet/upgrade/lens 同对角的处理。
- 价值：保证 YT Flash Swap 不引入第二个 AMM、不重复收费、不消费 Router 自有余额，且所有失败路径（capacity 不足、价格限制、partial fill、恶意 callback、token/Splitter 重入、int128/uint256 边界、过期 deadline、principal/dependency 失配、非法成本/债务、minPOLOut/maxPOLIn 违反、baseline/allowance 未恢复）都原子回滚，用户不会因失败交易被保留预拉资产。
- 去重关系：本条与 INV-22（普通动态 Swap 一次选费/四路径）共享「真实 BalanceDelta 是唯一结算依据」「一次选费」语义——YT Flash Swap 的底层 PT/POL 腿就是一次普通动态 swap，INV-22 的费率/容量/价格限制规则完全适用，本条只在其之上叠加 split/merge flash 结算与 baseline/allowance/principal/dependency 的额外约束，不重复普通 swap 规则。与 INV-23（Smart EOA transient session）共享 active session principal 语义——本条要求 Router 入口前 principal==msg.sender，不改变 session 生命周期。
- 主要锚点：`src/swap/MemeverseYTFlashSwapRouter.sol::swapPOLForExactYT`、`::swapExactYTForPOL`、`::unlockCallback`、`::_executeBuy`、`::_executeSell`（买入 split/PT settle/baseline 与卖出 merge/POL settle/baseline），`src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol`（两入口、`YTFlashSwapPOLForYT`/`YTFlashSwapYTForPOL` 事件、错误集合），`src/swap/MemeverseUniswapHookUpgradeable.sol::activeAccountSessionPrincipal`（只读 transient getter），`src/swap/interfaces/IMemeverseUniswapHook.sol::activeAccountSessionPrincipal`，`src/polend/POLSplitterUpgradeable.sol::split`、`::merge`（既有生命周期/PT-backing 唯一真源）。

### INV-25 OFT compose 兜底结算单一解析与记账一致性 `[代码已证]`

- 不变量：每个 (token, guid) 对在每个 composer 上至多被解析一次——`lzCompose`（置 `Settled`）与 `settlePendingCompose`（置 `Released`）经按 token 键控的 `ComposeState` 单向迁移互斥（None→Settled 或 None→Released，不可逆），endpoint 的 `RECEIVED_MESSAGE_HASH` 作纵深防御；OFT token 合约不再托管 compose 状态（无 `withdrawIfNotExecuted`/`ComposeTxStatus`/UBO），mint 即终态；staker 的 deposit 分支在外部 deposit 调用前校验 `vault.asset() == 投递 token`、`YieldDispatcherUpgradeable._settleToContract` MEMECOIN 分支同样在 approve 前绑定 `receiver.asset() == 投递 token`（本轮 code writer 同步落地；均 `TokenVaultMismatch`）——伪造 (token, vault) 配对在 staker 与 dispatcher 两侧均 revert、无资金移动，“伪造防护”因此同时覆盖 deposit 与 settle 两条资金流，而不只是互斥锁槽。
- 机制细节（投递证明、键控互斥与伪造防护、CEI 置位顺序、结算分支）：见 [docs/spec/interoperation/layerzero-oapp-oft.md §4](interoperation/layerzero-oapp-oft.md)。
- 价值：消除 to=0 经 `withdrawIfNotExecuted` 二次 mint 通胀攻击面，并修复 UBO 机制系统性失效（三路径已投递未执行 compose 兜底结算全坏）。token 合约回归官方 LayerZero OFTCore，兜底结算复杂度住在 composer，符合市场最佳实践。
- 主要锚点：`src/verse/YieldDispatcherUpgradeable.sol::settlePendingCompose`/`::_settle`/`::lzCompose`，`src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::settlePendingCompose`/`::lzCompose`，`src/verse/interfaces/IYieldDispatcher.sol`（`ComposeState`/错误/事件），`src/interoperation/interfaces/IOmnichainMemecoinStaker.sol`，`src/yield/MemecoinYieldVault.sol::reAccumulateYields`，`src/common/omnichain/oft/OutrunOFTCoreInit.sol::_lzReceive`（回归官方）。

### INV-26 资产计价投票的 checkpoint 三条 trace 必须配对一致 `[代码已证]`

- 不变量：任何改变 `totalAssets`、或经 mint/burn 增删 `_totalCheckpoints` 的 vault 变更，都必须伴随同 timepoint 的 `_writeTotalAssetCheckpoint` 写入（delegate/delegateBySig 仅写 `_delegateCheckpoints`、不改变资产值，无需配对）——`MemecoinYieldVault.sol` 的 `deposit`（`_mint` 后）、`mint`（`_mint` 后；B1 ERC-4626 部分对齐入口，复用 `_deposit`）、`requestRedeem`（`_burn` 与 `totalAssets` 扣减后）、`_accumulateYield`（`totalAssets` 增加后）四个调用点都在同一调用内以同一 `clock()` 写入资产 checkpoint，保证 `_totalCheckpoints` / `_delegateCheckpoints` / `_totalAssetsCheckpoint` 三条 trace 在任意历史 timepoint 配对一致。本条记录的是 `OutrunVotesInit.sol` 源码注释自述的既有语义（Pairing-consistency invariant (load-bearing)：写入 share checkpoint 的子类必须在同一 mutation 上调用 `_writeTotalAssetCheckpoint`，三条 trace 不得在时间上分叉），不是新引入的要求。claim 入口 `redeem` / `withdraw` 已落地且**不**触碰 `totalAssets`（资产扣减已在 `requestRedeem` 时完成），故**不**写资产 checkpoint、不在配对写入点之列。配对写入点调用清单为：`requestRedeem`（烧 shares + `totalAssets` 扣减 + 写 checkpoint）+ `deposit` / `mint` / `_accumulateYield`（写 checkpoint）+ `redeem` / `withdraw`（claim，**不**写 checkpoint）。`[代码已证]` 覆盖范围含上述全部调用点。
- 机制细节：share 侧 checkpoint 由 `OutrunERC20VotesInit.sol::_update` → `OutrunVotesInit.sol::_transferVotingUnits` 以 `clock()` 为键写入（mint/burn 增删 `_totalCheckpoints`，`_moveDelegateVotes` 写 `_delegateCheckpoints`）；资产侧由 `OutrunVotesInit.sol::_writeTotalAssetCheckpoint` 以同一 `clock()` 为键写入 `_totalAssetsCheckpoint`。零值/空金库路径不产生变更也不写 checkpoint（`deposit(0)`、`_accumulateYield` 的 `yield == 0` 早退、`totalSupply() == 0` 时 burn yield）；claim 入口 `redeem` / `withdraw` 不触碰 `totalAssets`（扣减已在 `requestRedeem` 时完成），同样不写 checkpoint。
- 价值：历史票权的资产计价换算依赖三条 trace 在同一历史 timepoint 配对读取——`OutrunVotesInit.sol::getPastVotes` / `::getPastTotalSupply` 分别经 `Checkpoints.sol::upperLookupRecent` 取同一 timepoint 的 delegate / total / totalAssets 三份快照，交给 `MemecoinYieldVault.sol::_convertPastVotes` / `::_convertPastTotalSupply` 换算；配对断裂（如 share 变更未写资产 checkpoint、或资产 checkpoint 落后于 share trace）会导致历史查询错价或换算到过期的资产值。
- 主要锚点：`src/common/token/extensions/governance/OutrunVotesInit.sol::getPastVotes`、`::getPastTotalSupply`、`::_transferVotingUnits`、`::_writeTotalAssetCheckpoint`，`src/common/token/extensions/governance/OutrunERC20VotesInit.sol::_update`，`src/yield/MemecoinYieldVault.sol::deposit`、`::mint`、`::requestRedeem`、`::_accumulateYield`、`::redeem`、`::withdraw`、`::_convertPastVotes`、`::_convertPastTotalSupply`

### INV-27 GenesisCredit 暂停开关不变量 `[代码已证]`

- 约束（全挡范围）：GenesisCredit 处于 pause 状态时，所有 ERC20 状态变更路径——`transfer` / `transferFrom` / `claim`（mint）/ `burn` / OFT 桥接（send 侧 `_burn` 与 receive 侧 `_mint`）——必须 revert `EnforcedPause`（继承 OZ `ERC20Pausable`，override `_update` 单点全挡）；`paused() == false` 时上述路径不受 pause 影响。`[代码已证]`
- 约束（状态迁移权限）：`paused` 状态只能由该 GenesisCredit owner 经 `pause` / `unpause` 迁移（复用 OFTCore 的 OZ Ownable，与 `setMerkleRoot` 同一权限面，不新增角色）；事件与错误复用 OZ Pausable（`Paused(address account)` / `Unpaused(address account)` / `EnforcedPause()` / `ExpectedPause()`），不自定义。`[代码已证]`
- 约束（幂等方向错误）：已 paused 时再 `pause` revert `EnforcedPause`；未 paused 时 `unpause` revert `ExpectedPause`。`[代码已证]`
- 约束（POLend 路径交互）：pause 期间 `POLendUpgradeable.leveragedGenesisWithCredit` 的 `transferFrom` 托管、Refund 终态 `claimRefund` 的 credit `transfer` 退回（托管仍在，资金不丢，延迟到 unpause 可领）、`finalizeLeveragedGenesis` 的托管 `burn` 均被阻断并 revert `EnforcedPause`，unpause 后恢复；零 credit 路径不受 pause 影响（`POLendUpgradeable.sol::claimRefund` 的 `realPaid != 0` 与 `creditPaid != 0` 两分支各自条件执行）：real-only 参与者（`creditInterestPaid == 0`）的 `claimRefund` 只走 real `uAsset` transfer 分支、不被阻断，mixed 参与者（real 与 credit 两栏均非零）pause 期间整笔 revert、real 部分随整笔延迟到 unpause，real-only 市场（`totalCreditInterest == 0`）的 `finalizeLeveragedGenesis` 不调用 credit burn、finalize 不被阻断；home pause 期间 LayerZero 消息 delivery 失败转为 retryable/storeable，不丢失。每个链上 GenesisCredit 部署的 pause 状态互相独立，由各自 owner 控制。`[代码已证]`
- 价值：为 owner 提供应急冻结 GenesisCredit 全部 token 移动的开关（含 claim、桥、finalize burn、refund transfer 的阻断与恢复），权限面、事件与错误语义完全复用 OZ `ERC20Pausable`，无自定义分叉。
- 主要锚点：`src/credit/GenesisCredit.sol::pause`，`::unpause`，`::paused`，`::_update`（OZ `ERC20Pausable` override）；`src/polend/POLendUpgradeable.sol::leveragedGenesisWithCredit`，`::claimRefund`，`::finalizeLeveragedGenesis`（受影响 credit 路径，real-only / mixed 分支为各自条件执行）；测试锚点 `test/credit/GenesisCredit.t.sol`（pause 全挡 / 权限 / 幂等方向语义）与 `test/credit/GenesisCreditPOLendIntegration.t.sol`（`test_RevertWhen_CreditPaused_LeveragedGenesisWithCredit_RevertsAndRealPathUnaffected`、`test_CreditPaused_RefundClaim_RealOnlyUnblockedMixedDelayedUntilUnpause`，覆盖 POLend 路径交互约束）
- 主要真源：[docs/spec/polend/genesis.md §4.1](polend/genesis.md)，[docs/spec/polend/core.md §8](polend/core.md)，[docs/SECURITY_AND_APPROVALS.md §4.3](../SECURITY_AND_APPROVALS.md)

## 3. 确定性边界

- 高确定性：以上带 `[代码已证]` 标签的不变量有函数级源码锚点；普通动态 Swap 的 INV-22 锚点为 `OrdinarySwapMath`、`SwapFacet`、`DynamicFeeFacet`、Lens bridge 与相应测试。其余 `[目标规范]` 条目须待对应源码和测试落地后再升级证据标签。
- `[未知]`：生产环境是否额外加多签/时锁/脚本守护进程，不在仓库源码证据范围内。
