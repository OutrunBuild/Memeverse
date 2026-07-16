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
  - 主要是 OpenZeppelin `Ownable` 或 Outrun `OutrunOwnableInit` 的 `onlyOwner`。
  - 证据：`src/verse/MemeverseLauncher.sol::setMemeverseSwapRouter`, `src/swap/MemeverseUniswapHook.sol::setTreasury`, `src/interoperation/MemeverseOmnichainInteroperation.sol::setGasLimits`
- `registrar`
  - launcher 侧为 `memeverseRegistrar` 地址；注册中心与 local/omnichain registrar 构成上游链路。
  - 证据：`src/verse/MemeverseLauncher.sol::registerMemeverse`(facade 入口), `src/verse/MemeverseLaunchImpl.sol::registerMemeverse`(registrar ACL + body), `src/verse/registration/MemeverseRegistrarAtLocal.sol::localRegistration`
- `governor`
  - launcher 元数据更新与治理 treasury/upgrade 授权主体，同时也是 DAO treasury 与 reward payout 的唯一资产托管者。
  - 证据：`src/verse/MemeverseLauncher.sol::setExternalInfo`, `src/governance/MemecoinDaoGovernorUpgradeable.sol::propose`, `src/governance/MemecoinDaoGovernorUpgradeable.sol::sendTreasuryAssets`
- `permissionless caller`
  - 未加 owner/role 白名单，仅靠阶段/参数约束。
  - 证据：`src/verse/MemeverseLauncher.sol::genesis`, `src/verse/MemeverseLauncher.sol::preorder`, `src/yield/MemecoinYieldVault.sol::accumulateYields`
- `external dispatcher / endpoint caller`
  - 仅允许 LayerZero endpoint、launcher 或合约自身的调度入口。
  - 证据：`src/verse/YieldDispatcher.sol::lzCompose`, `src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`, `src/verse/registration/MemeverseRegistrationCenter.sol::lzSend`

## 3. 边界矩阵（源码锚点）

