# MemeverseV2 部署拓扑与初始化事实

## 1. 说明

本文记录当前“代码可证”的部署与初始化关系。
标签说明：

- `[代码已证]`：源码与脚本可直接定位
- `[未知]`：仓库没有最终部署实参/清单

## 2. 顶层部署拓扑（按合约角色）

### 2.1 基础常驻组件

- `LzEndpointRegistry`：`chainId -> endpointId` 映射注册表。`[代码已证]`
- `MemeverseRegistrationCenter`：中心链注册入口与 fan-out。`[代码已证]`
- `MemeverseRegistrarAtLocal` 或 `MemeverseRegistrarOmnichain`：注册执行层。`[代码已证]`
- `MemeverseLauncher`：verse 生命周期与资金总编排；当前为 `IOutrunDeployer` CREATE3 部署的 `ERC1967Proxy + UUPS` proxy。`[代码已证]`
- `MemeverseLaunchImpl`：launch 生命周期 delegatecall sibling；Launcher facade 经 `delegatecall` 调用的纯逻辑合约，与 Launcher 共享同一 ERC-7201 storage namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行 registerMemeverse / genesis / preorder / `changeStage` stage dispatcher / 治理组件部署编排。本身非 proxy（无 `Initializable`、无自身 storage），部署期由 owner `setLaunchImpl` 接线。`[代码已证]`
- `MemeverseSettlementImpl`：settlement / claim / fee 分发 delegatecall sibling；与 Launcher 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行 fee 收集/分发（redeem fee 捕获、POL burn、executor reward 拆分、同链/跨链分发）、refund / refundPreorder / claimNormalYT / claimNormalFees / claimUnlockedPreorderMemecoin / `redeemAndDistributeFees`、Locked→Unlocked 解算编排（`unlockFromLocked`）、post-unlock 公开 swap 保护。本身非 proxy、无自身 storage，部署期由 owner `setSettlementImpl` 接线。`[代码已证]`
- `MemeverseLiquidityImpl`：bootstrap 流动性 / POL mint / LP 赎回 delegatecall sibling；与 Launcher 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行主池+三辅助池创建、preorder settlement 接线、residual 处置、`mintPOLToken`、`redeemAuxiliaryLiquidity`、`settleLeveragedAuxiliaryLiquidity`、`redeemMemecoinLiquidity`、LP helper。本身非 proxy、无自身 storage，部署期由 owner `setLiquidityImpl` 接线。`[代码已证]`
- `MemeverseFeePreviewReader`：fee 预览独立 view 合约（genesis maker fee 预览、fee 分发 LayerZero fee 报价）；通过 immutable `PROXY` staticcall proxy getter 读状态，不绑名域、不被 delegatecall、不改 proxy storage。构造注入 proxy 地址，部署期由 owner `setFeePreviewReader` 接线。`[代码已证]`
- `MemeverseProxyDeployer`：per-verse clone/proxy 部署器。`[代码已证]`
- `YieldDispatcher`：收益 OFT compose 分发器。`[代码已证]`
- `MemeverseOmnichainInteroperation` + `OmnichainMemecoinStaker`：跨链 staking 路径。`[代码已证]`
- `MemeverseUniswapHook` + `MemeverseSwapRouter`：swap/liquidity 核心与外围。`[代码已证]`
- `lpTokenImplementation`：per-pool LP token clone 模板，是部署脚本返回的 first-class deployment artifact。`[代码已证]`
- `preorderSettlementExecutor`：preorder settlement 外部 helper，是部署脚本返回的 first-class deployment artifact。`[代码已证]`

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

注册阶段的 launcher 侧 7 步执行序列（权限校验、deployer 部署并初始化 memecoin/POL、`setPeer`、verse 基础信息与反向索引、`POLend.registerLendMarket`、`RegisterMemeverse`、后续 `setExternalInfo`）见 [docs/spec/verse/registration-details.md](registration-details.md) §10。

`POLend.registerLendMarket` 使用当前默认 `interestRate / leveragedDebtFactor`，其中 `leveragedDebtFactor` 已在初始化与 setter 侧受 `uint128.max * 1e18` 技术上限约束。`[代码已证]`

以上为 `[代码已证]`。

