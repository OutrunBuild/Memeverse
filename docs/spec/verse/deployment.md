# Memeverse 部署拓扑与初始化事实

## 1. 说明

本文记录当前“代码可证”的部署与初始化关系。
标签说明：

- `[代码已证]`：源码与脚本可直接定位
- `[未知]`：仓库没有最终部署实参/清单

## 2. 顶层部署拓扑（按合约角色）

### 2.1 基础常驻组件

- `LzEndpointRegistry`：`chainId -> endpointId` 映射注册表。`[代码已证]`
- `MemeverseRegistrationCenterUpgradeable`：中心链注册入口与 fan-out；现为 UUPS（`ERC1967Proxy`）部署，基于 LayerZero upgradeable OApp 基座（`OAppUpgradeable`，remapping `@layerzerolabs/oapp-evm-upgradeable/=lib/devtools/packages/oapp-evm-upgradeable/`），`lzEndpoint` 烧入 implementation 构造器。`[代码已证]`
- `MemeverseRegistrarAtLocal` 或 `MemeverseRegistrarOmnichain`：注册执行层。`[代码已证]`
- `MemeverseLauncherUpgradeable`：verse 生命周期与资金总编排；当前为 `IOutrunDeployer` CREATE3 部署的 `ERC1967Proxy + UUPS` proxy。`[代码已证]`
- `MemeverseLaunchImpl`：launch 生命周期 delegatecall sibling；Launcher facade 经 `delegatecall` 调用的纯逻辑合约，与 Launcher 共享同一 ERC-7201 storage namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行 registerMemeverse / genesis / preorder / `changeStage` stage dispatcher / 治理组件部署编排。本身非 proxy（无 `Initializable`、无自身 storage），部署期由 owner `setLaunchImpl` 接线。`[代码已证]`
- `MemeverseSettlementImpl`：settlement / claim / fee 分发 delegatecall sibling；与 Launcher 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行 fee 收集/分发（redeem fee 捕获、POL burn、executor reward 拆分、同链/跨链分发）、refund / refundPreorder / claimNormalYT / claimNormalFees / claimUnlockedPreorderMemecoin / `redeemAndDistributeFees`、Locked→Unlocked 解算编排（`unlockFromLocked`）、post-unlock 公开 swap 保护。本身非 proxy、无自身 storage，部署期由 owner `setSettlementImpl` 接线。`[代码已证]`
- `MemeverseLiquidityImpl`：bootstrap 流动性 / POL mint / LP 赎回 delegatecall sibling；与 Launcher 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行主池+三辅助池创建、preorder settlement 接线、residual 处置、`mintPOLToken`、`redeemAuxiliaryLiquidity`、`settleLeveragedAuxiliaryLiquidity`、`redeemMemecoinLiquidity`、LP helper。本身非 proxy、无自身 storage，部署期由 owner `setLiquidityImpl` 接线。`[代码已证]`
- `MemeverseFeePreviewReader`：fee 预览独立 view 合约（genesis maker fee 预览、fee 分发 LayerZero fee 报价）；通过 immutable `PROXY` staticcall proxy getter 读状态，不绑名域、不被 delegatecall、不改 proxy storage。构造注入 proxy 地址，部署期由 owner `setFeePreviewReader` 接线。`[代码已证]`
- `MemeverseProxyDeployer`：per-verse clone/proxy 部署器。`[代码已证]`
- `YieldDispatcherUpgradeable`：收益 OFT compose 分发器。`[代码已证]`
- `MemeverseOmnichainInteroperation` + `OmnichainMemecoinStakerUpgradeable`：跨链 staking 路径；staker 现为 UUPS（`ERC1967Proxy`）部署，interoperation 仍为构造部署。`[代码已证]`
- `MemeverseUniswapHookUpgradeable` + `MemeverseSwapRouter`：swap/liquidity 核心与外围；`hookProxy`（真正的 v4 hook 地址）与 `hookImplementation` 同为部署脚本返回的 first-class deployment artifact。`[代码已证]`
- `lpTokenImplementation`：per-pool LP token clone 模板，是部署脚本返回的 first-class deployment artifact。`[代码已证]`
- `SwapFacet` / `DynamicFeeFacet` / `SettlementFacet`：hook 的 3 个 delegatecall facet（callback logic / dynamic fee state / preorder settlement），是部署脚本返回的 first-class deployment artifact。`[代码已证]`

