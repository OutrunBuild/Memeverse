# MemeverseV2 访问控制边界（Authority / Evidence）

## 1. 目标与范围

本文档定义当前产品真相层的权限边界，聚焦：

- `owner` 边界
- `registrar` 边界
- `governor` 边界
- `permissionless`（无白名单）入口
- 外部 dispatcher / endpoint 边界

来源边界：
- 当前规则真源是 `docs/spec/*.md`（含本文档）。
- 规则证据来自 `src/**` 与 `test/**`。

## 2. 角色定义（按当前产品规则语义）

- `owner`
  - 主要是 OpenZeppelin `Ownable`、Outrun `OutrunOwnableInit`（OApp/OFT clone 系）或 Outrun `OutrunOwnableUpgradeable`（UUPS 系：`MemeverseLauncherUpgradeable` / `MemeverseUniswapHookUpgradeable` / `POLendUpgradeable` / `POLSplitterUpgradeable`）的 `onlyOwner`；两家 Outrun 基类共享同一 ERC7201 owner 槽 `outrun.storage.Ownable`。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::setMemeverseSwapRouter`, `src/swap/MemeverseUniswapHookUpgradeable.sol::setTreasury`, `src/interoperation/MemeverseOmnichainInteroperation.sol::setGasLimits`
- `registrar`
  - launcher 侧为 `memeverseRegistrar` 地址；注册中心与 local/omnichain registrar 构成上游链路。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::registerMemeverse`(facade 入口), `src/verse/MemeverseLaunchImpl.sol::registerMemeverse`(registrar ACL + body), `src/verse/registration/MemeverseRegistrarAtLocal.sol::localRegistration`
- `governor`
  - launcher 元数据更新与治理 treasury/upgrade 授权主体，同时也是 DAO treasury 与 reward payout 的唯一资产托管者。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::setExternalInfo`, `src/governance/MemecoinDaoGovernorUpgradeable.sol::propose`, `src/governance/MemecoinDaoGovernorUpgradeable.sol::sendTreasuryAssets`
- `permissionless caller`
  - 未加 owner/role 白名单，仅靠阶段/参数约束。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::genesis`, `src/verse/MemeverseLauncherUpgradeable.sol::preorder`, `src/yield/MemecoinYieldVault.sol::accumulateYields`, `src/yield/MemecoinYieldVault.sol::reAccumulateYields`, `src/verse/YieldDispatcherUpgradeable.sol::settlePendingCompose`
- `external dispatcher / endpoint caller`
  - 仅允许 LayerZero endpoint、launcher 或合约自身的调度入口。
  - 证据：`src/verse/YieldDispatcherUpgradeable.sol::lzCompose`, `::distributeSameChain`, `src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`, `src/verse/registration/MemeverseRegistrationCenter.sol::lzSend`
  - 同 surface 另有 `OmnichainMemecoinStaker.settlePendingCompose` 为 receiver-only 兜底入口（`msg.sender == receiver`，receiver 从哈希绑定 message 解码，属受益人自领），不属 endpoint/launcher/合约自身调度，详见 §3 边界矩阵。

## 3. 边界矩阵（源码锚点）

