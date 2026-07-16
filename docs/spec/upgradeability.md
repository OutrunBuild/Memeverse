# MemeverseV2 升级性与初始化约束（Source-Backed）

## 1. 结论摘要

当前仓库存在五类 surface：

1. 构造函数部署、不可升级（无 proxy）
2. 最小代理（EIP-1167 clone）+ 自定义 `initializer`
3. `ERC1967Proxy` + `UUPSUpgradeable`（含 diamond Router Hook）
4. Diamond facet（非 proxy，经 Router `delegatecall` 的可替换实现）
5. Facade delegatecall 目标（非 proxy，owner setter 替换指针）

补充约束：

- 本文档是升级性规则主文档（canonical source）。
- [docs/implementation-map.md](../implementation-map.md) 仅在各 surface 行内记录升级机制事实与定位锚点，不替代本文规则条目。

## 2. 升级面分类

| Surface | 机制 | 初始化入口 | 升级授权 | 证据 |
| --- | --- | --- | --- | --- |
| **构造函数部署（不可升级）** | | | | |
| Router | constructor 部署 | constructor | 不适用 | `src/swap/MemeverseSwapRouter.sol::constructor` |
| RegistrationCenter | constructor 部署 | constructor | 不适用 | `src/verse/registration/MemeverseRegistrationCenter.sol::constructor` |
| RegistrarAtLocal | constructor 部署 | constructor | 不适用 | `src/verse/registration/MemeverseRegistrarAtLocal.sol::constructor` |
| RegistrarOmnichain | constructor 部署 | constructor | 不适用 | `src/verse/registration/MemeverseRegistrarOmnichain.sol::constructor` |
| YieldDispatcher | constructor 部署 | constructor | 不适用 | `src/verse/YieldDispatcher.sol::constructor` |
| OmnichainInteroperation | constructor 部署 | constructor | 不适用 | `src/interoperation/MemeverseOmnichainInteroperation.sol::constructor` |
| OmnichainMemecoinStaker | constructor 部署 | constructor | 不适用 | `src/interoperation/OmnichainMemecoinStaker.sol::constructor` |
| LzEndpointRegistry | constructor 部署 | constructor | 不适用 | `src/common/omnichain/LzEndpointRegistry.sol::constructor` |
| ProxyDeployer | constructor 部署 | constructor | 不适用 | `src/verse/deployment/MemeverseProxyDeployer.sol::constructor` |
| `lpTokenImplementation` | constructor 部署；`DeploymentResult.lpTokenImplementation` 返回 | constructor | 不适用 | `script/DeployMemeverseHookProxy.s.sol`（部署脚本） |
| `feePreviewReader` | constructor 部署；immutable `PROXY` 绑 Launcher proxy 地址；非 delegatecall 目标，仅 staticcall 读 proxy getter | constructor | 不适用（地址替换由 Launcher owner `setFeePreviewReader` 控制） | `src/verse/MemeverseFeePreviewReader.sol::constructor`、`::PROXY`；`src/verse/MemeverseLauncher.sol::setFeePreviewReader` |
| **最小代理 clone（不可升级）** | | | | |
| `Memecoin` / `MemePol` / `MemecoinYieldVault` | EIP-1167 clone | 外部 `initialize`（单次） | 无实现内升级入口 | `src/verse/deployment/MemeverseProxyDeployer.sol::deployMemecoin`、`::deployPOL`、`::deployYieldVault`; `src/token/Memecoin.sol::initialize`; `src/token/MemePol.sol::initialize`; `src/yield/MemecoinYieldVault.sol::initialize` |
| **UUPS 可升级** | | | | |
| `MemeverseLauncher` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, localLzEndpoint_, memeverseRegistrar_, memeverseProxyDeployer_, yieldDispatcher_, lzEndpointRegistry_, polend_, polSplitter_, executorRewardRate_, oftReceiveGasLimit_, yieldDispatcherGasLimit_, preorderCapRatio_, preorderVestingDuration_)` | `_authorizeUpgrade(...) => onlyOwner` | `src/verse/MemeverseLauncher.sol`（`_authorizeUpgrade`）; `script/MemeverseScript.s.sol`（部署脚本） |
| `MemecoinDaoGovernorUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(...)` | `_authorizeUpgrade(...) => onlyGovernance` | `src/governance/MemecoinDaoGovernorUpgradeable.sol`（`_authorizeUpgrade`）; `src/verse/deployment/MemeverseProxyDeployer.sol`（proxy 部署） |
| `GovernanceCycleIncentivizerUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(...)` | `_authorizeUpgrade(...) => onlyGovernance` | `src/governance/GovernanceCycleIncentivizerUpgradeable.sol`（`_authorizeUpgrade`）; `src/verse/deployment/MemeverseProxyDeployer.sol`（proxy 部署） |
| `POLend` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, interestRate_, leveragedDebtFactor_, treasury_, launcher_, splitter_)` | `_authorizeUpgrade(...) => onlyOwner` | `src/polend/POLend.sol`（`_authorizeUpgrade`） |
| `POLSplitter` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, _launcher)` | `_authorizeUpgrade(...) => onlyOwner` | `src/polend/POLSplitter.sol`（`_authorizeUpgrade`） |
| **UUPS 可升级（diamond Router）** | | | | |
| `MemeverseUniswapHook`（Router） | `ERC1967Proxy` + UUPS | `initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_)` | `_authorizeUpgrade(...) => onlyOwner`（Hook `owner()`）；3 facet 地址经 owner `setFacet(bytes32 role, address facet)` 独立替换 | `script/DeployMemeverseHookProxy.s.sol`（Hook proxy 部署与 existing proxy 校验）；`src/swap/MemeverseUniswapHook.sol::initialize`、`::setFacet`；getter 区 `::lpTokenImplementation`、`::swapFacet`、`::dynamicFeeFacet`、`::settlementFacet` |
| **Diamond facet（非 proxy，可替换实现）** | | | | |
| `SwapFacet`（`SWAP_FACET_ROLE`） | Hook Router 显式 entry 经 `delegatecall` 调度的 v4 callback / LP snapshot logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(SWAP_FACET_ROLE, facet)` 替换 | `src/swap/SwapFacet.sol`; `src/swap/interfaces/ISwapFacet.sol`; `src/swap/MemeverseUniswapHook.sol::setFacet` |
| `DynamicFeeFacet`（`DYNAMIC_FEE_FACET_ROLE`） | Hook Router、`SwapFacet` 与 `SettlementFacet` 经 `delegatecall` 调度的动态费率 logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(DYNAMIC_FEE_FACET_ROLE, facet)` 替换 | `src/swap/DynamicFeeFacet.sol`; `src/swap/interfaces/IDynamicFeeFacet.sol`; `src/swap/MemeverseUniswapHook.sol::setFacet` |
| `SettlementFacet`（`SETTLEMENT_FACET_ROLE`） | Hook Router 显式 entry 经 `delegatecall` 调度的 preorder settlement / unlock callback logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(SETTLEMENT_FACET_ROLE, facet)` 替换 | `src/swap/SettlementFacet.sol`; `src/swap/interfaces/ISettlementFacet.sol`; `src/swap/MemeverseUniswapHook.sol::setFacet` |
| **Facade delegatecall 目标（非 proxy）** | | | | |
| `MemeverseBootstrap` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setBootstrapImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeverseBootstrap.sol`；`src/verse/MemeverseLauncher.sol::setBootstrapImpl`、`::_deployLiquidity`；`src/verse/interfaces/IMemeverseBootstrap.sol::deployLiquidity` |
| `MemeverseFeeDistributor` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setFeeDistributorImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeverseFeeDistributor.sol`；`src/verse/MemeverseLauncher.sol::setFeeDistributorImpl`、`::redeemAndDistributeFees`、`changeStage` Locked→Unlocked delegatecall 调用点 |
| `MemeversePOLMinter` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setPOLMinterImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeversePOLMinter.sol`；`src/verse/MemeverseLauncher.sol::setPOLMinterImpl`、`::mintPOLToken`；`src/verse/interfaces/IMemeversePOLMinter.sol::mintPOLToken` |

### 2.1 Diamond facet 替换兼容约束

- role 的 ABI 契约分别是 `ISwapFacet`、`IDynamicFeeFacet` 与 `ISettlementFacet`。`SwapFacet` 的 `*Logic` 参数必须与 Router 外层 v4 callback 的参数顺序和类型 1:1 镜像；所有 role 的 selector、参数 ABI 与返回 ABI 必须保持兼容。`SettlementCallbackData` / `SettlementResult` 的编解码也属于 `SettlementFacet` 的兼容契约。
- `setFacet` 在链上只验证 `onlyOwner`、已知 role、非零地址、候选地址有字节码，以及 `ImmutableState(facet).poolManager()` 与 Hook `poolManager` 一致；它不验证完整 role ABI、共享 storage layout 或 `onlyViaRouter`。
- 三个 facet 必须以同一个 `IPoolManager` 构造，并通过 `layout at erc7201("outrun.storage.MemeverseUniswapHook")` 和 `IMemeverseHookStorage` 使用同一 `MemeverseUniswapHookStorage`。字段顺序冻结，只能尾部追加。
- facet 应保留 `FacetGuard.onlyViaRouter` 的 direct-`CALL` 拒绝。该 guard 只区分 direct `CALL` 与 `delegatecall`，不认证 delegatecall 的宿主一定是指定 Hook proxy。

## 3. 初始化约束（当前代码实际支持）

### 3.1 最小代理初始化一次性

- `src/common/access/Initializable.sol` 在实现合约 constructor 中把 `initialized=true`，阻止实现本体被初始化。
  - 证据：`src/common/access/Initializable.sol::constructor`
- clone 实例通过 `initializer` 进入一次初始化，重复调用回退 `AlreadyInitialized`。
  - 证据：`src/common/access/Initializable.sol::initializer`（modifier）与 `::AlreadyInitialized`（error）

### 3.2 由 launcher 驱动 token 初始化

- launcher 在注册时通过 deployer 克隆 `memecoin`/`POL` 并立即 `initialize`。
  - 证据：`src/verse/MemeverseLauncher.sol::_deployAndInitializeVerseTokens`

**owner 与 delegate 的初始化值：**

- `initialize` 调用时，`owner` 和 `delegate` 均被设为 `msg.sender`——即执行调用的 launcher 实例（`address(this)`）。
  - 含义：刚部署的 memecoin / POL token 的 admin 权限（owner）与治理代理权（delegate）都归属于 launcher。
  - 证据：`src/verse/MemeverseLauncher.sol::_deployAndInitializeVerseTokens`; `src/token/Memecoin.sol::initialize`; `src/token/MemePol.sol::initialize`
- 此行为仅反映源码层的初始化语义；线上部署后 owner 是否被迁移（例如转给多签 / timelock）不在仓库证据范围内。
  - 同源：section 6 "中确定性" 条目

### 3.3 governance 组件仅在治理链本地部署初始化

- 当 `govChainId == block.chainid`：部署并初始化 `yieldVault/governor/incentivizer`。
  - 证据：`src/verse/MemeverseLauncher.sol::_deployGovernanceComponents`（local 分支：`govChainId == block.chainid`）
- 否则只做地址预测，不在当前链初始化。
  - 证据：`src/verse/MemeverseLauncher.sol::_deployGovernanceComponents`（remote 分支：`govChainId != block.chainid`）

### 3.4 Launcher UUPS 初始化事实

- 当前 `MemeverseLauncher` 是 `ERC1967Proxy + UUPS` surface。实现合约 constructor 只调用 `_disableInitializers()`，阻止 implementation 本体被初始化。
  - 证据：`src/verse/MemeverseLauncher.sol::constructor`
- Launcher proxy 通过 `initialize(...)` 写入 canonical 配置：`initialOwner`、local endpoint、registrar、proxy deployer、yield dispatcher、endpoint registry、`POLend`、`POLSplitter`、gas、reward 与 preorder 初始配置。
  - 证据：`src/verse/MemeverseLauncher.sol::initialize`
- Launcher 升级通过 UUPS `upgradeToAndCall(...)` 进入实现合约，并由 `_authorizeUpgrade(...) => onlyOwner` 放行。
  - 证据：`src/verse/MemeverseLauncher.sol::_authorizeUpgrade`
- 协议真实 Launcher 地址是 `IOutrunDeployer` CREATE3 部署的 ERC1967 proxy 地址，不是 implementation 地址。脚本对 implementation salt 与 proxy salt 分开建模，`MemeverseLauncher` salt 对应 canonical proxy 地址。
  - 证据：`script/MemeverseScript.s.sol::_deployMemeverseProxyDeployer`、`::_deployMemeverseLauncher`
- `deployCaller` 是执行 CREATE3 / proxy 部署的调用者，`initialOwner` 是 Launcher proxy 初始化后的 owner；两者显式拆分。默认脚本支持两种模式：`deployCaller == initialOwner` 时脚本在部署中直接写入 `setFundMetaData`；`deployCaller != initialOwner` 时跳过 fund metadata，由 `initialOwner` 单独调用 `setFundMetaData`。测试 harness 通过覆盖 `_beginMemeverseLauncherOwnerExecution` 实现 `vm.startPrank` 以在单交易内测试双角色路径。`[代码已证]`
  - 证据：`script/MemeverseScript.s.sol::_deployMemeverseLauncher`、`::_setMemeverseLauncherFundMetaData`; `test/verse/deployment/MemeverseProxyDeployer.t.sol::_beginMemeverseLauncherOwnerExecution`
- `POLend` / `POLSplitter` 通过 Launcher `initialize(...)` 参数（`polend_`、`polSplitter_`）写入，且必须是各自 canonical proxy address。
- readiness 检查覆盖 Launcher proxy 可读配置、launcher-bound 依赖 back-reference、`fundMetaDatas[uAsset]`、`POLend.settlementDustStates(uAsset).maxReserve`，以及 `bootstrapImpl` / `feeDistributorImpl` / `polMinterImpl` / `feePreviewReader` 有代码，不能只检查 implementation 或 proxy code 存在；swap-router 与 hook 的 PoolManager 一致性（`router.poolManager() == hook.poolManager()`）亦在 readiness 范围内，与 3 facet 的 `_requireFacetPoolManager` 对称（错误串 `ROUTER_POOL_MANAGER_NOT_READY`），避免 router↔hook PoolManager 不一致导致 `NotPoolManager` 路径 DoS。
  - 证据：`script/MemeverseScript.s.sol::_checkMemeverseLauncherDeployment`、`::_requireDeploymentReady`、`::_requireFundMetaDataReady`、`::_readSettlementDustState`、`::_readLauncherImplSiblings`
- `bootstrapImpl` 由部署期 owner `setBootstrapImpl` 配置（非 `initialize` 参数）；`Genesis -> Locked` 的 bootstrap 流动性部署由 Launcher facade `::_deployLiquidity` 经 `delegatecall` 委托 `MemeverseBootstrap::deployLiquidity`，在 proxy storage 上下文执行。readiness 校验 `bootstrapImpl` 有代码。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncher.sol::setBootstrapImpl`、`::_deployLiquidity`；`src/verse/MemeverseBootstrap.sol::deployLiquidity`
- `feeDistributorImpl` 同样由部署期 owner `setFeeDistributorImpl` 配置（非 `initialize` 参数）；fee 分发由 Launcher facade `::redeemAndDistributeFees` 与 `changeStage` Locked→Unlocked 分支经 `delegatecall` 委托 `MemeverseFeeDistributor`，在 proxy storage 上下文执行。readiness 校验 `feeDistributorImpl` 与 `feePreviewReader` 有代码，与 `bootstrapImpl` 一致：三者均为用户路径上使用的 sibling/view 合约，缺失会让 `redeemAndDistributeFees` / `changeStage` Locked→Unlocked 回退 `FeeDistributorImplNotSet`（或预览失效）；readiness 提前抓、运行时守卫兜底，双层防御与 `bootstrapImpl` 对称。`polMinterImpl` 走同一套 readiness + 运行时守卫模式，详见下方 `MemeversePOLMinter` 段。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncher.sol::setFeeDistributorImpl`、`::redeemAndDistributeFees`、`::changeStage`；`src/verse/MemeverseFeeDistributor.sol::collectAndDistributeFees`、`::captureLockedAuxiliaryFees`；`script/MemeverseScript.s.sol::_readLauncherImplSiblings`、`::_requireDeploymentReady`
- `polMinterImpl` 同样由部署期 owner `setPOLMinterImpl` 配置（非 `initialize` 参数）；POL token 铸造由 Launcher facade `::mintPOLToken` 经 `delegatecall` 委托 `MemeversePOLMinter`，在 proxy storage 上下文执行。`MemeversePOLMinter` 是 launcher sibling（与 `MemeverseBootstrap` / `MemeverseFeeDistributor` 同类：空 constructor、无 `Initializable`、共享 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct，`layout at erc7201("outrun.storage.MemeverseLauncher") is TokenHelper, IMemeversePOLMinter`）。readiness 校验 `polMinterImpl` 有代码，与 `bootstrapImpl` / `feeDistributorImpl` 一致；缺失会让 `mintPOLToken` 回退 `POLMinterImplNotSet`，readiness 提前抓、运行时守卫兜底，双层防御与前序 sibling 对称。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncher.sol::setPOLMinterImpl`、`::mintPOLToken`；`src/verse/MemeversePOLMinter.sol::mintPOLToken`；`src/verse/interfaces/IMemeversePOLMinter.sol::mintPOLToken`、`::POLMinterImplNotSet`；`script/MemeverseScript.s.sol::_readLauncherImplSiblings`、`::_requireDeploymentReady`
- `creditFactory` 是 POLend 可替换运行态指针（owner-only `setCreditFactory` 替换，emit `CreditFactoryChanged`），由 `leveragedGenesisWithCredit` 在该 verse 首次 credit 注入时经 `IGenesisCreditFactory(creditFactory).creditOf(uAsset)` 解析 GenesisCredit 地址。readiness 校验 `POLend.creditFactory()` 有代码，与 `bootstrapImpl` / fee sibling 同类（均为用户路径上使用的接线指针）：缺失或被占位（如 `_buildPOLendCreationCode` 在未设 `CREDIT_FACTORY_PROXY` 时兜底写入的 `initialOwner` EOA，无代码）会让首次 `leveragedGenesisWithCredit` 对无代码地址 staticcall 返空、`abi.decode` revert，credit 路径静默阻断直到 `setCreditFactory`；readiness 提前抓，与 sibling 对称。校验"有代码"而非"非零"，因 owner 兜底非零、能蒙过零检查。`[代码已证]`
  - 证据：`src/polend/POLend.sol::leveragedGenesisWithCredit`、`::setCreditFactory`、`::creditFactory`；`script/MemeverseScript.s.sol::_requireDeploymentReady`、`::_buildPOLendCreationCode`