### 2.2 实现合约与按 verse 实例化组件

- 实现合约（模板）：
 - `Memecoin`、`MemePol`、`MemecoinYieldVault`
 - `MemecoinDaoGovernorUpgradeable`、`GovernanceCycleIncentivizerUpgradeable`
- 按 `verseId(uniqueId)` 实例化：
 - memecoin/POL/yieldVault：最小代理（cloneDeterministic）
 - governor/incentivizer：`ERC1967Proxy + Create2`

以上为 `[代码已证]`。

## 3. 初始化与依赖顺序（代码路径）

### 3.1 注册阶段

注册阶段的 launcher 侧 7 步执行序列（权限校验、deployer 部署并初始化 memecoin/POL、`setPeer`、verse 基础信息与反向索引、`POLendUpgradeable.registerLendMarket`、`RegisterMemeverse`、后续 `setExternalInfo`）见 [docs/spec/verse/registration-details.md](registration-details.md) §10。

`POLendUpgradeable.registerLendMarket` 使用当前默认 `interestRate / leveragedDebtFactor`，其中 `leveragedDebtFactor` 已在初始化与 setter 侧受 `uint128.max * 1e18` 技术上限约束。`[代码已证]`

以上为 `[代码已证]`。

### 3.2 `Genesis -> Locked` 时的部署动作

1. launcher 判断是否达标并进入 `_deployAndSetupMemeverse`
2. 若 `getTotalLeveragedDebt(verseId) > 0`，launcher 调用 `POLendUpgradeable.finalizeLeveragedGenesis(verseId)`
3. launcher 调用 `POLSplitterUpgradeable.initializeVerse`
4. launcher 在主池建池后把主池实际 `uAsset` / POL raw 写入 `POLSplitterUpgradeable.recordPTBackingRatio(...)`
5. launcher 调用 `POLSplitterUpgradeable.split(...)` 产出 PT/YT，并把杠杆侧初始 YT 转给 `POLendUpgradeable`
6. launcher 按 POLendUpgradeable 四池模型创建 `memecoin/uAsset` 主池与 `POL/uAsset`、`PT/uAsset`、`PT/POL` 三个辅助池，必要时通过 `hook.executePreorderSettlement(...)` 完成 preorder 结算
7. 若治理链是本链：
 - deployer 部署并初始化 `yieldVault/governor/incentivizer`
 - governor 与 incentivizer 经 `Create2 + ERC1967Proxy` 同 salt 不同 init code 部署、同交易内 governor 先 `initialize`（带 incentivizer 地址）后 incentivizer `initialize`（带 governor 地址）解开互引循环；同 salt 无碰撞前提、`_unsafeAllowUninitialized` 语义与互引序详见 [upgradeability.md §4](../upgradeability.md)
 - `yieldVault.initialize` 的参数清单与虚拟资产缓冲（`virtualAssets`）的语义见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md) §4.1；本链分支由 `MemeverseLaunchImpl.sol::_deployGovernanceComponents` 经 `MemeverseLauncherLib.virtualAssetsBuffer(minTotalFund, fundBasedAmount)` 计算后传入 `initialize` 的 `_virtualAssets` 形参，`ZeroVirtualAssets`（`MemecoinYieldVault.sol::initialize`）与 `VirtualAssetsTooLow`（`MemeverseLauncherUpgradeable.sol::setFundMetaData`）双重强制 > 0。`[代码已证]`
8. 若治理链非本链：
 - 仅预测 `yieldVault/governor/incentivizer` 地址，不在本链初始化

以上动作发生在同一笔 `changeStage` 交易内；任一步失败都会回滚整笔 `Genesis -> Locked` 迁移。
进入该部署路径前，普通创世与杠杆创世受聚合资金上限约束（预检条件与 preorder 口径排除见 [polend/genesis.md §3](../polend/genesis.md)）。`[代码已证]`

以上为 `[代码已证]`。

## 4. 关键部署依赖事实