| Surface | 权限边界 | 证据 |
| --- | --- | --- |
| `MemeverseLauncherUpgradeable` 配置面 | `set*`、`pause/unpause`、`removeGasDust` 为 `onlyOwner` | `src/verse/MemeverseLauncherUpgradeable.sol::setMemeverseSwapRouter`, `::setMemeverseUniswapHook`, `::setMemeverseRegistrar`, `::setMemeverseProxyDeployer`, `::setYieldDispatcher`, `::setFundMetaData`, `::setExecutorRewardRate`, `::setPreorderConfig`, `::setGasLimits`, `::setLaunchImpl`, `::setSettlementImpl`, `::setLiquidityImpl`, `::setFeePreviewReader`, `::pause`, `::unpause`, `::removeGasDust` |
| `MemeverseLauncherUpgradeable.registerMemeverse` | 仅 `memeverseRegistrar` | `src/verse/MemeverseLauncherUpgradeable.sol::registerMemeverse`(facade 入口), `src/verse/MemeverseLaunchImpl.sol::registerMemeverse`(registrar ACL + body) |
| `MemeverseLauncherUpgradeable.setExternalInfo` | `governor` 或 `memeverseRegistrar` | `src/verse/MemeverseLauncherUpgradeable.sol::setExternalInfo` |
| Launcher 生命周期入口 | `genesis`/`changeStage`/`refund`/`claimNormalYT`/POLendUpgradeable `claimLeveragedYT`/`redeemAndDistributeFees` 等无白名单，靠阶段与输入校验；facade 保留入口级守卫（已注册 verse 校验与 `impl != 0`；`whenNotPaused` 保护侧：`genesis`/`preorder`/`genesisAndPreorder`/`claimNormalYT`/`claimNormalFees`/`redeemAuxiliaryLiquidity`/`claimUnlockedPreorderMemecoin`/`redeemAndDistributeFees`/`mintPOLToken`；pause 豁免侧（故意保持 pause 期间可执行）：`changeStage`/`refund`/`refundPreorder`（refund/settlement 须 pause 期可执行）、`redeemMemecoinLiquidity`（用户 POL 退出，pause 会 trap liquidity holders）、`settleLeveragedAuxiliaryLiquidity`（POLendUpgradeable 结算回调，仅 `polend` 可调、pause 期须可执行）），stage/claim/fee body 在 delegatecall sibling（`MemeverseLaunchImpl` / `MemeverseSettlementImpl`）内 | `src/verse/MemeverseLauncherUpgradeable.sol::genesis`(facade), `src/verse/MemeverseLaunchImpl.sol::genesis`(body), `src/verse/MemeverseLauncherUpgradeable.sol::changeStage`(facade), `src/verse/MemeverseLaunchImpl.sol::changeStage`(Genesis→Locked/Refund), `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked`(Locked→Unlocked), `src/verse/MemeverseLauncherUpgradeable.sol::refund`(facade), `src/verse/MemeverseSettlementImpl.sol::refund`(body), `src/verse/MemeverseLauncherUpgradeable.sol::claimNormalYT`(facade), `src/verse/MemeverseSettlementImpl.sol::claimNormalYT`(body), `src/verse/MemeverseLauncherUpgradeable.sol::redeemAndDistributeFees`(entry checks), `src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees`(fee body), `src/polend/POLendUpgradeable.sol::claimLeveragedYT` |
| `POLendUpgradeable` 杠杆创世与配置 | `leveragedGenesis` 为用户入口，靠 Launcher Genesis 阶段、累计 debt cap 与 aggregate genesis funds 上限约束；`setLeveragedDebtFactor` 为 owner-only，并受 `uint128.max * 1e18` 技术上限约束 | `src/polend/POLendUpgradeable.sol::leveragedGenesis`, `::setLeveragedDebtFactor` |
| `MemeverseRegistrationCenter` | `registration` 对外开放；参数配置和 gas dust 清理是 `onlyOwner` | `src/verse/registration/MemeverseRegistrationCenter.sol::registration`, `::removeGasDust`, `::setSupportedUAsset`, `::setDurationDaysRange`, `::setRegisterGasLimit` |
| `MemeverseRegistrarAtLocal` | `localRegistration` 仅 center；`setRegistrationCenter` 仅 owner | `src/verse/registration/MemeverseRegistrarAtLocal.sol::localRegistration`, `::setRegistrationCenter` |
| `MemeverseRegistrarOmnichain` | `setRegistrationGasLimit` 仅 owner | `src/verse/registration/MemeverseRegistrarOmnichain.sol::setRegistrationGasLimit` |
| `MemeverseSwapRouter` | `quote/swap/addLiquidity/removeLiquidity` 等用户路由入口为 permissionless；`previewClaimableFees(...)` 仅为只读预览 helper；pool bootstrap `createPoolAndAddLiquidity(...)` 仅当前 launcher 可调用；不承载 launch-settlement 特权授权；launcher 配置时需校验其 `hook` 绑定 | `src/swap/MemeverseSwapRouter.sol::quoteSwap`, `::swap`, `::addLiquidity`, `::removeLiquidity`, `::previewClaimableFees`, `::createPoolAndAddLiquidity`, `onlyLauncher` (modifier) |
| `MemeverseYTFlashSwapRouter` `[代码已证]` | 两个用户入口 `swapPOLForExactYT` / `swapExactYTForPOL` permissionless，但任何资金动作（转账、take、settle、split、merge）前必须同时满足：`hook.activeAccountSessionPrincipal() == msg.sender`（无 session 或不匹配回滚 Router 自身接口 `src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol` 定义的 `AccountSessionPrincipalMismatch`；与 Hook 同名 afterSwap error 的区分见 [swap/yt-flash-swap.md §11](swap/yt-flash-swap.md)）+ 动态校验当前 launcher 的 `getLauncherContracts()` 返回 `memeverseUniswapHook`/`polSplitter` 与 Router immutable 一致（否则 `CanonicalDependencyMismatch`）；无 Permit2 入口，付款只用 allowance + transferFrom；canonical 与行为详见 [swap/yt-flash-swap.md](swap/yt-flash-swap.md) | `src/swap/MemeverseYTFlashSwapRouter.sol::swapPOLForExactYT`, `::swapExactYTForPOL`; `src/swap/MemeverseUniswapHookUpgradeable.sol::activeAccountSessionPrincipal`; 结算不变量见 [invariants.md INV-24](invariants.md) |
| `MemeverseUniswapHookUpgradeable` | 核心 `addLiquidityCore/removeLiquidityCore/claimFeesCore/claimRebate` 对外开放；其中 `claimFeesCore` 与 `claimRebate` 虽可外部调用，但仅支持 self-claim：owner 由 `msg.sender` 推导（LP fee owner 对应 `claimFeesCore`，referrer 对应 `claimRebate`），`recipient` 仅为 payout destination，不存在 owner 参数，也不支持 nonce / deadline / signature / 第三方 relayed claim；owner 配置与逻辑替换：`setTreasury` / `setPoolInitializer` / `setLpTokenImplementation` / `setProtocolFeeCurrency` / `setReferrerRebateBps` / `setDefaultLaunchFeeConfig` / `setFacet` 为 `onlyOwner`（`launcher` 不再是 onlyOwner setter，改由 `initialize` 一次性固化）；`executePreorderSettlement(...)` 与 pair-based `setPublicSwapResumeTime(address,address,uint40)` 仅当前 launcher；三 facet（`SwapFacet` / `DynamicFeeFacet` / `SettlementFacet`）logic 入口不是产品对外 API；Hook 的支持路径经 `DELEGATECALL` 调度，直接 `CALL` 回退 `DirectFacetCallForbidden`（`onlyViaRouter`）。`onlyViaRouter` 只区分 direct `CALL` 与 `delegatecall`，不认证 delegatecall 宿主一定是本 Hook；`beforeSwap` 读取 pool-level resume time 执行公开 swap 保护 | `src/swap/MemeverseUniswapHookUpgradeable.sol::addLiquidityCore`, `::removeLiquidityCore`, `::claimFeesCore`, `::claimRebate`, `::_claimFees`, `::setTreasury`, `::setFacet`, `onlyOwner` (modifier), `onlyLauncher` (modifier), `::executePreorderSettlement`, `::setPublicSwapResumeTime`, `::initialize`, `src/swap/FacetGuard.sol::onlyViaRouter`, `src/swap/SwapFacet.sol::beforeSwapLogic`, `src/swap/SwapFacet.sol::_revertIfPublicSwapBlocked` |
| `Memecoin` | `mint` 仅 launcher；`burn` 自主 | `src/token/Memecoin.sol::mint`, `::burn` |
| `MemePol` | `setPoolId` 与 `mint` 仅 launcher；`burn` 为持币人或 allowance 授权方 | `src/token/MemePol.sol::setPoolId`, `::mint`, `::burn`, `onlyMemeverseLauncher` (modifier) |
| `Memecoin` / `MemePol` `memeverseLauncher` initialize-only | `memeverseLauncher` 为普通 storage，仅 `initialize` 写入一次，无 setter，不可由 owner 旋转（区别于 Solidity `immutable` 关键字的 EVM 级只读保证；实际不可变仅源于当前 implementation 无 setter） | `Memecoin.sol::initialize`（`memeverseLauncher` storage + initialize 写入）, `MemePol.sol::initialize`（同） |
| `Memecoin` / `MemePol` endpoint 配置权（owner == delegate） | 继承 OApp/OFT 的 5 个 `onlyOwner` endpoint 配置 setter；initialize 时 owner 与 delegate 均设为 launcher，故部署后 launcher 作为 owner == delegate 持有该配置权 | `setPeer`（`OutrunOAppCoreInit.sol::setPeer`）, `setDelegate`（`OutrunOAppCoreInit.sol::setDelegate`）, `setMsgInspector`（`src/common/omnichain/oft/OutrunOFTCoreInit.sol::setMsgInspector`）, `setEnforcedOptions`（`OutrunOAppOptionsType3Init.sol::setEnforcedOptions`，当前未启用：全仓零生产调用、`enforcedOptions` 恒空、所有 OFT 发送路径原样透传 caller `_extraOptions` 不校验类型）, `setPreCrime`（`OutrunOAppPreCrimeSimulatorInit.sol::setPreCrime`）；owner/delegate initialize 写入见 `Memecoin.sol::initialize`, `MemePol.sol::initialize` |
| `MemePol.setPoolId` 可重设 | ACL 仍仅 launcher（`onlyMemeverseLauncher`）；但函数体裸写 `poolId = _poolId`，无 one-shot guard，launcher 可多次调用覆盖 | `MemePol.sol::setPoolId` |
| `MemecoinYieldVault` | `accumulateYields` / `deposit` / `mint` / `reAccumulateYields` 为 permissionless 业务入口（非 owner 门禁；`reAccumulateYields` 是未执行 yield compose 的恢复入口，委托 `YieldDispatcherUpgradeable.settlePendingCompose`）；`requestRedeem` 同样非 owner 门禁，但仅允许自我赎回：`controller == msg.sender && owner == msg.sender`，否则 revert `NotSelfRedemption()`；claim 入口 `redeem` / `withdraw` 同样仅允许自我赎回（`owner == msg.sender`），`receiver` 可任意指定为收款方，但不支持 `owner != msg.sender`：份额在 `requestRedeem` 时已烧，无 allowance 路径，第三方 `owner` 会盗取已锁资产，故 revert `NotSelfRedemption()` | `src/yield/MemecoinYieldVault.sol::accumulateYields`, `::deposit`, `::mint`, `::requestRedeem`, `::redeem`, `::withdraw`, `::reAccumulateYields` |
| `YieldDispatcherUpgradeable` | `distributeSameChain` 仅 `memeverseLauncher`；`lzCompose` 仅 `localEndpoint`；`settlePendingCompose` permissionless（接收方从 `message` 解码，任何人可调，经 `composeStates` 互斥）；`setProtocolTreasury` 与升级（`_authorizeUpgrade`）均仅 owner | `src/verse/YieldDispatcherUpgradeable.sol::distributeSameChain`, `::lzCompose`, `::settlePendingCompose`, `::setProtocolTreasury`, `::_authorizeUpgrade` |
| `OmnichainMemecoinStaker` | `lzCompose` 仅 `localEndpoint`；`settlePendingCompose` 仅接收人（`receiver == msg.sender`，receiver 从 hash 绑定的 `message` 解码，防第三方 front-run 抢占） | `src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`, `::settlePendingCompose` |
| `MemeverseRegistrationCenter` dispatcher 封装 | `lzSend` 仅合约自身可调用；`_lzReceive` 校验 origin.sender 为 registrar | `src/verse/registration/MemeverseRegistrationCenter.sol::lzSend`, `::_lzReceive` |
| `MemeverseOmnichainInteroperation` | staking 入口 permissionless；`setGasLimits` 仅 owner | `src/interoperation/MemeverseOmnichainInteroperation.sol::memecoinStaking`, `::setGasLimits` |
| `MemecoinDaoGovernorUpgradeable` | treasury 支出与升级授权仅治理执行；reward payout 资产由 governor 托管，`disburseReward(...)` 为 `Incentivizer` 专用 payout 路径 | [docs/spec/governance/governance-yield-details.md](governance/governance-yield-details.md); [docs/spec/verse/accounting.md](verse/accounting.md) |
| `GovernanceCycleIncentivizerUpgradeable` | `recordTreasuryIncome(...)` / `recordTreasuryAssetSpend(...)` 仅 governor；`claimReward()` 为用户入口；`syncTreasuryBalance(...)` 与 `finalizeCurrentCycle()` 可 permissionless | [docs/spec/governance/governance-yield-details.md](governance/governance-yield-details.md); [docs/spec/verse/accounting.md](verse/accounting.md); [docs/spec/access-control.md](access-control.md) |
| `GenesisCredit` `[代码已证]` | `claim(...)` permissionless（merkle proof 校验，单点写入 home 链防重复领）；`burn(uint256)` permissionless 自烧（持币人标准 ERC20 burn 路径，POLendUpgradeable finalize 托管 GenesisCredit 也走该路径）；`setMerkleRoot(...)` 仅 GenesisCredit owner 可直接调用，owner 为部署时传入 `deployCredit(..., delegate)` 的 `delegate`，或后续 `transferOwnership` 后的新 owner | [docs/spec/polend/core.md](polend/core.md); `src/credit/GenesisCredit.sol::claim`, `src/credit/GenesisCredit.sol::burn`, `src/credit/GenesisCredit.sol::setMerkleRoot` |
| `GenesisCreditFactory` `[代码已证]` | `deployCredit(uAsset, name, symbol, delegate)` owner-only（per-uAsset CREATE3 salt = `keccak256(abi.encode(uAsset))`，本链确定性地址（跨链同址需 factory+uAsset 均跨链同址，非合约保证），`delegate` 成为对应 GenesisCredit 初始 owner）；`creditOf(uAsset)` view，任意地址可读，用于取得对应 GenesisCredit 地址 | [docs/spec/polend/core.md](polend/core.md); `src/credit/GenesisCreditFactory.sol::deployCredit`, `src/credit/GenesisCreditFactory.sol::creditOf` |
| `POLendUpgradeable.leveragedGenesisWithCredit` `[代码已证]` | 用户入口，permissionless；受 Launcher verse `Genesis` 阶段、market state（`None / Genesis`）、该 `uAsset` 已完成全局 reserve 配置且 `GenesisCreditFactory` 已部署对应 GenesisCredit、pause 约束；`creditAmount > 0`；累计 `nextTotalLeveragedInterest -> previewDebt` 吃 debt cap（real + credit 合计） | [docs/spec/polend/genesis.md §4.1](polend/genesis.md); `src/polend/POLendUpgradeable.sol::leveragedGenesisWithCredit` |
| `POLendUpgradeable.setCreditFactory` `[代码已证]` | owner-only，替换 `GenesisCreditFactory` 地址指针（用于按 `uAsset` 查 GenesisCredit 地址）；emit `CreditFactoryChanged(old, new)` | [docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md); `src/polend/POLendUpgradeable.sol::setCreditFactory` |