- `proxiableUUID()` 在 implementation 上可读；通过 proxy 调用 `proxiableUUID()` 必须按 UUPS guard 回退，不能作为 proxy readiness 成功检查。

### 3.5 Hook UUPS 初始化事实

- 当前 `MemeverseUniswapHook` 是 `ERC1967Proxy + UUPS` surface（diamond Router）。实现合约 constructor 调用 `_disableInitializers()`，阻止 implementation 本体被初始化。
  - 证据：`src/swap/MemeverseUniswapHook.sol::constructor`
- Hook proxy 通过 `ERC1967Proxy(implementation, initializeData)`（2 参数，不传 owner 给 proxy constructor）部署；owner 经 `initialize(...)` 植入 Hook storage。
  - 证据：`script/DeployMemeverseHookProxy.s.sol`（Hook proxy 部署与 existing proxy 校验）
- Hook `initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_)` 写入 owner、treasury、LP token implementation 与 3 个 facet 地址，并写入默认启动费率配置与默认 `referrerRebateBps = 1000`。
  - 证据：`src/swap/MemeverseUniswapHook.sol::initialize`
- Hook 升级通过 UUPS `upgradeToAndCall(...)` 进入实现合约，并由 `_authorizeUpgrade(address) internal view override onlyOwner` 放行（镜像 `src/verse/MemeverseLauncher.sol::_authorizeUpgrade`）。`_authorizeUpgrade` 先对新 implementation 做无代码守卫（`newImplementation.code.length == 0` 时 revert `UpgradeTargetCodeNotReady`），再内置 `poolManager` drift 检查：通过 `ImmutableState(newImplementation).poolManager()` 读取新 implementation 的 immutable PoolManager，与当前 `poolManager` 比较，不匹配 revert `UpgradePoolManagerMismatch`。这是运维护栏而非安全边界（恶意 owner 可伪造 getter 绕过），保护对象是 honest upgrade 中的构造参数误用。
  - 证据：`src/swap/MemeverseUniswapHook.sol::_authorizeUpgrade`（UUPS 入口 + poolManager drift 检查）