- Launcher 配置 router / hook 时的 set-time 三重校验与 write-once 语义见 [docs/spec/invariants.md](../invariants.md) INV-04；`Genesis -> Locked` 执行建池前会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
- `Genesis -> Locked` 的 bootstrap 流动性部署由 `MemeverseLaunchImpl`（`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`）经 `delegatecall` 委托 `MemeverseLiquidityImpl`（`src/verse/MemeverseLiquidityImpl.sol::deployBootstrapLiquidity` / `src/verse/interfaces/IMemeverseLiquidityImpl.sol::deployBootstrapLiquidity`）。sibling 与 Launcher facade 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行；sibling 地址由 owner `setLiquidityImpl` 配置（`src/verse/MemeverseLauncherUpgradeable.sol::setLiquidityImpl`），未配置时 `Genesis -> Locked` 回退 `LiquidityImplNotSet`。`[代码已证]`
- fee 分发的 delegatecall 委托路径：Launcher facade `::redeemAndDistributeFees`（`src/verse/MemeverseLauncherUpgradeable.sol::redeemAndDistributeFees`）与 `changeStage` 的 Locked→Unlocked 分支（`::unlockFromLocked`）经 `delegatecall` 委托 `MemeverseSettlementImpl`（`src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees` / `::unlockFromLocked`）。sibling 地址由 owner `setSettlementImpl` 配置（`src/verse/MemeverseLauncherUpgradeable.sol::setSettlementImpl`），未配置时 delegatecall 前置点回退 `SettlementImplNotSet`。sibling 与 Launcher 共享同一 ERC-7201 namespace 与 struct，在 proxy storage 上下文执行。`[代码已证]`
- `polend` 与 `polSplitter` 都是 Launcher proxy 初始化写入的必需接线，当前代码不存在 unset 或运行中换地址路径。注册、创世部署、fee preview/claim、unlock settlement 都直接依赖这两个固定地址。`[代码已证]`
- 具体接线语义：
  - `polend`：注册时 `registerLendMarket`，部署时 `finalizeLeveragedGenesis`，Locked governor PT fee 预兑付时 `preRedeemPTFee`，unlock settlement 时按需 `executeGlobalSettlement`
  - `polSplitter`：部署时 `initializeVerse`、`recordPTBackingRatio`、`split`，normal/gov PT fee preview 时 `previewPTToUAsset`，settled 后 PT 兑现时 `redeemPT`，unlock settlement 时 `settle`