### 3.1 Smart EOA transient session 权限边界 `[代码已证]`

- 合约账户 `A` 直接调用 Hook 的 `beginAccountSession()` 时，Hook 仅从 `msg.sender` 捕获 active principal `A`。写入前必须同时满足 `activePrincipal == address(0)` 与 `swapContextDepth() == 0`；任一不满足都必须拒绝，不能覆盖或继承残留 context。`msg.sender.code.length != 0` 只排除传统 EOA，不是账户认证或白名单；具有 delegated code 的 EIP-7702 账户仍可满足该条件。
- `A` 必须在同一不可捕获、全成全败的执行 frame 内经任意单一经济账户 Router 执行，再由 `A` 调用 Hook 的 `endAccountSession()`。`end` 只能由 active principal `A` 调用；省略 `end` 不会让该笔交易失败——交易结束时 EIP-1153 transient storage 自动清零 `activePrincipal`。但若同一外层交易后续还有账户（如 V）要 `beginAccountSession()`，省略 `end` 会让 V 的 `begin` 回退 `AccountSessionAlreadyActive`；因此多账户串行（如 bundler `handleOps([A, V])`）A 必须显式 `end`。`beforeSwap` / `afterSwap` 只可使用尚未结束的 active session context 中的 principal。
- Router 地址、`hookData`、PoolManager callback caller、`tx.origin` 与 Universal Router 的 `msgSender` 都不是 principal 来源。该模型不增加 Router allowlist / trust、签名、EIP-712、ERC-1271、principal 参数、持久状态或 session begin/end event。
- `MemeverseYTFlashSwapRouter` `[代码已证]` 复用同一 active session principal：它不自行 `beginAccountSession`/`endAccountSession`，而是在每个用户入口的资金动作前要求 `hook.activeAccountSessionPrincipal() == msg.sender`。因此 smart-account/Safe/EIP-7702 原子 frame `begin -> YTFlashSwapRouter -> end` 的 principal 必须一致，SDK Lens trader 也必须是同一地址；详见 [swap/yt-flash-swap.md §6](swap/yt-flash-swap.md) 与 INV-24。