- same-nonce / existing Hook proxy 复用校验使用 ERC1967Proxy runtime codehash，不检查 admin slot、`ProxyAdmin` owner 或 ProxyAdmin 与 Hook owner 对齐。
  - 证据：`script/DeployMemeverseHookProxy.s.sol::_validateExistingImplementationCodehashes`

## 4. Proxy / Deployer 假设（仅限代码可证）

- 当前 `MemeverseLauncher` 是 UUPS surface，不使用独立 `ProxyAdmin`。
- `MemeverseProxyDeployer` 只允许 launcher 调用 deploy 系列函数。
  - 证据：`src/verse/deployment/MemeverseProxyDeployer.sol::onlyMemeverseLauncher`（modifier）；deploy 系列 `::deployMemecoin`、`::deployPOL`、`::deployYieldVault`、`::deployGovernorAndIncentivizer`
- governor 与 incentivizer 使用 `Create2 + ERC1967Proxy`，部署后立即执行 `initialize(...)`。
  - 证据：`src/verse/deployment/MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer`
- 当前治理组件采用 UUPS，不存在透明代理模式下的独立 `ProxyAdmin`；`upgradeToAndCall(...)` 进入实现合约后，由 `_authorizeUpgrade(...)` 决定是否放行。
  - governor：`_authorizeUpgrade(...) => onlyGovernance`
  - incentivizer：`_authorizeUpgrade(...) => onlyGovernance`（实际校验 `msg.sender == governor`）
  - 证据：`src/governance/MemecoinDaoGovernorUpgradeable.sol::_authorizeUpgrade`; `src/governance/GovernanceCycleIncentivizerUpgradeable.sol::_authorizeUpgrade`、`::onlyGovernance`（modifier）