### 3.2 `Genesis -> Locked` 时的部署动作

1. launcher 判断是否达标并进入 `_deployAndSetupMemeverse`
2. 若 `getTotalLeveragedDebt(verseId) > 0`，launcher 调用 `POLend.finalizeLeveragedGenesis(verseId)`
3. launcher 调用 `POLSplitter.initializeVerse`
4. launcher 在主池建池后把主池实际 `uAsset` / POL raw 写入 `POLSplitter.recordPTBackingRatio(...)`
5. launcher 调用 `POLSplitter.split(...)` 产出 PT/YT，并把杠杆侧初始 YT 转给 `POLend`
6. launcher 按 POLend 四池模型创建 `memecoin/uAsset` 主池与 `POL/uAsset`、`PT/uAsset`、`PT/POL` 三个辅助池，必要时通过 `hook.executePreorderSettlement(...)` 完成 preorder 结算
7. 若治理链是本链：
 - deployer 部署并初始化 `yieldVault/governor/incentivizer`
 - `yieldVault.initialize` 的参数清单与虚拟缓冲 V 的语义见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md) §4.1；V 传入路径为 `[目标规范]`，后续 V 落地时以该锚点回填
8. 若治理链非本链：
 - 仅预测 `yieldVault/governor/incentivizer` 地址，不在本链初始化

以上动作发生在同一笔 `changeStage` 交易内；任一步失败都会回滚整笔 `Genesis -> Locked` 迁移。
进入该部署路径前，普通创世与杠杆创世共享 `totalNormalFunds + totalLeveragedDebt <= type(uint128).max` 的聚合资金上限，preorder 不计入该口径。`[代码已证]`

以上为 `[代码已证]`。

## 4. 关键部署依赖事实

- Launcher 配置 router / hook 时的 set-time 三重校验与 write-once 语义见 [docs/spec/invariants.md](../invariants.md) INV-04；`Genesis -> Locked` 执行建池前会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
- `Genesis -> Locked` 的 bootstrap 流动性部署由 `MemeverseLaunchImpl`（`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`）经 `delegatecall` 委托 `MemeverseLiquidityImpl`（`src/verse/MemeverseLiquidityImpl.sol::deployBootstrapLiquidity` / `src/verse/interfaces/IMemeverseLiquidityImpl.sol::deployBootstrapLiquidity`；原 `deployLiquidity` selector 变更为 `deployBootstrapLiquidity`）。sibling 与 Launcher facade 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，在 proxy storage 上下文执行；sibling 地址由 owner `setLiquidityImpl` 配置（`src/verse/MemeverseLauncher.sol::setLiquidityImpl`），未配置时 `Genesis -> Locked` 回退 `LiquidityImplNotSet`。`[代码已证]`
- fee 分发的 delegatecall 委托路径：Launcher facade `::redeemAndDistributeFees`（`src/verse/MemeverseLauncher.sol::redeemAndDistributeFees`）与 `changeStage` 的 Locked→Unlocked 分支（`::unlockFromLocked`）经 `delegatecall` 委托 `MemeverseSettlementImpl`（`src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees` / `::unlockFromLocked`）。sibling 地址由 owner `setSettlementImpl` 配置（`src/verse/MemeverseLauncher.sol::setSettlementImpl`），未配置时 delegatecall 前置点回退 `SettlementImplNotSet`。sibling 与 Launcher 共享同一 ERC-7201 namespace 与 struct，在 proxy storage 上下文执行。`[代码已证]`
- `polend` 与 `polSplitter` 都是 Launcher proxy 初始化写入的必需接线，当前代码不存在 unset 或运行中换地址路径。注册、创世部署、fee preview/claim、unlock settlement 都直接依赖这两个固定地址。`[代码已证]`
- 具体接线语义：
  - `polend`：注册时 `registerLendMarket`，部署时 `finalizeLeveragedGenesis`，Locked governor PT fee 预兑付时 `preRedeemPTFee`，unlock settlement 时按需 `executeGlobalSettlement`
  - `polSplitter`：部署时 `initializeVerse`、`recordPTBackingRatio`、`split`，normal/gov PT fee preview 时 `previewPTToUAsset`，settled 后 PT 兑现时 `redeemPT`，unlock settlement 时 `settle`