| Surface | 权限边界 | 证据 |
| --- | --- | --- |
| `MemeverseLauncher` 配置面 | `set*`、`pause/unpause`、`removeGasDust` 为 `onlyOwner` | `src/verse/MemeverseLauncher.sol::setMemeverseSwapRouter`, `::setMemeverseUniswapHook`, `::setLzEndpointRegistry`, `::setMemeverseRegistrar`, `::setMemeverseProxyDeployer`, `::setYieldDispatcher`, `::setFundMetaData`, `::setExecutorRewardRate`, `::setPreorderConfig`, `::setGasLimits`, `::setLaunchImpl`, `::setSettlementImpl`, `::setLiquidityImpl`, `::setFeePreviewReader`, `::pause`, `::unpause`, `::removeGasDust` |
| `MemeverseLauncher.registerMemeverse` | 仅 `memeverseRegistrar` | `src/verse/MemeverseLauncher.sol::registerMemeverse`(facade 入口), `src/verse/MemeverseLaunchImpl.sol::registerMemeverse`(registrar ACL + body) |
| `MemeverseLauncher.setExternalInfo` | `governor` 或 `memeverseRegistrar` | `src/verse/MemeverseLauncher.sol::setExternalInfo` |
| Launcher 生命周期入口 | `genesis`/`changeStage`/`refund`/`claimNormalYT`/POLend `claimLeveragedYT`/`redeemAndDistributeFees` 等无白名单，靠阶段与输入校验；facade 保留入口级守卫（已注册 verse 校验与 `impl != 0`；`genesis`/`claimNormalYT`/`redeemAndDistributeFees` 另受 `whenNotPaused` 保护；`changeStage`/`refund` 故意保持 pause 期间可执行），stage/claim/fee body 在 delegatecall sibling（`MemeverseLaunchImpl` / `MemeverseSettlementImpl`）内 | `src/verse/MemeverseLauncher.sol::genesis`(facade), `src/verse/MemeverseLaunchImpl.sol::genesis`(body), `src/verse/MemeverseLauncher.sol::changeStage`(facade), `src/verse/MemeverseLaunchImpl.sol::changeStage`(Genesis→Locked/Refund), `src/verse/MemeverseSettlementImpl.sol::unlockFromLocked`(Locked→Unlocked), `src/verse/MemeverseLauncher.sol::refund`(facade), `src/verse/MemeverseSettlementImpl.sol::refund`(body), `src/verse/MemeverseLauncher.sol::claimNormalYT`(facade), `src/verse/MemeverseSettlementImpl.sol::claimNormalYT`(body), `src/verse/MemeverseLauncher.sol::redeemAndDistributeFees`(entry checks), `src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees`(fee body), `src/polend/POLend.sol::claimLeveragedYT` |
| `POLend` 杠杆创世与配置 | `leveragedGenesis` 为用户入口，靠 Launcher Genesis 阶段、累计 debt cap 与 aggregate genesis funds 上限约束；`setLeveragedDebtFactor` 为 owner-only，并受 `uint128.max * 1e18` 技术上限约束 | `src/polend/POLend.sol::leveragedGenesis`, `::setLeveragedDebtFactor` |
| `MemeverseRegistrationCenter` | `registration` 对外开放；参数配置和 gas dust 清理是 `onlyOwner` | `src/verse/registration/MemeverseRegistrationCenter.sol::registration`, `::removeGasDust`, `::setSupportedUAsset`, `::setDurationDaysRange`, `::setRegisterGasLimit` |
| `MemeverseRegistrarAtLocal` | `localRegistration` 仅 center；`setRegistrationCenter` 仅 owner | `src/verse/registration/MemeverseRegistrarAtLocal.sol::localRegistration`, `::setRegistrationCenter` |
| `MemeverseRegistrarOmnichain` | `setRegistrationGasLimit` 仅 owner | `src/verse/registration/MemeverseRegistrarOmnichain.sol::setRegistrationGasLimit` |
| `MemeverseSwapRouter` | `quote/swap/addLiquidity/removeLiquidity` 等用户路由入口为 permissionless；`previewClaimableFees(...)` 仅为只读预览 helper；pool bootstrap `createPoolAndAddLiquidity(...)` 仅当前 launcher 可调用；不承载 launch-settlement 特权授权；launcher 配置时需校验其 `hook` 绑定 | `src/swap/MemeverseSwapRouter.sol::quoteSwap`, `::swap`, `::addLiquidity`, `::removeLiquidity`, `::previewClaimableFees`, `::createPoolAndAddLiquidity`, `onlyLauncher` (modifier) |
| `MemeverseUniswapHook` | 核心 `addLiquidityCore/removeLiquidityCore/claimFeesCore/claimRebate` 对外开放；其中 `claimFeesCore` 与 `claimRebate` 虽可外部调用，但仅支持 self-claim：owner 由 `msg.sender` 推导（LP fee owner 对应 `claimFeesCore`，referrer 对应 `claimRebate`），`recipient` 仅为 payout destination，不存在 owner 参数，也不支持 nonce / deadline / signature / 第三方 relayed claim；owner 配置与逻辑替换：`setTreasury` / `setLauncher` / `setPoolInitializer` / `setLpTokenImplementation` / `setProtocolFeeCurrency` / `setReferrerRebateBps` / `setDefaultLaunchFeeConfig` / `setFacet` 为 `onlyOwner`；`executePreorderSettlement(...)` 与 pair-based `setPublicSwapResumeTime(address,address,uint40)` 仅当前 launcher；三 facet（`SwapFacet` / `DynamicFeeFacet` / `SettlementFacet`）logic 入口不是产品对外 API；Hook 的支持路径经 `DELEGATECALL` 调度，直接 `CALL` 回退 `DirectFacetCallForbidden`（`onlyViaRouter`）。`onlyViaRouter` 只区分 direct `CALL` 与 `delegatecall`，不认证 delegatecall 宿主一定是本 Hook；`beforeSwap` 读取 pool-level resume time 执行公开 swap 保护 | `src/swap/MemeverseUniswapHook.sol::addLiquidityCore`, `::removeLiquidityCore`, `::claimFeesCore`, `::claimRebate`, `::_claimFees`, `::setTreasury`, `::setFacet`, `onlyOwner` (modifier), `onlyLauncher` (modifier), `::executePreorderSettlement`, `::setPublicSwapResumeTime`, `src/swap/FacetGuard.sol::onlyViaRouter`, `src/swap/SwapFacet.sol::beforeSwapLogic`, `src/swap/SwapFacet.sol::_revertIfPublicSwapBlocked` |
| `Memecoin` | `mint` 仅 launcher；`burn` 自主 | `src/token/Memecoin.sol::mint`, `::burn` |
| `MemePol` | `setPoolId` 与 `mint` 仅 launcher；`burn` 为持币人或 allowance 授权方 | `src/token/MemePol.sol::setPoolId`, `::mint`, `::burn`, `onlyMemeverseLauncher` (modifier) |
| `MemecoinYieldVault` | `accumulateYields` / `deposit` / `requestRedeem` / `executeRedeem` 为 permissionless 业务入口（非 owner 门禁） | `src/yield/MemecoinYieldVault.sol::accumulateYields`, `::deposit`, `::requestRedeem`, `::executeRedeem` |
| `YieldDispatcher` | `lzCompose` 仅 `localEndpoint` 或 `memeverseLauncher` | `src/verse/YieldDispatcher.sol::lzCompose` |
| `OmnichainMemecoinStaker` | `lzCompose` 仅 `localEndpoint` | `src/interoperation/OmnichainMemecoinStaker.sol::lzCompose` |
| `MemeverseRegistrationCenter` dispatcher 封装 | `lzSend` 仅合约自身可调用；`_lzReceive` 校验 origin.sender 为 registrar | `src/verse/registration/MemeverseRegistrationCenter.sol::lzSend`, `::_lzReceive` |
| `MemeverseOmnichainInteroperation` | staking 入口 permissionless；`setGasLimits` 仅 owner | `src/interoperation/MemeverseOmnichainInteroperation.sol::memecoinStaking`, `::setGasLimits` |
| `MemecoinDaoGovernorUpgradeable` | treasury 支出与升级授权仅治理执行；reward payout 资产由 governor 托管，`disburseReward(...)` 为 `Incentivizer` 专用 payout 路径 | [docs/spec/governance/governance-yield-details.md](governance/governance-yield-details.md); [docs/spec/verse/accounting.md](verse/accounting.md) |
| `GovernanceCycleIncentivizerUpgradeable` | `recordTreasuryIncome(...)` / `recordTreasuryAssetSpend(...)` 仅 governor；`claimReward()` 为用户入口；`finalizeCurrentCycle()` 可 permissionless | [docs/spec/governance/governance-yield-details.md](governance/governance-yield-details.md); [docs/spec/verse/accounting.md](verse/accounting.md); [docs/spec/access-control.md](access-control.md) |
| `GenesisCredit` `[代码已证]` | `claim(...)` permissionless（merkle proof 校验，单点写入 home 链防重复领）；`burn(uint256)` permissionless 自烧（持币人标准 ERC20 burn 路径，POLend finalize 托管 GenesisCredit 也走该路径）；`setMerkleRoot(...)` 仅 GenesisCredit owner 可直接调用，owner 为部署时传入 `deployCredit(..., delegate)` 的 `delegate`，或后续 `transferOwnership` 后的新 owner | [docs/spec/polend/core.md](polend/core.md); `src/credit/GenesisCredit.sol::claim`, `src/credit/GenesisCredit.sol::burn`, `src/credit/GenesisCredit.sol::setMerkleRoot` |
| `GenesisCreditFactory` `[代码已证]` | `deployCredit(uAsset, name, symbol, delegate)` owner-only（per-uAsset CREATE3 salt = `keccak256(abi.encode(uAsset))`，本链确定性地址（跨链同址需 factory+uAsset 均跨链同址，非合约保证），`delegate` 成为对应 GenesisCredit 初始 owner）；`creditOf(uAsset)` view，任意地址可读，用于取得对应 GenesisCredit 地址 | [docs/spec/polend/core.md](polend/core.md); `src/credit/GenesisCreditFactory.sol::deployCredit`, `src/credit/GenesisCreditFactory.sol::creditOf` |
| `POLend.leveragedGenesisWithCredit` `[代码已证]` | 用户入口，permissionless；受 Launcher verse `Genesis` 阶段、market state（`None / Genesis`）、该 `uAsset` 已完成全局 reserve 配置且 `GenesisCreditFactory` 已部署对应 GenesisCredit、pause 约束；`creditAmount > 0`；累计 `nextTotalLeveragedInterest -> previewDebt` 吃 debt cap（real + credit 合计） | [docs/spec/polend/genesis.md §4.1](polend/genesis.md); `src/polend/POLend.sol::leveragedGenesisWithCredit` |
| `POLend.setCreditFactory` `[代码已证]` | owner-only，替换 `GenesisCreditFactory` 地址指针（用于按 `uAsset` 查 GenesisCredit 地址）；emit `CreditFactoryChanged(old, new)` | [docs/spec/polend/settlement-and-fees.md](polend/settlement-and-fees.md); `src/polend/POLend.sol::setCreditFactory` |