- `POLend` 与 `POLSplitter` 不由 `MemeverseProxyDeployer` 部署；它们通过外部脚本/工厂独立部署，并以 Launcher `initialize(...)` 参数 `polend_`、`polSplitter_` 接线。其 proxy 部署与升级授权独立于 ProxyDeployer。`[代码已证]`
- Launcher 保存的是 `POLend` / `POLSplitter` 的 proxy 地址，当前规范不提供 setter、地址级替换、迁移或降级零地址模式；这只约束 proxy 地址本身，不否定 proxy 实现升级。`POLend` 与 `POLSplitter` 均为 UUPS，`_authorizeUpgrade(...)` 由 `onlyOwner` 放行。`[代码已证]`
- `MemeverseUniswapHook` 使用 `ERC1967Proxy + UUPS`。Hook implementation 持 UUPS `_authorizeUpgrade` / `upgradeToAndCall` 升级入口；升级授权由 Hook `owner()` 经 `_authorizeUpgrade(...) => onlyOwner` 控制。`script/DeployMemeverseHookProxy.s.sol` 创建 Hook proxy 时使用 `ERC1967Proxy(implementation, initializeData)`（2 参数，UUPS 不传 owner 给 proxy constructor，owner 经 `initialize` 植入 Hook storage）。same-nonce / existing Hook proxy 复用路径校验 `EXPECTED_HOOK_PROXY_CODEHASH`（ERC1967Proxy runtime）与 Hook `owner()`（完整复用校验路径见 [operations.md](../operations.md)）；运维侧 ownership transfer 即升级授权转移，无 ProxyAdmin 对齐需求。`poolManager` 一致性是 Hook on-chain upgrade guardrail（`_authorizeUpgrade` 内先做无代码守卫，`newImplementation.code.length == 0` 时 revert `UpgradeTargetCodeNotReady`，再做 `UpgradePoolManagerMismatch` 检查）；operator/off-chain upgrade checklist/runbook 仍建议执行 pre-check 作为双保险。`poolManager` 不在 proxy storage 中，升级替换字节码后若真实值不同，`_authorizeUpgrade` 会 revert `UpgradePoolManagerMismatch` 阻止升级；若绕过该守卫（如恶意 owner 伪造 getter），hook 回调将指向错误目标，导致所有 swap 和流动性操作永久失效。`[代码已证]`
- **Hook 与 facet 升级模型**：dynamic fee logic 位于 `DynamicFeeFacet`，rebate accrual 位于 `src/swap/SwapFacet.sol::_settleProtocolFee`（`_collectProtocolFee` 调用，经 Router DELEGATECALL 共享 hook storage）；hook owner 经 `setFacet(bytes32 role, address facet)` 替换 facet 地址，role 取 `SWAP_FACET_ROLE` / `DYNAMIC_FEE_FACET_ROLE` / `SETTLEMENT_FACET_ROLE` 三个 `bytes32` 常量。返佣 storage（`referrerRebateBps` / `pendingRebate`）位于 hook ERC7201 namespace `outrun.storage.MemeverseUniswapHook`；hook `initialize` 写入默认 `referrerRebateBps = 1000` 并触发 `ReferrerRebateBpsUpdated(0, 1000)`。`setFacet(DYNAMIC_FEE_FACET_ROLE, newAddr)` 只换 facet 地址，不修改 hook storage。DynamicFeeFacet 经 DELEGATECALL 拥有 hook 全 storage 写权，属于 facet 信任边界。`[代码已证]`
- hook storage 冻结约束：一旦部署，所有 facet 共享的 `MemeverseUniswapHookStorage` 字段顺序冻结，任何升级不能改动字段顺序，只能在尾部追加。违反此约束会破坏所有 facet 的 storage 读写，包括 rebate。`[代码已证]`
- facet 防直接调用：facet 是独立部署合约，其 logic 函数为 `external`（DELEGATECALL 要求），但第三方可直接 CALL facet 地址，此时 facet 会在自己的空 / 未初始化 storage 上下文执行。facet 用 `__self` immutable 守卫防直接 CALL：`__self` 在部署时固定为 facet 自己的地址（immutable，字节码级，不占 storage slot），每个 logic 函数开头经 `onlyViaRouter` 检查 `address(this) != __self`；经 Router DELEGATECALL 时 `address(this)` = hook proxy ≠ `__self`(facet) 通过，直接 CALL 时 `address(this)` = facet == `__self` revert（不依赖 storage 读，靠 immutable 自比较）。`[代码已证]`
- `MemeverseUniswapHook.initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_)` 初始化 owner、treasury、LP token implementation 与 3 个 facet 地址，并写入默认启动费率配置与默认 `referrerRebateBps = 1000`。初始化时校验 3 facet 字节码就绪且 poolManager 与 hook 一致。部署顺序：部署 3 facet（constructor 传 hook 的 poolManager）→ 部署 Router implementation + hook proxy（proxy 地址需 HookMiner 挖 flag）→ `initialize` 传 facet 地址。成功初始化触发以下 hook-product 事件：`FacetUpdated(SWAP_FACET_ROLE, address(0), swapFacet_)`、`FacetUpdated(DYNAMIC_FEE_FACET_ROLE, address(0), dynamicFeeFacet_)`、`FacetUpdated(SETTLEMENT_FACET_ROLE, address(0), settlementFacet_)`、`TreasuryUpdated(address(0), treasury_)`、`LPTokenImplementationUpdated(address(0), lpTokenImplementation_)`、`DefaultLaunchFeeConfigUpdated(0,0,0,5000,100,900)` 与 `ReferrerRebateBpsUpdated(0, 1000)`（inherited `Ownable` 的 `OwnershipTransferred(address(0), initialOwner)` 经 `__OutrunOwnable_init` 先于上列触发，按 [events catalog](../events.md) hook-product 惯例不在此列）。`[代码已证]`
- `lpTokenImplementation` 是 first-class deployment artifact 之一（非 UUPS surface；完整清单见 implementation-map.md）；脚本必须在 `DeploymentResult.lpTokenImplementation` 中返回。same-nonce 复用时校验预测地址、地址非零与代码存在；运行期 codehash 必须等于 `EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH`（见 `script/DeployMemeverseHookProxy.s.sol::_validateExistingImplementationCodehashes`）；readiness 不包含 pool-manager getter 检查。`[代码已证]`
- `lpTokenImplementation` 暴露 owner setter `setLpTokenImplementation`（`src/swap/MemeverseUniswapHook.sol::setLpTokenImplementation`），可由 owner 替换克隆模板；但替换仅影响后续新建的 pool，已部署 pool 的 LP token clone 不受影响。根因：`lpTokenImplementation` 是每个 pool 在 `beforeInitialize` 经 `Clones.clone` 独立克隆的模板（`src/swap/SwapFacet.sol::beforeInitializeLogic`），EIP-1167 minimal proxy 在 clone 时即固化实现地址，clone 实例不可迁移。因此 `setLpTokenImplementation` 替换指针后，仅对此后新建的 pool 生效；已存在 pool 的 LP token clone 永久指向旧实现，无法热修，只能引导流动性迁移到新 pool。settlement logic 由 SettlementFacet 承载；`setFacet(SETTLEMENT_FACET_ROLE, ...)` 替换其地址并对所有 pool 立即生效。`[代码已证]`
- `feePreviewReader` 是 Launcher 的独立 view 合约（非 UUPS surface、非 delegatecall 目标）；Launcher owner 可经 `setFeePreviewReader` 原子替换指针，替换后所有外部预览调用立即指向新 reader。与 `MemeverseBootstrap` / `MemeverseFeeDistributor` 形似而本质不同：reader 通过 immutable `PROXY` staticcall 读 proxy getter，不绑 ERC-7201 名域、不接收 delegatecall、永不写 proxy storage，因此升级 `MemeverseLauncherStorage` struct 时 reader 无需跟 sibling 同步重编；EOA 直调 reader 是其正常用法，不存在"零地址 void delegatecall 静默成功"风险，readiness 校验 `feePreviewReader` 有代码是唯一防线。`[代码已证]`
  - 证据：`src/verse/MemeverseFeePreviewReader.sol::PROXY`、`::constructor`；`src/verse/MemeverseLauncher.sol::setFeePreviewReader`；`script/MemeverseScript.s.sol::_readLauncherImplSiblings`、`::_requireContractCode`