- Hook owner 在部署后仍可 retarget `launcher`；该能力属于与 launcher owner 同一 trust boundary 的配置权，当前产品语义接受这一点。`[代码已证]`
- Launcher 与所有继承 `ReentrancyGuard` 的合约（`POLend`、`POLSplitter`、`MemeverseUniswapHook`）依赖 EIP-1153 transient storage（`tload`/`tstore` 操作码），编译目标 `evm_version = "prague"`。部署链必须支持 Cancun 或更新硬分叉，否则 `nonReentrant` 修饰符将导致 `invalid opcode` 回退。见 [docs/operations.md](../../operations.md#6-evm-兼容性要求)。`[代码已证]`
- 跨链分发与 staking 的 gas 参数来自 launcher/interoperation 的可配置 gas limits。`[代码已证]`
- `MemeverseProxyDeployer.quorumNumerator` 仅影响后续新部署 governor 初始化，不回溯既有实例。`[代码已证]`

## 5. Launcher 原生 gas dust 边界

- `MemeverseLauncher.removeGasDust(address receiver)` 是 owner-only 运维清理入口，用于转出 Launcher 合约上的 native balance。`[代码已证]`
- 该余额不是用户可 claim 资金，且与 `RegistrationCenter` gas dust 是不同边界。`[代码已证]`
- 目标边界：`redeemAndDistributeFees` 要求 `msg.value` 精确等于 required fee；本地分发、无跨链要求或无 fee 分发时 required fee 为 `0`。精确 native payment 下，费用分发不应产生预期 Launcher dust。
- 无 fee 分发时，`redeemAndDistributeFees` 在返回零值前必须拒绝非零 `msg.value`，避免误带 native value 留作 Launcher dust。`[代码已证]`
- 当前代码按实现行为描述，不额外声明 zero-address receiver 校验。`[代码已证]`

## 6. CREATE3 UUPS proxy 部署顺序

`IOutrunDeployer.getDeployed(deployCaller, salt)` 的 `deployCaller` 是后续实际调用 `deploy(...)` 的 CREATE3 命名空间，不是 `initialize(...)` 使用的 `initialOwner`。二者可以相同，但部署脚本拆分这两个概念：`deployCaller` 控制地址预测/部署命名空间，`initialOwner` 控制 proxy 初始化后的 owner 与 UUPS 升级权限。`[代码已证]`

**部署模式**

脚本支持两种部署模式：

- **单角色部署**（`deployCaller == initialOwner`，如同一 EOA 既部署又持有 owner）：脚本在部署过程中直接写入 `setFundMetaData`，并部署三个 delegatecall sibling `MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 与独立 view 合约 `MemeverseFeePreviewReader`，再调用 `launcher.setLaunchImpl(...)` / `launcher.setSettlementImpl(...)` / `launcher.setFeePreviewReader(...)` / `launcher.setLiquidityImpl(...)` 接线。四个 setter 彼此无顺序依赖；该顺序仅对齐当前部署脚本与 WARNING 文案，readiness check 只要求四者最终均已接线且有代码。readiness check 通过后即可打开 registration。`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployMemeverseLauncher, _setMemeverseLauncherFundMetaData`；`src/verse/MemeverseLauncher.sol::setLaunchImpl`、`::setSettlementImpl`、`::setFeePreviewReader`、`::setLiquidityImpl`
- **双角色部署**（`deployCaller != initialOwner`，如 DevOps 负责部署、multisig 持有 owner）：脚本部署 proxy 并执行 `initialize`，但跳过 `setFundMetaData` 与 launch/settlement/fee-preview/liquidity 四个 setter 写入。`initialOwner` 必须在单独交易中调用 `launcher.setFundMetaData(...)`、`launcher.setLaunchImpl(...)`、`launcher.setSettlementImpl(...)`、`launcher.setFeePreviewReader(...)`、`launcher.setLiquidityImpl(...)`，完成后才能通过 readiness check 并打开 registration。脚本在检测到双角色部署时输出 console 警告。`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployMemeverseLauncher`（条件跳过 + 警告 log，文案为 `"WARNING: deployCaller(%s) != initialOwner(%s) -- fund metadata, launchImpl, settlementImpl, feePreviewReader and liquidityImpl must be set by initialOwner"`）

Launcher、`POLend`、`POLSplitter`、`lpTokenImplementation`、`preorderSettlementExecutor` 使用同一 `DEPLOYMENT_NONCE` 派生各自 salt；脚本输出的 `DeploymentResult` 必须把这些地址作为 first-class fields 返回，不能只把后两者当作内部临时地址。

| 合约 / artifact | Proxy salt label | Implementation / helper salt label | Canonical address |
| --- | --- | --- | --- |
| `MemeverseLauncher` | `MemeverseLauncher` | `MemeverseLauncherImplementation` | `getDeployed(deployCaller, launcherSalt)` 返回的 Launcher proxy |
| `POLend` | `POLend` | `POLendImplementation` | `getDeployed(deployCaller, polendSalt)` 返回的 `POLend` proxy |
| `POLSplitter` | `POLSplitter` | `POLSplitterImplementation` | `getDeployed(deployCaller, polSplitterSalt)` 返回的 `POLSplitter` proxy |
| `lpTokenImplementation` | N/A | `LPTokenImplementation` | `DeploymentResult.lpTokenImplementation` |
| `preorderSettlementExecutor` | N/A | `PreorderSettlementExecutor` | `DeploymentResult.preorderSettlementExecutor` |

部署顺序：`[代码已证]`
证据：`script/MemeverseScript.s.sol:_deployPOLend, _deployMemeverseLauncher, _deployPOLSplitter`

1. 用同一个 `deployCaller` 命名空间通过 `getDeployed` 预测 Launcher、`POLend`、`POLSplitter` proxy 地址。
2. `_deployPOLend(nonce)`：部署 POLend implementation（salt = `POLendImplementation + nonce`），用预测的 Launcher 和 POLSplitter 地址构建 proxy creation code，部署 POLend proxy（salt = `POLend + nonce`）。
3. `_deployMemeverseLauncher(nonce)`：部署 Launcher implementation（salt = `MemeverseLauncherImplementation + nonce`），用预测的 POLend 和 POLSplitter 地址构建 proxy creation code，部署 Launcher proxy（salt = `MemeverseLauncher + nonce`）。
4. `_deployPOLSplitter(nonce)`：部署 POLSplitter implementation（salt = `POLSplitterImplementation + nonce`），用已部署的 Launcher 地址构建 proxy creation code，部署 POLSplitter proxy（salt = `POLSplitter + nonce`）。`POLSplitter.initialize` 内部调用 `launcher.polend()` 获取 POLend 地址，因此 Launcher 必须先部署。
5. 部署 `lpTokenImplementation` 与 `preorderSettlementExecutor`，并写入 `DeploymentResult.lpTokenImplementation`、`DeploymentResult.preorderSettlementExecutor`。
6. 单角色部署模式下，脚本部署三个 delegatecall sibling `MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 与独立 view 合约 `MemeverseFeePreviewReader` 并分别调用 `launcher.setLaunchImpl(...)` / `launcher.setSettlementImpl(...)` / `launcher.setFeePreviewReader(...)` / `launcher.setLiquidityImpl(...)` 接线（双角色模式跳过，由 `initialOwner` 在单独交易中完成）。`[代码已证]`
7. 打开 registration 前执行 readiness checks。fund metadata 与 launchImpl readiness 取决于部署模式：单角色部署时脚本已在部署中写入 `setFundMetaData` 与 launch/settlement/fee-preview/liquidity 四个 setter；双角色部署时 `initialOwner` 须在单独交易中调用 `launcher.setFundMetaData(...)`、`launcher.setLaunchImpl(...)`、`launcher.setSettlementImpl(...)`、`launcher.setFeePreviewReader(...)`、`launcher.setLiquidityImpl(...)`。

Readiness checks 至少包括：`[代码已证]`
证据：`script/MemeverseScript.s.sol:_checkMemeverseLauncherDeployment, _checkPOLendDeployment, _checkPOLSplitterDeployment, _requireDeploymentReady`

- Launcher proxy 地址有代码（`code.length > 0`）。脚本不显式比较 implementation 地址；若误填 implementation 地址，后续 `owner()` / getter 一致性检查会以具体 getter 不匹配报错。
- `launcher.owner() == initialOwner`。
- `launcher.getLauncherContracts().memeverseRegistrar == MEMEVERSE_REGISTRAR`，且 registrar back-reference 指向 Launcher proxy。
- `launcher.getLauncherContracts().memeverseProxyDeployer == MEMEVERSE_PROXY_DEPLOYER`，且 proxy deployer back-reference 指向 Launcher proxy。
- `launcher.getLauncherContracts().yieldDispatcher == MEMEVERSE_YIELD_DISPATCHER`，且 yield dispatcher back-reference 指向 Launcher proxy。
- `launcher.polend() == polendProxy`。
- `launcher.getLauncherContracts().polSplitter == polSplitterProxy`。
- `polend.owner() == initialOwner`、`polend.launcher() == launcherProxy`、`polend.splitter() == polSplitterProxy`、`polend.treasury() == POLEND_TREASURY`。
- `polSplitter.owner() == initialOwner`、`polSplitter.launcher() == launcherProxy`、`polSplitter.polend() == polendProxy`。
- `DeploymentResult.lpTokenImplementation` 与 `DeploymentResult.preorderSettlementExecutor` 均为非零地址且 `code.length > 0`。
- `launchImpl`（`LauncherContracts` 字段）非零且有代码；脚本 typed decode `getLauncherContracts()` 后 `_requireContractCode(launchImpl, "LAUNCH_IMPL_NOT_READY")`。`[代码已证]`
- `settlementImpl` / `feePreviewReader` / `liquidityImpl` 与 `launchImpl` 同步进 readiness check：脚本 typed decode `getLauncherContracts()` 后分别 `_requireContractCode(settlementImpl, "SETTLEMENT_IMPL_NOT_READY")`、`_requireContractCode(feePreviewReader, "FEE_PREVIEW_READER_NOT_READY")`、`_requireContractCode(liquidityImpl, "LIQUIDITY_IMPL_NOT_READY")`，四者对称。未接线时 readiness 失败、阻断 registration 打开；运行时 `LaunchImplNotSet` / `SettlementImplNotSet` / `LiquidityImplNotSet` 守卫仅作兜底。`[代码已证]`
- `POLend.creditFactory()` 进 readiness check：脚本 `_readAddress(POLEND, "creditFactory()")` 取值后 `_requireContractCode(..., "POLEND_CREDIT_FACTORY_NOT_READY")`，与 bootstrap/fee sibling 同类（均为用户路径接线指针）。校验"有代码"而非"非零"——`_buildPOLendCreationCode` 在未设 `CREDIT_FACTORY_PROXY` 时会兜底写入 `initialOwner`（非零 EOA），仅 `code.length > 0` 才能拦住占位、阻断 registration 打开。`[代码已证]`
- 同一 nonce 复用时，`lpTokenImplementation` 与 `preorderSettlementExecutor` 必须和按当前 salt 预测出的地址一致；二者的运行期 codehash 都必须等于预期值（`lpTokenImplementation` 对应 `EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH`，`preorderSettlementExecutor` 对应 `EXPECTED_PREORDER_SETTLEMENT_EXECUTOR_CODEHASH`，见 `script/DeployMemeverseHookProxy.s.sol::_validateExistingImplementationCodehashes`），同时要求地址非零且有代码。
- 每个支持的 `uAsset` 都有非零 `fundMetaDatas(uAsset).minTotalFund` 与 `fundMetaDatas(uAsset).fundBasedAmount`。
- `POLend.settlementDustStates(uAsset).maxReserve > 0`。

## 7. 脚本层可见事实（非最终清单）

- `script/MemeverseScript.s.sol` 给出了环境变量命名、测试网链表与部署函数模板。`[代码已证]`
- 该脚本包含注释掉的分步部署/查询调用，不能视为“已执行部署记录”。`[代码已证]`

## 8. 明确未知项

- `[未知]` 各链真实部署地址与是否已升级后的实现地址。
- `[未知]` 生产环境 owner/delegate/multisig/timelock 实际控制关系。
- `[未知]` 生产环境实际 `supportedUAssets`、gasLimit、fee 配置最终值。
- `[未知]` 哪条链实际作为 registration center 主链与治理主链（需看部署参数，不在仓库固定）。