## 4. Governance Reward Path 边界

- `Governor.sendTreasuryAssets(...)` 属于治理执行权限路径。
- `Governor.disburseReward(...)` 不属于治理执行权限路径，而是 `Incentivizer` 驱动的受限 payout 路径。
- `Governor.disburseReward(...)` 仅允许配对的 `Incentivizer` 调用。
- `Incentivizer.recordTreasuryIncome(...)` 仅允许 `Governor` 调用。
- `Incentivizer.recordTreasuryAssetSpend(...)` 仅允许 `Governor` 调用。
- `Incentivizer.syncTreasuryBalance(...)` 可由任意调用者调用（permissionless）；该函数为纯账本对账，synced 值由 governor 实际托管余额与上一周期未领 reward 储备确定性导出，调用者无法控制结果，不转移 token。
- `Incentivizer.claimReward()` 属于用户业务入口，不受 `onlyGovernance` 限制。
- `Incentivizer.claimReward()` 必须以 `msg.sender` 作为 reward owner，不能把 `Governor`、治理执行者或其他中间调用者视为 reward owner。
- `Incentivizer.claimReward()` 第一版仅支持 self-claim，不支持指定 `receiver`，不支持代领。
- 若 `finalizeCurrentCycle()` 保持 permissionless，则其开放性仅限于推进周期状态，不应削弱 treasury custody 与 reward claim 的权限边界。

## 5. 与当前规则文档的对齐

- Launcher 的 owner / registrar / governor / permissionless 边界与 [docs/spec/protocol.md](protocol.md)、[docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- Swap 的“Router 公开入口 + Hook 核心引擎 + 显式 `Launcher -> Hook` preorder settlement 路径”与 [docs/spec/protocol.md](protocol.md)、[docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- Router / Hook / Launcher 绑定的三重校验与 write-once 语义见 [docs/spec/invariants.md](invariants.md) INV-04（启动结算显式路径与三重校验不变量）；`launcher` 由 hook `initialize` 一次性固化（initializer write-once），不可 retarget。
- 注册中心和 registrar 的边界与 [docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- diamond 后 Hook owner 的 facet 逻辑替换（`setFacet`）与 facet 防直调（`onlyViaRouter`）见本节矩阵；升级机制细节见 [docs/spec/upgradeability.md](upgradeability.md)。

## 6. 确定性边界

- 高确定性：函数级访问控制（`onlyOwner` / `require(msg.sender==...)`）可直接由源码证实。
- 中确定性：治理链上“最终权限持有地址”依赖部署清单，不在本仓库源码内。