- `POLend.initialize(...)` 必须拒绝 `leveragedDebtFactor_ > uint128.max * 1e18`；后续 owner setter 使用同一技术上限，升级不得放宽该边界。`[代码已证]`
- Hook proxy implementation 升级（UUPS `upgradeToAndCall`）保留返佣：rebate custody 与 `pendingRebate` / `referrerRebateBps` 都在 hook proxy 的 ERC7201 storage（`outrun.storage.MemeverseUniswapHook`），换 Router 字节码不改变 hook storage、不改变 `pendingRebate`、不改变 `referrerRebateBps`。换 Router 后若新 Router 仍指向同一组 facet 地址（或经 `setFacet` 更新到新 facet），rebate accrual / claim 路径不受影响；ABI 兼容边界仅包括 external `claimRebate` 入口，以及 Router 到 `ISwapFacet` 的相关 delegatecall interfaces。`_collectProtocolFee` 是 SwapFacet 内部函数，不是 calldata / entry ABI；升级须保留其 protocol fee / rebate 记账语义，而非其 calldata 或入口 ABI（返佣记账内联进 `_settleProtocolFee`，由 `_collectProtocolFee` 与 beforeSwap 主路径调用，无独立 `accrueRebate` 入口）。`[代码已证]`
- `MemeverseBootstrap` 是 Launcher facade 受信 `delegatecall` 目标，属 Launcher proxy 受信代码集；`setBootstrapImpl` 为 `onlyOwner`，与 Launcher 其他 admin setter 一致。`[代码已证]`
  - sibling 与 Launcher facade 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；sibling 只写 bootstrap 语义字段，零越界写其他 storage。Bootstrap、FeeDistributor 与 POLMinter 共享同一 `IMemeverseLauncherStorage::MemeverseLauncherStorage` struct，升级该 struct 时三者必须同步重编（详见下方 `MemeverseFeeDistributor` 段）。
  - facade `::_deployLiquidity` 前置守卫 `bootstrapImpl != address(0)`（`BootstrapImplNotSet`），防零地址 void `delegatecall` 静默成功、bootstrap 不执行却推进状态。
  - sibling 被 EOA 直调时读自身空 storage 回退（sibling 无 `Initializable`、无自身 storage），不构成可利用路径。
  - 证据：`src/verse/MemeverseBootstrap.sol`；`src/verse/MemeverseLauncher.sol::setBootstrapImpl`、`::_deployLiquidity`；`src/verse/interfaces/IMemeverseBootstrap.sol::deployLiquidity`；`src/verse/interfaces/IMemeverseLauncher.sol::BootstrapImplNotSet`