## 4. Governance Reward Path 边界

- `Governor.sendTreasuryAssets(...)` 属于治理执行权限路径。
- `Governor.disburseReward(...)` 不属于治理执行权限路径，而是 `Incentivizer` 驱动的受限 payout 路径。
- `Governor.disburseReward(...)` 仅允许配对的 `Incentivizer` 调用。
- `Incentivizer.recordTreasuryIncome(...)` 仅允许 `Governor` 调用。
- `Incentivizer.recordTreasuryAssetSpend(...)` 仅允许 `Governor` 调用。
- `Incentivizer.claimReward()` 属于用户业务入口，不受 `onlyGovernance` 限制。
- `Incentivizer.claimReward()` 必须以 `msg.sender` 作为 reward owner，不能把 `Governor`、治理执行者或其他中间调用者视为 reward owner。
- `Incentivizer.claimReward()` 第一版仅支持 self-claim，不支持指定 `receiver`，不支持代领。
- 若 `finalizeCurrentCycle()` 保持 permissionless，则其开放性仅限于推进周期状态，不应削弱 treasury custody 与 reward claim 的权限边界。

## 5. 与当前规则文档的对齐

- Launcher 的 owner / registrar / governor / permissionless 边界与 [docs/spec/protocol.md](protocol.md)、[docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- Swap 的“Router 公开入口 + Hook 核心引擎 + 显式 `Launcher -> Hook` preorder settlement 路径”与 [docs/spec/protocol.md](protocol.md)、[docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- Router / Hook / Launcher 绑定的三重校验与 write-once 语义见 [docs/spec/invariants.md](invariants.md) INV-04（启动结算显式路径与三重校验不变量）；hook owner 后续 retarget `launcher` 仍属于同一 trust boundary 内的接受配置权。
- 注册中心和 registrar 的边界与 [docs/spec/verse/state-machines.md](verse/state-machines.md) 一致。
- diamond 后 Hook owner 的 facet 逻辑替换（`setFacet`）与 facet 防直调（`onlyViaRouter`）见本节矩阵；升级机制细节见 [docs/spec/upgradeability.md](upgradeability.md)。

## 6. 确定性边界

- 高确定性：函数级访问控制（`onlyOwner` / `require(msg.sender==...)`）可直接由源码证实。
- 中确定性：治理链上“最终权限持有地址”依赖部署清单，不在本仓库源码内。