- `launcher` 由 hook `initialize` 一次性固化（initializer write-once），不可 retarget；与 launcher 侧 `setMemeverseUniswapHook` write-once 对称。`[代码已证]`
- 部署 runbook 注意（write-once 固有代价）：广播 hook proxy 部署（`initialize` 绑定 `launcher_`）前，必须确认 `MEMEVERSE_LAUNCHER` env var 解析为预期的**已部署** launcher proxy——部署脚本 `run(uint256)` 仅校验该 env `!= 0`，未校验 `code.length` 或 launcher 身份；`initialize` 后若绑错地址（EOA / 错误合约），hook 的所有 `onlyLauncher` 流程（`executePreorderSettlement` / `setPublicSwapResumeTime`）永久失效，UUPS `_initialized` 已置 `1` 锁定、无链上恢复路径（引入 rescue 会重新打开 hook retarget 攻击面）。兜底检测点：launcher 侧 `MemeverseLauncherUpgradeable.sol::setMemeverseUniswapHook` 的 back-pointer 校验 `hook.launcher() == address(this)` 在 launcher 配线时 revert，暴露 hook 侧 binding 错配，须在 launcher 打开 registration 前完成该项配线以触发该校验。`[代码已证]`
- Launcher 与所有直接继承 `ReentrancyGuardTransient` 的合约（`TokenHelper`、`POLendUpgradeable`、`POLSplitterUpgradeable`、`MemeverseUniswapHookUpgradeable`、`MemeverseYTFlashSwapRouter`）依赖 EIP-1153 transient storage（`tload`/`tstore` 操作码），编译目标 `evm_version = "prague"`。部署链必须支持 Cancun 或更新硬分叉，否则 `nonReentrant` 修饰符将导致 `invalid opcode` 回退。见 [docs/operations.md](../../operations.md#6-evm-兼容性要求)。`[代码已证]`
- 跨链分发与 staking 的 gas 参数来自 launcher/interoperation 的可配置 gas limits。`[代码已证]`
- `MemeverseProxyDeployer.quorumNumerator` 仅影响后续新部署 governor 初始化，不回溯既有实例。`[代码已证]`
- composer 系与 token/registration 部署函数（`MemeverseScript._deployYieldDispatcher` / `_deployOmnichainMemecoinStaker` / `_deployMemeverseOmnichainInteroperation` / `_deployImplementation` / `_deployMemecoinPOLImplementation` / `_deployRegistrationCenter` / `_deployMemeverseRegistrar`）对各自烘焙进 immutable/构造参数的值前置 require 非零（并集，非每个函数全查）：`localEndpoint` 于 6 个函数（`_deployYieldDispatcher` / `_deployOmnichainMemecoinStaker` / `_deployImplementation` / `_deployMemecoinPOLImplementation` / `_deployRegistrationCenter` / `_deployMemeverseRegistrar`，错误串 `ZERO_LOCAL_ENDPOINT`）、`MEMEVERSE_LAUNCHER` 于 `_deployYieldDispatcher`（`ZERO_MEMEVERSE_LAUNCHER`）、`PROTOCOL_TREASURY` 于 `_deployYieldDispatcher`（`ZERO_PROTOCOL_TREASURY`）、`OMNICHAIN_MEMECOIN_STAKER` 于 `_deployMemeverseOmnichainInteroperation`（`ZERO_OMNICHAIN_MEMECOIN_STAKER`）、CREATE3 部署器 `OUTRUN_DEPLOYER` 于 `_deployYieldDispatcher` / `_deployMemeverseOmnichainInteroperation` / `_deployOmnichainMemecoinStaker`（`ZERO_OUTRUN_DEPLOYER`）；零配置部署在部署期失败；`YieldDispatcherUpgradeable` 与 `OmnichainMemecoinStakerUpgradeable` 现为 UUPS（`ERC1967Proxy`）部署、构造器零参检查迁入 `initialize`（dispatcher 对 owner / localEndpoint / memeverseLauncher / protocolTreasury 四地址非零校验；staker 对 initialOwner / _localEndpoint 具名零检查），`MemeverseOmnichainInteroperation` 仍为构造部署、自身对 immutable 参数 revert `ZeroAddress()`；`_deployRegistrationCenter` 同 dispatcher 模式改为 impl + ERC1967Proxy 两步 CREATE3 部署（impl 构造参数含 `_lzEndpoint`，deploy+initialize 经 proxy constructor data 原子完成，镜像 `_deployYieldDispatcher`）；registrar 侧合约守卫是该路径唯一的零参防御——脚本侧 `_deployMemeverseRegistrar` 仅前置 `ZERO_LOCAL_ENDPOINT`，不检查 `_memeverseLauncher` / `_lzEndpointRegistry` 入参，`MemeverseRegistrarAbstract.sol::constructor` 的具名零检查（revert `ZeroAddress()`，两个叶子 registrar 继承同一守卫）同时兜底不经脚本、直接链上构造的零参部署。`[代码已证]`

## 5. Launcher 原生 gas dust 边界

- `MemeverseLauncherUpgradeable.removeGasDust(address receiver)` 是 owner-only 运维清理入口，用于转出 Launcher 合约上的 native balance。`[代码已证]`
- 该余额不是用户可 claim 资金，且与 `RegistrationCenter` gas dust 是不同边界。`[代码已证]`
- 目标边界：`redeemAndDistributeFees` 要求 `msg.value` 精确等于 required fee；本地分发、无跨链要求或无 fee 分发时 required fee 为 `0`。精确 native payment 下，费用分发不应产生预期 Launcher dust。
- 无 fee 分发时，`redeemAndDistributeFees` 在返回零值前必须拒绝非零 `msg.value`，避免误带 native value 留作 Launcher dust。`[代码已证]`
- 当前代码按实现行为描述，不额外声明 zero-address receiver 校验。`[代码已证]`

## 6. CREATE3 UUPS proxy 部署顺序

`IOutrunDeployer.getDeployed(deployCaller, salt)` 的 `deployCaller` 是后续实际调用 `deploy(...)` 的 CREATE3 命名空间，不是 `initialize(...)` 使用的 `initialOwner`。二者可以相同，但部署脚本拆分这两个概念：`deployCaller` 控制地址预测/部署命名空间，`initialOwner` 控制 proxy 初始化后的 owner 与 UUPS 升级权限。`[代码已证]`

**部署模式**

脚本支持两种部署模式：

- **单角色部署**（`deployCaller == initialOwner`，如同一 EOA 既部署又持有 owner）：脚本在部署过程中直接写入 `setFundMetaData`，并部署三个 delegatecall sibling `MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 与独立 view 合约 `MemeverseFeePreviewReader`，再调用 `launcher.setLaunchImpl(...)` / `launcher.setSettlementImpl(...)` / `launcher.setFeePreviewReader(...)` / `launcher.setLiquidityImpl(...)` 接线。四个 setter 彼此无顺序依赖；该顺序仅对齐当前部署脚本与 WARNING 文案，readiness check 只要求四者最终均已接线且有代码。readiness check 通过后即可打开 registration。`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployMemeverseLauncher, _setMemeverseLauncherFundMetaData`；`src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl`、`::setSettlementImpl`、`::setFeePreviewReader`、`::setLiquidityImpl`
- **双角色部署**（`deployCaller != initialOwner`，如 DevOps 负责部署、multisig 持有 owner）：脚本部署 proxy 并执行 `initialize`，但跳过 `setFundMetaData` 与 launch/settlement/fee-preview/liquidity 四个 setter 写入。`initialOwner` 必须在单独交易中调用 `launcher.setFundMetaData(...)`、`launcher.setLaunchImpl(...)`、`launcher.setSettlementImpl(...)`、`launcher.setFeePreviewReader(...)`、`launcher.setLiquidityImpl(...)`，完成后才能通过 readiness check 并打开 registration。脚本在检测到双角色部署时输出 console 警告。`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployMemeverseLauncher`（条件跳过 + 警告 log，文案为 `"WARNING: deployCaller(%s) != initialOwner(%s) -- fund metadata, launchImpl, settlementImpl, feePreviewReader and liquidityImpl must be set by initialOwner"`）

`MemeverseLauncherUpgradeable`、`POLendUpgradeable`、`POLSplitterUpgradeable` 由 `script/MemeverseScript.s.sol` 部署，不进 hook 的 `DeploymentResult`；`lpTokenImplementation`、3 facet（`SwapFacet`/`DynamicFeeFacet`/`SettlementFacet`）、`MemeverseUniswapHookUpgradeable` 的 implementation 与 proxy 由 `script/DeployMemeverseHookProxy.s.sol` 部署，全部使用同一 `DEPLOYMENT_NONCE` 派生各自 salt。后者输出的 `DeploymentResult` 必须把 `hookImplementation`、`hookProxy`、`lpTokenImplementation`、`swapFacet`、`dynamicFeeFacet`、`settlementFacet` 这 6 个地址作为 first-class fields 返回。其中 `hookProxy` 是真正的 v4 hook 地址，不能只把 lpToken/facet 当作内部临时地址。

本表是各合约 proxy / implementation salt label 与 canonical 地址的唯一事实表（operations.md §3.9.1 升级表中同名列以本表为准）。

| 合约 / artifact | Proxy salt label | Implementation / helper salt label | Canonical address |
| --- | --- | --- | --- |
| `MemeverseLauncherUpgradeable` | `MemeverseLauncher` | `MemeverseLauncherImplementation` | `getDeployed(deployCaller, launcherSalt)` 返回的 Launcher proxy |
| `POLendUpgradeable` | `POLend` | `POLendImplementation` | `getDeployed(deployCaller, polendSalt)` 返回的 `POLendUpgradeable` proxy |
| `POLSplitterUpgradeable` | `POLSplitter` | `POLSplitterImplementation` | `getDeployed(deployCaller, polSplitterSalt)` 返回的 `POLSplitterUpgradeable` proxy |
| `lpTokenImplementation` | N/A | `MemeverseUniswapLPTokenImplementation` | `DeploymentResult.lpTokenImplementation` |
| `SwapFacet` | N/A | `MemeverseSwapFacet` | `DeploymentResult.swapFacet` |
| `DynamicFeeFacet` | N/A | `MemeverseDynamicFeeFacet` | `DeploymentResult.dynamicFeeFacet` |
| `SettlementFacet` | N/A | `MemeverseSettlementFacet` | `DeploymentResult.settlementFacet` |
| `MemeverseUniswapHookUpgradeable` | mined（见下注） | `MemeverseUniswapHookImplementation` | proxy = `DeploymentResult.hookProxy`（真正 v4 hook 地址）；impl = `DeploymentResult.hookImplementation` |

> 注：`MemeverseUniswapHookUpgradeable` proxy salt 经 mining 搜索以满足 v4 hook flag（`(uint160(addr) & 0x3fff) == 0x28cc`），salt = `keccak256(abi.encodePacked("MemeverseUniswapHookProxy", nonce, i))`。`i` 由 `_selectProxySalt` 按链上 eligibility 选取（须 flag 命中；最终地址空且对应 CREATE3 中间槽未消耗 → 选用并 fresh 部署；最终地址有代码但 implementation 非本 nonce 预期 hook → 跳过该候选；完整同配置 same-nonce 部署 → 复用；CREATE3 已消耗，或同 hook 配置/codehash 冲突 → revert）。**部署选中地址**须用完整 `getPredictedProxy(..., nonce, hookOwner, hookTreasury, poolManager)`；三参数 `getPredictedProxy(..., nonce)` 仅返回首个 flag candidate，不代表部署结果。复现见 `script/DeployMemeverseHookProxy.s.sol::_selectProxySalt`。

> 注：`lpTokenImplementation` 与 3 facet 的 salt 均为 `salt = keccak256(abi.encodePacked(seed, nonce))`，各 `seed` 见 `script/DeployMemeverseHookProxy.s.sol` 的 `LP_TOKEN_IMPL_SALT_SEED` / `SWAP_FACET_SALT_SEED` / `DYNAMIC_FEE_FACET_SALT_SEED` / `SETTLEMENT_FACET_SALT_SEED`（hex 常量解码即上表 salt label 列字符串，本表以脚本常量为唯一真相源）。复现见 `script/DeployMemeverseHookProxy.s.sol::_computeArtifact` / `_deployArtifact`。

部署顺序：`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployPOLend, _deployMemeverseLauncher, _deployPOLSplitter`

1. 用同一个 `deployCaller` 命名空间通过 `getDeployed` 预测 Launcher、`POLendUpgradeable`、`POLSplitterUpgradeable` proxy 地址。
2. `_deployPOLend(nonce)`：部署 POLendUpgradeable implementation（salt = `POLendImplementation + nonce`），用预测的 Launcher 和 POLSplitterUpgradeable 地址构建 proxy creation code，部署 POLendUpgradeable proxy（salt = `POLend + nonce`）。
3. `_deployMemeverseLauncher(nonce)`：部署 Launcher implementation（salt = `MemeverseLauncherImplementation + nonce`），用预测的 POLendUpgradeable 和 POLSplitterUpgradeable 地址构建 proxy creation code，部署 Launcher proxy（salt = `MemeverseLauncher + nonce`）。
4. `_deployPOLSplitter(nonce)`：部署 POLSplitterUpgradeable implementation（salt = `POLSplitterImplementation + nonce`），用已部署的 Launcher 地址构建 proxy creation code，部署 POLSplitterUpgradeable proxy（salt = `POLSplitter + nonce`）。`POLSplitterUpgradeable.initialize` 内部调用 `launcher.polend()` 获取 POLendUpgradeable 地址，因此 Launcher 必须先部署。
5. 部署 `lpTokenImplementation`、3 facet、hook implementation 与 hook proxy，全部写入 `DeploymentResult` 的 6 个 first-class 字段（`hookProxy` 是真正的 v4 hook 地址）。部署顺序、facet `poolManager` 一致性与 `initialize` 绑定的操作流程唯一权威见 [operations.md §3.10](../../operations.md)。
6. 单角色部署模式下，脚本部署三个 delegatecall sibling `MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 与独立 view 合约 `MemeverseFeePreviewReader` 并分别调用 `launcher.setLaunchImpl(...)` / `launcher.setSettlementImpl(...)` / `launcher.setFeePreviewReader(...)` / `launcher.setLiquidityImpl(...)` 接线（双角色模式跳过，由 `initialOwner` 在单独交易中完成）。`[代码已证]`
7. 打开 registration 前执行 readiness checks。fund metadata 与 launchImpl readiness 取决于部署模式：单角色部署时脚本已在部署中写入 `setFundMetaData` 与 launch/settlement/fee-preview/liquidity 四个 setter；双角色部署时 `initialOwner` 须在单独交易中调用 `launcher.setFundMetaData(...)`、`launcher.setLaunchImpl(...)`、`launcher.setSettlementImpl(...)`、`launcher.setFeePreviewReader(...)`、`launcher.setLiquidityImpl(...)`。

readiness 检查项全集（依赖 pin、码检、registry 内容探针、`DAY()` 读回等）的唯一权威 runbook 见 [docs/operations.md §3.9.7](../../operations.md)；本节只保留部署拓扑与顺序事实。

`YieldDispatcherUpgradeable` 的部署拓扑事实：跨链 fee 分发（`MemeverseSettlementImpl.sol::_sendRedeemedFeesCrossChain`）的 OFT `SendParam.to` = 源链 `launcher.yieldDispatcher`，投递到 gov 链，负载性前提为「源链 `launcher.yieldDispatcher` == gov 链上真实部署的 YieldDispatcherUpgradeable 地址」。部署脚本经 CREATE3 两步部署（`script/MemeverseScript.s.sol::_deployYieldDispatcher`）：implementation 用 salt `SALT_YIELD_DISPATCHER_IMPLEMENTATION = "YieldDispatcherImplementation"`，ERC1967Proxy 用 `SALT_YIELD_DISPATCHER = "YieldDispatcher"` + initialize calldata；CREATE3 地址 = f(OutrunDeployer, deployer, salt) 与 creationCode 无关，各链同址三元组前提（OutrunDeployer 跨链同址 ∧ deployer/broadcaster 跨链同址 ∧ nonce 同）保持。`initialize` 每链传同一 `PROTOCOL_TREASURY`（各链 env 配同一值），故 `protocolTreasury` 跨链同址；此为部署约定非合约强制（`MemeverseLauncherUpgradeable.sol::setYieldDispatcher` 仅校验非零；`YieldDispatcherUpgradeable.sol::setProtocolTreasury` 仅 owner、非零校验），错配即协议费滞留、无回收入口、fail-closed（无第三方窃取）。`[代码已证]`

**sibling 轮换责任**：部署后 owner 经 `src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl` / `::setSettlementImpl` / `::setLiquidityImpl` 替换 sibling 指针属轮换路径，setter 链上只校验非零地址，上述部署期 readiness 的 `script/MemeverseScript.s.sol::_requireContractCode` 检查不覆盖该路径；轮换时 owner 须自行完成等价验证——新实现须有代码、ABI 与对应 `IMemeverseLaunchImpl` / `IMemeverseSettlementImpl` / `IMemeverseLiquidityImpl` 接口兼容、继承 `DelegatecallOnly`、存储布局与共享 `outrun.storage.MemeverseLauncher` namespace 的 `IMemeverseLauncherStorage::MemeverseLauncherStorage` struct 同步。完整责任清单见 [upgradeability.md §2.3](../upgradeability.md)。

## 7. 脚本层可见事实（非最终清单）

- `script/MemeverseScript.s.sol` 给出了环境变量命名、测试网链表与部署函数模板。`[代码已证]`
- 该脚本包含注释掉的分步部署/查询调用，不能视为“已执行部署记录”。`[代码已证]`

## 8. 明确未知项

- `[未知]` 各链真实部署地址与是否已升级后的实现地址。
- `[未知]` 生产环境 owner/delegate/multisig/timelock 实际控制关系。
- `[未知]` 生产环境实际 `supportedUAssets`、gasLimit、fee 配置最终值。
- `[未知]` 哪条链实际作为 registration center 主链与治理主链（需看部署参数，不在仓库固定）。