- `MemeverseFeeDistributor` 同属 Launcher proxy 受信 `delegatecall` 目标集；`setFeeDistributorImpl` 为 `onlyOwner`，与 `setBootstrapImpl` 一致。`[代码已证]`
  - sibling 与 Launcher/Bootstrap 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；升级 `MemeverseLauncherStorage` struct 时 Bootstrap、FeeDistributor 与 POLMinter 必须用相同 struct 同步重编，否则 facade 经 delegatecall 调任一 sibling 时读写错位。
  - facade `::redeemAndDistributeFees` 与 `changeStage` Locked→Unlocked 分支前置守卫 `feeDistributorImpl != address(0)`（`FeeDistributorImplNotSet`），防零地址 void `delegatecall` 静默成功、fee 不执行却推进状态，与 `BootstrapImplNotSet` 同理。
  - sibling 被 EOA 直调时读自身永久未初始化的 storage（sibling 无 `Initializable`、无自身 storage）回退，不构成可利用路径。
  - 证据：`src/verse/MemeverseFeeDistributor.sol`；`src/verse/MemeverseLauncher.sol::setFeeDistributorImpl`、`::redeemAndDistributeFees`、`::changeStage`；`src/verse/interfaces/IMemeverseFeeDistributor.sol::collectAndDistributeFees`、`::captureLockedAuxiliaryFees`；`src/verse/interfaces/IMemeverseLauncher.sol::FeeDistributorImplNotSet`

## 5. 与文档链的关系

- deployer + governance proxy 属于 launcher 生命周期编排的一部分，与上述代码路径一致。
- Harness 层对 `src/**/*.sol` 的 gate、review 与测试映射要求以 `.harness/policy.json` 为真源；governance 升级路径已由 governance / deployment 相关测试与 policy 内的测试映射覆盖。

## 6. 确定性与未知项

- 高确定性
  - 合约是否声明 UUPS / initializer、是否通过 clone/proxy 部署，均可由源码直接判定。
  - governor / incentivizer 的 proxy 初始化与 `upgradeToAndCall` 授权路径已有执行级测试证据。
- 中确定性
  - 线上部署是否额外挂接 timelock、多签或其他治理执行者封装，不在仓库证据范围内。
- 未知项
  - 当前仓库未给出“生产链部署清单 + 环境级治理执行者配置”文档，因此无法给出环境级最终控制人结论；所有 UUPS surface（含 diamond Router Hook）均不使用独立 `ProxyAdmin` 角色。
