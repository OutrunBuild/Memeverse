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
| RegistrarAtLocal | constructor 部署 | constructor | 不适用 | `src/verse/registration/MemeverseRegistrarAtLocal.sol::constructor` |
| RegistrarOmnichain | constructor 部署 | constructor | 不适用 | `src/verse/registration/MemeverseRegistrarOmnichain.sol::constructor` |
| OmnichainInteroperation | constructor 部署 | constructor | 不适用 | `src/interoperation/MemeverseOmnichainInteroperation.sol::constructor` |
| LzEndpointRegistry | constructor 部署 | constructor | 不适用 | `src/common/omnichain/LzEndpointRegistry.sol::constructor` |
| ProxyDeployer | constructor 部署 | constructor | 不适用 | `src/verse/deployment/MemeverseProxyDeployer.sol::constructor` |
| `lpTokenImplementation` | constructor 部署；`DeploymentResult.lpTokenImplementation` 返回 | constructor | 不适用 | `script/DeployMemeverseHookProxy.s.sol`（部署脚本） |
| `feePreviewReader` | constructor 部署；immutable `PROXY` 绑 Launcher proxy 地址；非 delegatecall 目标，仅 staticcall 读 proxy getter | constructor | 不适用（地址替换由 Launcher owner `setFeePreviewReader` 控制） | `src/verse/MemeverseFeePreviewReader.sol::constructor`、`::PROXY`；`src/verse/MemeverseLauncherUpgradeable.sol::setFeePreviewReader` |
| **最小代理 clone（不可升级）** | | | | |
| `Memecoin` / `MemePol` / `MemecoinYieldVault` | EIP-1167 clone | 外部 `initialize`（单次） | 无实现内升级入口 | `src/verse/deployment/MemeverseProxyDeployer.sol::deployMemecoin`、`::deployPOL`、`::deployYieldVault`; `src/token/Memecoin.sol::initialize`; `src/token/MemePol.sol::initialize`; `src/yield/MemecoinYieldVault.sol::initialize` |
| **UUPS 可升级** | | | | |
| `MemeverseLauncherUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, localLzEndpoint_, memeverseRegistrar_, memeverseProxyDeployer_, yieldDispatcher_, lzEndpointRegistry_, polend_, polSplitter_, executorRewardRate_, oftReceiveGasLimit_, yieldDispatcherGasLimit_, preorderCapRatio_, preorderVestingDuration_)` | `_authorizeUpgrade(...) => onlyOwner` | `src/verse/MemeverseLauncherUpgradeable.sol`（`_authorizeUpgrade`）; `script/MemeverseScript.s.sol`（部署脚本） |
| `MemecoinDaoGovernorUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(...)` | `_authorizeUpgrade(...) => onlyGovernance` | `src/governance/MemecoinDaoGovernorUpgradeable.sol`（`_authorizeUpgrade`）; `src/verse/deployment/MemeverseProxyDeployer.sol`（proxy 部署） |
| `GovernanceCycleIncentivizerUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(...)` | `_authorizeUpgrade(...) => onlyGovernance` | `src/governance/GovernanceCycleIncentivizerUpgradeable.sol`（`_authorizeUpgrade`）; `src/verse/deployment/MemeverseProxyDeployer.sol`（proxy 部署） |
| `POLendUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, interestRate_, leveragedDebtFactor_, treasury_, launcher_, splitter_, creditFactory_)` | `_authorizeUpgrade(...) => onlyOwner` | `src/polend/POLendUpgradeable.sol`（`_authorizeUpgrade`） |
| `POLSplitterUpgradeable` | `ERC1967Proxy` + UUPS | `initialize(initialOwner, _launcher)` | `_authorizeUpgrade(...) => onlyOwner`；PT/YT 克隆模板指针经 owner `setTokenImplementations` 成对替换（仅影响后续 verse 的 `initializeVerse`，存量 clone 冻结） | `src/polend/POLSplitterUpgradeable.sol`（`_authorizeUpgrade`）；`src/polend/POLSplitterUpgradeable.sol::setTokenImplementations` |
| YieldDispatcherUpgradeable | `ERC1967Proxy` + UUPS | `initialize(initialOwner, _localEndpoint, _memeverseLauncher, _protocolTreasury)` | `_authorizeUpgrade(...) => onlyOwner` | `src/verse/YieldDispatcherUpgradeable.sol::initialize`、`::_authorizeUpgrade` |
| `MemeverseRegistrationCenterUpgradeable` | `ERC1967Proxy` + UUPS；基于 LayerZero upgradeable OApp 基座（`OAppUpgradeable`，remapping `@layerzerolabs/oapp-evm-upgradeable/=lib/devtools/packages/oapp-evm-upgradeable/`，仅导入其 `contracts/`） | implementation `constructor(address _lzEndpoint)` 传 endpoint 给 `OAppUpgradeable` 后 `_disableInitializers()`；proxy 经 `initialize(initialOwner, _memeverseRegistrar, _lzEndpointRegistry)` 写入 owner 槽（`__Ownable_init` / `__OApp_init`，后者含 `endpoint.setDelegate(initialOwner)`）与自有 storage 字段 `memeverseRegistrar` / `lzEndpointRegistry`；deploy + initialize 经 ERC1967Proxy constructor data 原子完成（CREATE3，镜像 `_deployYieldDispatcher`）；`receive()` 挂 `DelegatecallOnly::onlyDelegatecall`——impl 直转 ETH revert `DelegatecallOnlyCall` 原路退回（impl owner 恒 0、无清扫出口，误转不再滞留），proxy 上下文退款路径不变（LayerZero native refund 依赖 impl 的 `receive` 经 fallback 委托执行）（`MemeverseRegistrationCenterUpgradeable.sol::receive`、`src/common/access/DelegatecallOnly.sol`） | `_authorizeUpgrade(...) => onlyOwner`；先无代码守卫（revert `UpgradeTargetCodeNotReady`），再校验 `IOAppCore(newImplementation).endpoint() == endpoint()`（不匹配 revert `UpgradeEndpointMismatch`）——运维护栏而非安全边界，与 `MemeverseUniswapHookUpgradeable.sol::_authorizeUpgrade` 的 poolManager guard 同定性；有代码但 getter 缺失或调用 revert 时具名 revert `UpgradeEndpointUnreadable`（不落裸 ABI-decode revert，与无代码守卫同属可 grep 的诚实失败）；owner 基座为 OZ `OwnableUpgradeable`（OApp 基座内建、单 owner 槽，不使用 `OutrunOwnableUpgradeable` 以避免双 owner 槽，偏离已在合约 NatSpec 记录），`renounceOwnership` 经共享基座 `OutrunOAppUpgradeable` 覆盖为恒 revert（保持全仓 never-renounceable 语义，基座镜像 Outrun ownable 家族的基座级编码） | `src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol::constructor`、`::initialize`、`::setMemeverseRegistrar`、`::_authorizeUpgrade`；storage layout at `erc7201("outrun.storage.MemeverseRegistrationCenter")`，字段只允许尾部追加 |
| `OmnichainMemecoinStakerUpgradeable` | `ERC1967Proxy` + UUPS（镜像 `YieldDispatcherUpgradeable`） | `constructor()` 仅 `_disableInitializers()`；`initialize(initialOwner, _localEndpoint)` 具名零检查后写入 storage | `_authorizeUpgrade(...) => onlyOwner`（无 endpoint guard——`localEndpoint` 是 proxy storage 而非 implementation immutable）；owner 仅持升级授权，升级权等同对滞留 bridged memecoin 的托管权（与 `YieldDispatcherUpgradeable` 同一接受的 residual）；`OutrunOwnableUpgradeable`（never-renounceable） | `src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::initialize`、`::_authorizeUpgrade`；storage layout at `erc7201("outrun.storage.OmnichainMemecoinStaker")`，字段只允许尾部追加 |
| **UUPS 可升级（diamond Router）** | | | | |
| `MemeverseUniswapHookUpgradeable`（Router） | `ERC1967Proxy` + UUPS | `initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_, launcher_)` | `_authorizeUpgrade(...) => onlyOwner`（Hook `owner()`）；3 facet 地址经 owner `setFacet(bytes32 role, address facet)` 独立替换 | `script/DeployMemeverseHookProxy.s.sol`（Hook proxy 部署与 existing proxy 校验）；`src/swap/MemeverseUniswapHookUpgradeable.sol::initialize`、`::setFacet`；getter 区 `::lpTokenImplementation`、`::swapFacet`、`::dynamicFeeFacet`、`::settlementFacet` |
| **Diamond facet（非 proxy，可替换实现）** | | | | |
| `SwapFacet`（`SWAP_FACET_ROLE`） | Hook Router 显式 entry 经 `delegatecall` 调度的 v4 callback / LP snapshot logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(SWAP_FACET_ROLE, facet)` 替换 | `src/swap/SwapFacet.sol`; `src/swap/interfaces/ISwapFacet.sol`; `src/swap/MemeverseUniswapHookUpgradeable.sol::setFacet` |
| `DynamicFeeFacet`（`DYNAMIC_FEE_FACET_ROLE`） | Hook Router、`SwapFacet` 与 `SettlementFacet` 经 `delegatecall` 调度的动态费率 logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(DYNAMIC_FEE_FACET_ROLE, facet)` 替换 | `src/swap/DynamicFeeFacet.sol`; `src/swap/interfaces/IDynamicFeeFacet.sol`; `src/swap/MemeverseUniswapHookUpgradeable.sol::setFacet` |
| `SettlementFacet`（`SETTLEMENT_FACET_ROLE`） | Hook Router 显式 entry 经 `delegatecall` 调度的 preorder settlement / unlock callback logic | constructor(`IPoolManager`)；无 `initialize` | Hook `owner()` 经 `setFacet(SETTLEMENT_FACET_ROLE, facet)` 替换 | `src/swap/SettlementFacet.sol`; `src/swap/interfaces/ISettlementFacet.sol`; `src/swap/MemeverseUniswapHookUpgradeable.sol::setFacet` |
| **Facade delegatecall 目标（非 proxy）** | | | | |
| `MemeverseLaunchImpl` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setLaunchImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeverseLaunchImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl`、`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`（内部 delegatecall `MemeverseLiquidityImpl::deployBootstrapLiquidity`）；`src/verse/interfaces/IMemeverseLaunchImpl.sol::registerMemeverse`、`::genesis`、`::preorder`、`::changeStage` |
| `MemeverseSettlementImpl` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setSettlementImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeverseSettlementImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setSettlementImpl`、`::redeemAndDistributeFees`、`changeStage` Locked→Unlocked delegatecall 调用点（dispatcher 在 `MemeverseLaunchImpl::changeStage`，嵌套 delegatecall `MemeverseSettlementImpl::unlockFromLocked`）；`src/verse/interfaces/IMemeverseSettlementImpl.sol::collectAndDistributeFees`、`::unlockFromLocked` |
| `MemeverseLiquidityImpl` | Launcher facade `delegatecall` 目标（非 proxy） | 无（纯逻辑合约，读 proxy storage） | owner `setLiquidityImpl` 替换指针（非 UUPS `upgradeToAndCall`） | `src/verse/MemeverseLiquidityImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setLiquidityImpl`、`::mintPOLToken`、`changeStage` Genesis→Locked delegatecall 调用点（dispatcher 在 `MemeverseLaunchImpl::changeStage`，嵌套 delegatecall `MemeverseLiquidityImpl::deployBootstrapLiquidity`）；`src/verse/interfaces/IMemeverseLiquidityImpl.sol::deployBootstrapLiquidity`、`::mintPOLToken` |

**UUPS 转换的依赖存法判据（localEndpoint 类）**：

转换 constructor 部署合约为 UUPS 时，「构造期可固化的依赖」（如本链 LayerZero endpoint）的存法按两条判据选——(1) 继承 LayerZero `OAppUpgradeable` 基座（其构造签名强制 endpoint 为 implementation immutable），或需要跨升级一致性锚点（升级时校验新 implementation 烘焙值不变）→ 构造 immutable + `_authorizeUpgrade` endpoint 守卫（`MemeverseRegistrationCenterUpgradeable` 式；读取免费，但每次升级须重传同值、依赖守卫防错位）；(2) 无 LZ 基座、跟随 composer 家族、无需升级期校验 → `initialize` 写 ERC-7201 storage（`YieldDispatcherUpgradeable` / `OmnichainMemecoinStakerUpgradeable` 式；指针随 proxy storage 跨升级天然存活、升级零心智负担，热路径每次读取付 ~2.1k 冷 SLOAD（2100，EIP-2929 槽位价）——已由 `test/interoperation/LzComposeGasBenchmark.t.sol` 基准接受）。热路径读频次高且无基座强迫时优先 immutable。两式并存为有意设计非漂移。

### 2.1 Diamond facet 替换兼容约束

- role 的 ABI 契约分别是 `ISwapFacet`、`IDynamicFeeFacet` 与 `ISettlementFacet`。`SwapFacet` 的 `*Logic` 参数必须与 Router 外层 v4 callback 的参数顺序和类型 1:1 镜像；所有 role 的 selector、参数 ABI 与返回 ABI 必须保持兼容。`SettlementCallbackData` / `SettlementResult` 的编解码也属于 `SettlementFacet` 的兼容契约。
- `setFacet` 在链上只验证 `onlyOwner`、已知 role、非零地址、候选地址有字节码，以及 `ImmutableState(facet).poolManager()` 与 Hook `poolManager` 一致；它不验证完整 role ABI、共享 storage layout 或 `onlyViaRouter`。
- 三个 facet 必须以同一个 `IPoolManager` 构造，并通过 `layout at erc7201("outrun.storage.MemeverseUniswapHook")` 和 `IMemeverseHookStorage` 使用同一 `MemeverseUniswapHookStorage`。字段顺序冻结，只能尾部追加。
- facet 应保留 `FacetGuard.onlyViaRouter` 的 direct-`CALL` 拒绝。该 guard 只区分 direct `CALL` 与 `delegatecall`，不认证 delegatecall 的宿主一定是指定 Hook proxy。
- `IDynamicFeeFacet.quote` 必须保持 `view`。`MemeverseUniswapHookUpgradeable.quoteSwapFeeWithContext` 是 `external` 无调用者限制的 Router entry，经普通 `DELEGATECALL`（`_facetDelegatecall` → `Address.functionDelegateCall`，非 STATICCALL）调度 facet；其只读性外包给 facet 的 `view` 修饰符，因 solc 0.8.35 Error 8961 禁止 `view + delegatecall`，entry 自身无法声明 `view`。Lens 路径因 `Address.functionStaticCall`（STATICCALL，EIP-214 上下文穿透 delegatecall）恒安全；但直调路径（任意 EOA CALL）无此保护，只读性完全依赖 `quote` 保持 `view`。若未来升级把 `quote` 改为非 view 且函数体写 storage，直调 `quoteSwapFeeWithContext` 将成为无 swap、无权限、无费用的零成本状态变更面（如刷新 volatility anchor 操纵动态费率时间戳）。当前 `quote` 为 `view` 且函数体操作 memory 副本不写 storage，无可达影响。`[代码已证]`

### 2.2 Smart EOA transient session 的 paired release `[代码已证]`

- Hook implementation 与 `SwapFacet` 必须作为兼容的 paired release 发布；两者不得依赖彼此尚未生效的 session ABI 或 callback 语义。
- session context 仅为 Hook-owned transient state：不引入持久 storage migration，不迁移历史 session，也不新增 session begin/end event。
- Hook implementation 与 `SwapFacet` 是同一兼容 release unit 的已落地配对。对于已上线 Hook，不能把先升级 Hook implementation、再替换 `SwapFacet`（或反序）描述为安全；任何 live upgrade 都需要另行批准的 runbook、执行顺序与验证证据。

### 2.3 Facade sibling 轮换（rotation）责任清单

owner 经 `src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl` / `::setSettlementImpl` / `::setLiquidityImpl` 替换 sibling 指针（普通 setter 换指针，非 UUPS `upgradeToAndCall`）；setter 链上只校验 `impl != address(0)`，以下责任由 owner（multisig）在轮换时承担：

- 新实现必须已部署（有代码），并实现对应接口（`IMemeverseLaunchImpl` / `IMemeverseSettlementImpl` / `IMemeverseLiquidityImpl`）的全部 selector，ABI 与返回语义保持兼容：delegatecall 不做 ABI 检查，错误实现会让依赖该 sibling 的入口失效（运行时多为响亮 revert；带 fallback 的错合约在 `src/verse/interfaces/IMemeverseLaunchImpl.sol::genesis` / `::preorder` / `::genesisAndPreorder` / `::registerMemeverse` 四个非解码入口是静默 no-op）。
- 新实现必须继承 `DelegatecallOnly`：否则直接调用不再以 `DelegatecallOnlyCall` 拒绝，防护姿态静默改变（直接调用以自身空 storage 执行，ACL 读空 storage 大多 fail-closed，但具名拒绝面消失）。
- 存储布局必须与共享 `outrun.storage.MemeverseLauncher` namespace 的 `IMemeverseLauncherStorage::MemeverseLauncherStorage` struct 保持同步：升级该 struct 时三者必须同步重编（该约束已由 §4 三个 sibling 段落覆盖，此处不重复展开）。
- 前置校验（如 `impl.code.length > 0`）可把 EOA 错误提前到设置时刻暴露，但 ABI / 布局兼容无法链上校验，最终责任在 owner（multisig）。

## 3. 初始化约束（当前代码实际支持）

### 3.1 最小代理初始化一次性

- `src/common/access/Initializable.sol` 在实现合约 constructor 中把 `initialized=true`，阻止实现本体被初始化。
  - 证据：`src/common/access/Initializable.sol::constructor`
- clone 实例通过 `initializer` 进入一次初始化，重复调用回退 `AlreadyInitialized`。
  - 证据：`src/common/access/Initializable.sol::initializer`（modifier）与 `::AlreadyInitialized`（error）

### 3.2 由 launcher 驱动 token 初始化

- launcher 在注册时通过 deployer 克隆 `memecoin`/`POL` 并立即 `initialize`。
  - 证据：`src/verse/MemeverseLaunchImpl.sol::_deployAndInitializeVerseTokens`

**owner 与 delegate 的初始化值：**

- `initialize` 调用时，`owner` 和 `delegate` 均被设为 `msg.sender`——即执行调用的 launcher 实例（`address(this)`）。
  - 含义：刚部署的 memecoin / POL token 的 admin 权限（owner）与治理代理权（delegate）都归属于 launcher。
  - 证据：`src/verse/MemeverseLaunchImpl.sol::_deployAndInitializeVerseTokens`; `src/token/Memecoin.sol::initialize`; `src/token/MemePol.sol::initialize`
- 此行为仅反映源码层的初始化语义；线上部署后 owner 是否被迁移（例如转给多签 / timelock）不在仓库证据范围内。
  - 同源：section 6 "中确定性" 条目

### 3.3 governance 组件仅在治理链本地部署初始化

- 当 `govChainId == block.chainid`：部署并初始化 `yieldVault/governor/incentivizer`。
  - 证据：`src/verse/MemeverseLaunchImpl.sol::_deployGovernanceComponents`（local 分支：`govChainId == block.chainid`）
- 否则只做地址预测，不在当前链初始化。
  - 证据：`src/verse/MemeverseLaunchImpl.sol::_deployGovernanceComponents`（remote 分支：`govChainId != block.chainid`）

### 3.4 Launcher UUPS 初始化事实

- 当前 `MemeverseLauncherUpgradeable` 是 `ERC1967Proxy + UUPS` surface。实现合约 constructor 只调用 `_disableInitializers()`，阻止 implementation 本体被初始化。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::constructor`
- Launcher proxy 通过 `initialize(...)` 写入 canonical 配置：`initialOwner`、local endpoint、registrar、proxy deployer、yield dispatcher、endpoint registry、`POLendUpgradeable`、`POLSplitterUpgradeable`、gas、reward 与 preorder 初始配置。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::initialize`
- Launcher 升级通过 UUPS `upgradeToAndCall(...)` 进入实现合约，并由 `_authorizeUpgrade(...) => onlyOwner` 放行。
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::_authorizeUpgrade`
- 协议真实 Launcher 地址是 `IOutrunDeployer` CREATE3 部署的 ERC1967 proxy 地址，不是 implementation 地址。脚本对 implementation salt 与 proxy salt 分开建模，`MemeverseLauncherUpgradeable` salt 对应 canonical proxy 地址。
  - 证据：`script/MemeverseScript.s.sol::_deployMemeverseProxyDeployer`、`::_deployMemeverseLauncher`
- `deployCaller` 是执行 CREATE3 / proxy 部署的调用者，`initialOwner` 是 Launcher proxy 初始化后的 owner；两者显式拆分。默认脚本支持两种模式：`deployCaller == initialOwner` 时脚本在部署中直接写入 `setFundMetaData`；`deployCaller != initialOwner` 时跳过 fund metadata，由 `initialOwner` 单独调用 `setFundMetaData`。测试 harness 通过覆盖 `_beginMemeverseLauncherOwnerExecution` 实现 `vm.startPrank` 以在单交易内测试双角色路径。`[代码已证]`
  - 证据：`script/MemeverseScript.s.sol::_deployMemeverseLauncher`、`::_setMemeverseLauncherFundMetaData`; `test/verse/deployment/MemeverseProxyDeployer.t.sol::_beginMemeverseLauncherOwnerExecution`
- `POLendUpgradeable` / `POLSplitterUpgradeable` 通过 Launcher `initialize(...)` 参数（`polend_`、`polSplitter_`）写入，且必须是各自 canonical proxy address。
- readiness 检查覆盖 Launcher proxy 可读配置、launcher-bound 依赖 back-reference、`fundMetaDatas[uAsset]`、`POLendUpgradeable.settlementDustStates(uAsset).maxReserve`，以及 `launchImpl` / `settlementImpl` / `liquidityImpl` / `feePreviewReader` 有代码，不能只检查 implementation 或 proxy code 存在；swap-router 与 hook 的 PoolManager 一致性（`router.poolManager() == hook.poolManager()`）亦在 readiness 范围内，与 3 facet 的 `_requireFacetPoolManager` 对称（错误串 `ROUTER_POOL_MANAGER_NOT_READY`），避免 router↔hook PoolManager 不一致导致 `NotPoolManager` 路径 DoS。`[代码已证]`
  - 证据：`script/MemeverseScript.s.sol::_checkMemeverseLauncherDeployment`、`::_requireDeploymentReady`、`::_requireFundMetaDataReady`、`::_readSettlementDustState`、`::_requireSwapReady`
- readiness 不再使用不存在的 launcher direct config getter（`memeverseRegistrar()` / `memeverseProxyDeployer()` / `yieldDispatcher()` / `polSplitter()`）：这些不是 launcher 真实 ABI。脚本通过一次 typed decode `getLauncherContracts()` 读出全部依赖字段（`memeverseRegistrar` / `memeverseProxyDeployer` / `yieldDispatcher` / `polSplitter` 与 `launchImpl` / `settlementImpl` / `feePreviewReader` / `liquidityImpl`）；`polend()` 保留 direct getter（真实 ABI，不在 `LauncherContracts`）。`[代码已证]`
- `launchImpl` 由部署期 owner `setLaunchImpl` 配置（非 `initialize` 参数）；launch 生命周期入口（`registerMemeverse` / `genesis` / `preorder` / `changeStage`）由 Launcher facade thin delegatecall entry 经 `delegatecall` 委托 `MemeverseLaunchImpl`，在 proxy storage 上下文执行。readiness 校验 `launchImpl` 有代码。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl`；`src/verse/MemeverseLaunchImpl.sol::registerMemeverse`、`::genesis`、`::preorder`、`::changeStage`
- `settlementImpl` 同样由部署期 owner `setSettlementImpl` 配置（非 `initialize` 参数）；fee 分发与 Locked→Unlocked 解算编排由 Launcher facade `::redeemAndDistributeFees`（直接 delegatecall）与 `changeStage` Locked→Unlocked 分支（经 `MemeverseLaunchImpl::changeStage` dispatcher 嵌套 delegatecall `MemeverseSettlementImpl::unlockFromLocked`）经 `delegatecall` 委托 `MemeverseSettlementImpl`，在 proxy storage 上下文执行。readiness 校验 `settlementImpl` 与 `feePreviewReader` 有代码，与 `launchImpl` 一致：三者均为用户路径上使用的 sibling/view 合约，缺失会让 `redeemAndDistributeFees` / `changeStage` Locked→Unlocked 回退 `SettlementImplNotSet`（或预览失效）；readiness 提前抓、运行时守卫兜底，双层防御与 `launchImpl` 对称。`liquidityImpl` 走同一套 readiness + 运行时守卫模式，详见下方 `MemeverseLiquidityImpl` 段。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::setSettlementImpl`、`::redeemAndDistributeFees`、`::changeStage`；`src/verse/MemeverseSettlementImpl.sol::collectAndDistributeFees`、`::_captureLockedAuxiliaryFees`、`::unlockFromLocked`；`script/MemeverseScript.s.sol::_requireDeploymentReady`
- `liquidityImpl` 同样由部署期 owner `setLiquidityImpl` 配置（非 `initialize` 参数）；bootstrap 流动性 / POL token 铸造 / LP 赎回由 Launcher facade `::mintPOLToken`（直接 delegatecall）与 `changeStage` Genesis→Locked 成功分支（经 `MemeverseLaunchImpl::changeStage` dispatcher 嵌套 delegatecall `MemeverseLiquidityImpl::deployBootstrapLiquidity`）经 `delegatecall` 委托 `MemeverseLiquidityImpl`，在 proxy storage 上下文执行。`MemeverseLiquidityImpl` 与 `MemeverseLaunchImpl` / `MemeverseSettlementImpl` 同类（空 constructor、无 `Initializable`、共享 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct）。readiness 校验 `liquidityImpl` 有代码，与 `launchImpl` / `settlementImpl` 一致；缺失会让 `mintPOLToken` 或 `changeStage` Genesis→Locked bootstrap 回退 `LiquidityImplNotSet`，readiness 提前抓、运行时守卫兜底，双层防御与前序 sibling 对称。`_deployLiquidity`（位于 `MemeverseLaunchImpl`）delegatecall `MemeverseLiquidityImpl::deployBootstrapLiquidity`。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::setLiquidityImpl`、`::mintPOLToken`、`src/verse/MemeverseLaunchImpl.sol::_deployLiquidity`；`src/verse/MemeverseLiquidityImpl.sol::deployBootstrapLiquidity`、`::mintPOLToken`；`src/verse/interfaces/IMemeverseLiquidityImpl.sol::deployBootstrapLiquidity`、`::mintPOLToken`、`::LiquidityImplNotSet`；`script/MemeverseScript.s.sol::_requireDeploymentReady`
- `creditFactory` 是 POLendUpgradeable 可替换运行态指针（owner-only `setCreditFactory` 替换，emit `CreditFactoryChanged`），由 `leveragedGenesisWithCredit` 在该 verse 首次 credit 注入时经 `IGenesisCreditFactory(creditFactory).creditOf(uAsset)` 解析 GenesisCredit 地址。readiness 校验 `POLendUpgradeable.creditFactory()` 有代码，与 launch / settlement / liquidity sibling 同类（均为用户路径上使用的接线指针）：缺失或被占位（如 `_buildPOLendCreationCode` 在未设 `CREDIT_FACTORY_PROXY` 时兜底写入的 `initialOwner` EOA，无代码）会让首次 `leveragedGenesisWithCredit` 对无代码地址 staticcall 返空、`abi.decode` revert，credit 路径静默阻断直到 `setCreditFactory`；readiness 提前抓，与 sibling 对称。校验"有代码"而非"非零"，因 owner 兜底非零、能蒙过零检查。`[代码已证]`
  - 证据：`src/polend/POLendUpgradeable.sol::leveragedGenesisWithCredit`、`::setCreditFactory`、`::creditFactory`；`script/MemeverseScript.s.sol::_requireDeploymentReady`、`::_buildPOLendCreationCode`
- `proxiableUUID()` 在 implementation 上可读；通过 proxy 调用 `proxiableUUID()` 必须按 UUPS guard 回退，不能作为 proxy readiness 成功检查。

### 3.5 Hook UUPS 初始化事实

- 当前 `MemeverseUniswapHookUpgradeable` 是 `ERC1967Proxy + UUPS` surface（diamond Router）。实现合约 constructor 调用 `_disableInitializers()`，阻止 implementation 本体被初始化。
  - 证据：`src/swap/MemeverseUniswapHookUpgradeable.sol::constructor`
- Hook proxy 通过 `ERC1967Proxy(implementation, initializeData)`（2 参数，不传 owner 给 proxy constructor）部署；owner 经 `initialize(...)` 植入 Hook storage。
  - 证据：`script/DeployMemeverseHookProxy.s.sol`（Hook proxy 部署与 existing proxy 校验）
- Hook `initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_, launcher_)` 写入 owner、treasury、LP token implementation、3 个 facet 地址与 launcher 绑定，并写入默认启动费率配置与默认 `referrerRebateBps = 1000`。
  - 证据：`src/swap/MemeverseUniswapHookUpgradeable.sol::initialize`
- Hook 升级通过 UUPS `upgradeToAndCall(...)` 进入实现合约，并由 `_authorizeUpgrade(address) internal view override onlyOwner` 放行（镜像 `src/verse/MemeverseLauncherUpgradeable.sol::_authorizeUpgrade`）。`_authorizeUpgrade` 先对新 implementation 做无代码守卫（`newImplementation.code.length == 0` 时 revert `UpgradeTargetCodeNotReady`），再内置 `poolManager` drift 检查：通过 `ImmutableState(newImplementation).poolManager()` 读取新 implementation 的 immutable PoolManager，与当前 `poolManager` 比较，不匹配 revert `UpgradePoolManagerMismatch`。有代码但 getter 缺失或调用 revert 时具名 revert `UpgradePoolManagerUnreadable`（try/catch 折叠，与无代码守卫同属可 grep 的诚实失败；调用成功但返回数据不可解码类不被折叠、裸冒泡仍 fail-closed——镜像 center `UpgradeEndpointUnreadable` 家族）。这是运维护栏而非安全边界（恶意 owner 可伪造 getter 绕过），保护对象是 honest upgrade 中的构造参数误用。
  - 证据：`src/swap/MemeverseUniswapHookUpgradeable.sol::_authorizeUpgrade`（UUPS 入口 + poolManager drift 检查）
- same-nonce / existing Hook proxy 复用校验使用 ERC1967Proxy runtime codehash，不检查 admin slot、`ProxyAdmin` owner 或 ProxyAdmin 与 Hook owner 对齐。
  - 证据：`script/DeployMemeverseHookProxy.s.sol::_validateExistingImplementationCodehashes`

### 3.6 铸币权单点与恢复边界

- `Memecoin.memeverseLauncher` / `MemePol.memeverseLauncher` 均为普通 storage 指针，仅 `initialize` 写入一次，全仓无 setter，不可由 owner 旋转（与 [access-control.md](access-control.md) 的 `Memecoin / MemePol memeverseLauncher initialize-only` 行一致）；token 经 `MemeverseProxyDeployer.deployMemecoin` / `deployPOL` 以 `cloneDeterministic`（EIP-1167）部署，实现字节码固化，无实现内升级入口。`[代码已证]`
  - 证据：`src/token/Memecoin.sol::initialize`、`::memeverseLauncher`; `src/token/MemePol.sol::initialize`、`::memeverseLauncher`; `src/verse/deployment/MemeverseProxyDeployer.sol::deployMemecoin`、`::deployPOL`
- 单点后果：launcher 被攻破 → `Memecoin.mint` / `MemePol.mint`（仅 `onlyMemeverseLauncher`）可无供给上限净增发（`OutrunERC20Init._update` mint 分支无 cap）；launcher 失能（owner 密钥丢失且实现损坏不可修复）→ 铸币权永久冻结，token 侧无任何恢复入口。`[代码已证]`
  - 证据：`src/token/Memecoin.sol::mint`; `src/token/MemePol.sol::mint`; `src/common/token/OutrunERC20Init.sol::_update`
- 恢复边界：唯一补救路径是 launcher UUPS `upgradeToAndCall` + `_authorizeUpgrade(...) => onlyOwner`，依赖 owner 密钥存续；升级只换 launcher 实现，不改变 token 指向的 launcher proxy 地址，不构成旋转。token owner == delegate == launcher（`MemeverseLaunchImpl._deployAndInitializeVerseTokens` 以 `address(this)` 传 owner/delegate），故 token 侧若新增 owner 门禁入口，launcher 无 passthrough 亦不可达——旋转能力必须以「token owner 独立于 launcher」的所有权模型为前提。`[代码已证]`
  - 证据：`src/verse/MemeverseLauncherUpgradeable.sol::_authorizeUpgrade`; `src/verse/MemeverseLaunchImpl.sol::_deployAndInitializeVerseTokens`; `src/token/Memecoin.sol::initialize`; `src/token/MemePol.sol::initialize`
- 关联信任面：`MemeverseLiquidityImpl.deployBootstrapLiquidity` 入口对 hook 授无限 uAsset 额度（`_safeApproveInf(uAsset, hookAddress)`），`_bootstrapPTPools` 对 `_polSplitter` 授无限 POL 额度（`_safeApproveInf(pol, _polSplitter)`）。授予对象是 launcher 关联的协议内组件：`POLSplitterUpgradeable.settle` / `recordPTBackingRatio` 仅 `onlyLauncher`；`split` / `merge` 为用户开放入口（`external nonReentrant`，无 `onlyLauncher`）：`split` 经 `safeTransferFrom(msg.sender, ...)` 拉取用户自有 POL，`merge` 仅 burn 用户自有 PT/YT 并以 `safeTransfer` 支付 splitter 余额，均不消耗 launcher 的授权。故该无限授权只有 launcher 上下文可消耗，launcher 被攻破（owner 密钥泄露或实现指针被替换）时成为资金搬运现成通路，与第 2 条同属单点攻破面。`[代码已证]`
  - 证据：`src/verse/MemeverseLiquidityImpl.sol::deployBootstrapLiquidity`、`::_bootstrapPTPools`; `src/polend/POLSplitterUpgradeable.sol::settle`、`::recordPTBackingRatio`、`::split`、`::merge`
- 产品决策项：如需旋转能力（如 `transferMemeverseLauncher`，仅 owner、two-step），必须先变更所有权模型并重新评估与 INV-09 单点意图的对齐，属产品决策；当前实现不包含该变更。

## 4. Proxy / Deployer 假设（仅限代码可证）

- 当前 `MemeverseLauncherUpgradeable` 是 UUPS surface，不使用独立 `ProxyAdmin`。
- `MemeverseProxyDeployer` 只允许 launcher 调用 deploy 系列函数。
  - 证据：`src/verse/deployment/MemeverseProxyDeployer.sol::onlyMemeverseLauncher`（modifier）；deploy 系列 `::deployMemecoin`、`::deployPOL`、`::deployYieldVault`、`::deployGovernorAndIncentivizer`
- governor 与 incentivizer 使用 `Create2 + ERC1967Proxy`，部署后立即执行 `initialize(...)`。
  - 证据：`src/verse/deployment/MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer`
  - 同 salt 无碰撞前提：两 proxy 复用同一 salt `keccak256(abi.encode(uniqueId))`（salt 公式见 [operations.md](../operations.md)，不在此重复），不碰撞因 init code 内嵌不同 implementation 地址（`governorImplementation` 与 `incentivizerImplementation` 为 distinct immutable 构造参数）；`computeGovernorAndIncentivizerAddress` 以同一 salt + 不同 init code 对称推导两地址。`[代码已证]`
  - `_unsafeAllowUninitialized` 语义：`MemeverseERC1967Proxy` 构造传空 `""` init data 并 override `_unsafeAllowUninitialized() → true`，绕过 OZ v5.6.0 构造期强制初始化（无此 override 则空 init-data 部署 revert `ERC1967ProxyUninitialized`），把 `initialize` 推迟到同交易内单独调用；正当性在于 governor 与 incentivizer 两个 `initialize` 均在 `deployGovernorAndIncentivizer` 同一笔交易内原子完成，闭合 OZ 警告的未初始化代理中间人窗口。`[代码已证]`
    - 证据：`src/verse/deployment/MemeverseProxyDeployer.sol::MemeverseERC1967Proxy`（构造与 `_unsafeAllowUninitialized` override）、`::deployGovernorAndIncentivizer`；OZ 基类 `ERC1967Proxy.sol`（构造期空-data 守卫与 `_unsafeAllowUninitialized` 默认 `false`）
  - 互引 initialize 序：两 proxy 先后部署完毕后，governor 先 `initialize`（参数带 incentivizer 地址）、incentivizer 后 `initialize`（参数带 governor 地址），解开互引循环依赖；因两地址在任一 `initialize` 前均已存在，此顺序为代码约定而非正确性强制。`[代码已证]`
- 当前治理组件采用 UUPS，不存在透明代理模式下的独立 `ProxyAdmin`；`upgradeToAndCall(...)` 进入实现合约后，由 `_authorizeUpgrade(...)` 决定是否放行。
  - governor：`_authorizeUpgrade(...) => onlyGovernance`
  - incentivizer：`_authorizeUpgrade(...) => onlyGovernance`（实际校验 `msg.sender == governor`）
  - 证据：`src/governance/MemecoinDaoGovernorUpgradeable.sol::_authorizeUpgrade`; `src/governance/GovernanceCycleIncentivizerUpgradeable.sol::_authorizeUpgrade`、`::onlyGovernance`（modifier）
- 升级提案的前置超多数门：`upgradeToAndCall(...)` 在 governor 执行派发前，`MemecoinDaoGovernorUpgradeable.sol::_executeOperations` 对 target 为 governor 自身 **或** 激励器的提案要求 `upgradeSupermajorityRatio` 超多数（见 [docs/spec/governance/governance-yield-details.md](governance/governance-yield-details.md) §7.3）；这与 `_authorizeUpgrade(...)` 的 `onlyGovernance` 是两层独立校验——后者校验升级瞬间的 caller，前者校验提案通过所需的票数门槛。激励器升级纳入超多数是因为激励器是经 `MemecoinDaoGovernorUpgradeable.sol::disburseReward` 可移动 treasury 资产的特权合约，简单多数升级会旁路 §7.2 cap。
- `POLendUpgradeable` 与 `POLSplitterUpgradeable` 不由 `MemeverseProxyDeployer` 部署；它们通过外部脚本/工厂独立部署，并以 Launcher `initialize(...)` 参数 `polend_`、`polSplitter_` 接线。其 proxy 部署与升级授权独立于 ProxyDeployer。`[代码已证]`
- Launcher 保存的是 `POLendUpgradeable` / `POLSplitterUpgradeable` 的 proxy 地址，当前规范不提供 setter、地址级替换、迁移或降级零地址模式；这只约束 proxy 地址本身，不否定 proxy 实现升级（该约束指 proxy 地址；PT/YT 克隆模板指针的 owner 替换通道见下）。`POLendUpgradeable` 与 `POLSplitterUpgradeable` 均为 UUPS，`_authorizeUpgrade(...)` 由 `onlyOwner` 放行。`[代码已证]`
- `MemeverseUniswapHookUpgradeable` 使用 `ERC1967Proxy + UUPS`。Hook implementation 持 UUPS `_authorizeUpgrade` / `upgradeToAndCall` 升级入口；升级授权由 Hook `owner()` 经 `_authorizeUpgrade(...) => onlyOwner` 控制。`script/DeployMemeverseHookProxy.s.sol` 创建 Hook proxy 时使用 `ERC1967Proxy(implementation, initializeData)`（2 参数，UUPS 不传 owner 给 proxy constructor，owner 经 `initialize` 植入 Hook storage）。same-nonce / existing Hook proxy 复用路径校验 `EXPECTED_HOOK_PROXY_CODEHASH`（ERC1967Proxy runtime）与 Hook `owner()`（完整复用校验路径见 [operations.md](../operations.md)）；运维侧 ownership transfer 即升级授权转移，无 ProxyAdmin 对齐需求。`poolManager` 一致性是 Hook on-chain upgrade guardrail（`_authorizeUpgrade` 内先做无代码守卫，`newImplementation.code.length == 0` 时 revert `UpgradeTargetCodeNotReady`，再做 `UpgradePoolManagerMismatch` 检查）；getter 缺失或调用 revert 时具名 revert `UpgradePoolManagerUnreadable`（try/catch 折叠，镜像 center `UpgradeEndpointUnreadable` 家族）；operator/off-chain upgrade checklist/runbook 仍建议执行 pre-check 作为双保险。`poolManager` 不在 proxy storage 中，升级替换字节码后若真实值不同，`_authorizeUpgrade` 会 revert `UpgradePoolManagerMismatch` 阻止升级；若绕过该守卫（如恶意 owner 伪造 getter），hook 回调将指向错误目标，导致所有 swap 和流动性操作永久失效。`[代码已证]`
- **Hook 与 facet 升级模型**：dynamic fee logic 位于 `DynamicFeeFacet`，rebate accrual 位于 `src/swap/SwapFacet.sol::_settleProtocolFee`（`_collectProtocolFee` 调用，经 Router DELEGATECALL 共享 hook storage）；hook owner 经 `setFacet(bytes32 role, address facet)` 替换 facet 地址，role 取 `SWAP_FACET_ROLE` / `DYNAMIC_FEE_FACET_ROLE` / `SETTLEMENT_FACET_ROLE` 三个 `bytes32` 常量。返佣 storage（`referrerRebateBps` / `pendingRebate`）位于 hook ERC7201 namespace `outrun.storage.MemeverseUniswapHook`；hook `initialize` 写入默认 `referrerRebateBps = 1000` 并触发 `ReferrerRebateBpsUpdated(0, 1000)`。`setFacet(DYNAMIC_FEE_FACET_ROLE, newAddr)` 只换 facet 地址，不修改 hook storage。DynamicFeeFacet 经 DELEGATECALL 拥有 hook 全 storage 写权，属于 facet 信任边界。`[代码已证]`
- hook storage 冻结约束：一旦部署，所有 facet 共享的 `MemeverseUniswapHookStorage` 字段顺序冻结，任何升级不能改动字段顺序，只能在尾部追加。违反此约束会破坏所有 facet 的 storage 读写，包括 rebate。`[代码已证]`
- facet 防直接调用：facet 是独立部署合约，其 logic 函数为 `external`（DELEGATECALL 要求），但第三方可直接 CALL facet 地址，此时 facet 会在自己的空 / 未初始化 storage 上下文执行。facet 用 `__self` immutable 守卫防直接 CALL：`__self` 在部署时固定为 facet 自己的地址（immutable，字节码级，不占 storage slot），每个 logic 函数开头经 `onlyViaRouter` 检查 `address(this) != __self`；经 Router DELEGATECALL 时 `address(this)` = hook proxy ≠ `__self`(facet) 通过，直接 CALL 时 `address(this)` = facet == `__self` revert（不依赖 storage 读，靠 immutable 自比较）。`[代码已证]`
- `MemeverseUniswapHookUpgradeable.initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_, launcher_)` 初始化 owner、treasury、LP token implementation、3 个 facet 地址与 launcher 绑定，并写入默认启动费率配置与默认 `referrerRebateBps = 1000`。初始化时校验 3 facet 字节码就绪且 poolManager 与 hook 一致，并校验 `launcher_ != address(0)` 否则 revert `ZeroAddress`。部署顺序：部署 3 facet（constructor 传 hook 的 poolManager）→ 部署 Router implementation + hook proxy（proxy 地址需 HookMiner 挖 flag）→ `initialize` 传 facet 地址。成功初始化触发以下 hook-product 事件：`FacetUpdated(SWAP_FACET_ROLE, address(0), swapFacet_)`、`FacetUpdated(DYNAMIC_FEE_FACET_ROLE, address(0), dynamicFeeFacet_)`、`FacetUpdated(SETTLEMENT_FACET_ROLE, address(0), settlementFacet_)`、`TreasuryUpdated(address(0), treasury_)`、`LPTokenImplementationUpdated(address(0), lpTokenImplementation_)`、`LauncherUpdated(address(0), launcher_)`、`DefaultLaunchFeeConfigUpdated(0,0,0,5000,100,900)` 与 `ReferrerRebateBpsUpdated(0, 1000)`（inherited `Ownable` 的 `OwnershipTransferred(address(0), initialOwner)` 经 `__OutrunOwnable_init`（`OutrunOwnableUpgradeable` 家族）先于上列触发，按 [events catalog](../events.md) hook-product 惯例不在此列）。`[代码已证]`
- `lpTokenImplementation` 是 first-class deployment artifact 之一（非 UUPS surface；完整清单见 implementation-map.md）；脚本必须在 `DeploymentResult.lpTokenImplementation` 中返回。same-nonce 复用时校验预测地址、地址非零与代码存在；运行期 codehash 必须等于 `EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH`（见 `script/DeployMemeverseHookProxy.s.sol::_validateExistingImplementationCodehashes`）；readiness 不包含 pool-manager getter 检查。`[代码已证]`
- `lpTokenImplementation` 暴露 owner setter `setLpTokenImplementation`（`src/swap/MemeverseUniswapHookUpgradeable.sol::setLpTokenImplementation`），可由 owner 替换克隆模板；但替换仅影响后续新建的 pool，已部署 pool 的 LP token clone 不受影响。根因：`lpTokenImplementation` 是每个 pool 在 `beforeInitialize` 经 `Clones.clone` 独立克隆的模板（`src/swap/SwapFacet.sol::beforeInitializeLogic`），EIP-1167 minimal proxy 在 clone 时即固化实现地址，clone 实例不可迁移。因此 `setLpTokenImplementation` 替换指针后，仅对此后新建的 pool 生效；已存在 pool 的 LP token clone 永久指向旧实现，无法热修，只能引导流动性迁移到新 pool。settlement logic 由 SettlementFacet 承载；`setFacet(SETTLEMENT_FACET_ROLE, ...)` 替换其地址并对所有 pool 立即生效。`[代码已证]`
- POLSplitterUpgradeable 的 `principalTokenImplementation` / `yieldTokenImplementation` 同为克隆模板指针（`initialize` 内 `new PrincipalToken()` / `new YieldToken()` 部署并写入默认模板），owner 经 `setTokenImplementations` 成对原子替换；仅影响此后 `initializeVerse` 创建的 verse，已存在 per-verse PT/YT clone 因 EIP-1167 在克隆时固化模板地址，永久指向旧模板、无迁移路径（多代并存是设计边界）。链上仅校验非零地址与有代码，模板 ABI 兼容（`SplitterToken.initialize(name, symbol, splitter)`、onlySplitter `mint` / `burn` 与完整 ERC20 表面）是 owner（多签）责任。`[代码已证]`
  - 证据：`src/polend/POLSplitterUpgradeable.sol::setTokenImplementations`、`::initializeVerse`
- `feePreviewReader` 同为 first-class deployment artifact，不是 UUPS surface；Launcher owner 可经 `setFeePreviewReader` 原子替换指针，替换后所有外部预览调用立即指向新 reader。与 `MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 形似而本质不同：reader 通过 immutable `PROXY` staticcall 读 proxy getter，不绑 ERC-7201 名域、不接收 delegatecall、永不写 proxy storage，因此升级 `MemeverseLauncherStorage` struct 时 reader 无需跟 sibling 同步重编；EOA 直调 reader 是其正常用法，不存在"零地址 void delegatecall 静默成功"风险，readiness 校验 `feePreviewReader` 有代码是唯一防线。`[代码已证]`
  - 证据：`src/verse/MemeverseFeePreviewReader.sol::PROXY`、`::constructor`；`src/verse/MemeverseLauncherUpgradeable.sol::setFeePreviewReader`；`script/MemeverseScript.s.sol::_requireContractCode`
- `POLendUpgradeable.initialize(...)` 必须拒绝 `leveragedDebtFactor_ > uint128.max * 1e18`；后续 owner setter 使用同一技术上限，升级不得放宽该边界。`[代码已证]`
- Hook proxy implementation 升级（UUPS `upgradeToAndCall`）保留返佣：rebate custody 与 `pendingRebate` / `referrerRebateBps` 都在 hook proxy 的 ERC7201 storage（`outrun.storage.MemeverseUniswapHook`），换 Router 字节码不改变 hook storage、不改变 `pendingRebate`、不改变 `referrerRebateBps`。换 Router 后若新 Router 仍指向同一组 facet 地址（或经 `setFacet` 更新到新 facet），rebate accrual / claim 路径不受影响；ABI 兼容边界仅包括 external `claimRebate` 入口，以及 Router 到 `ISwapFacet` 的相关 delegatecall interfaces。`_collectProtocolFee` 是 SwapFacet 内部函数，不是 calldata / entry ABI；升级须保留其 protocol fee / rebate 记账语义，而非其 calldata 或入口 ABI（返佣记账内联进 `_settleProtocolFee`，由 `_collectProtocolFee` 与 beforeSwap 主路径调用，无独立 `accrueRebate` 入口）。`[代码已证]`
- `MemeverseLaunchImpl` 是 Launcher facade 受信 `delegatecall` 目标，属 Launcher proxy 受信代码集；`setLaunchImpl` 为 `onlyOwner`，与 Launcher 其他 admin setter 一致。`[代码已证]`
  - sibling 与 Launcher facade 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；sibling 只写 launch dispatcher 语义字段（`registerMemeverse` / `genesis` / `preorder` / `changeStage` / 治理部署），零越界写其他 storage。LaunchImpl / SettlementImpl / LiquidityImpl 共享同一 `IMemeverseLauncherStorage::MemeverseLauncherStorage` struct，升级该 struct 时三者必须同步重编（详见下方 `MemeverseSettlementImpl` / `MemeverseLiquidityImpl` 段）。
  - facade inline `require(launchImpl != address(0), LaunchImplNotSet())` 前置守卫，防零地址 void `delegatecall` 静默成功、dispatcher 不执行却推进状态。
  - sibling 继承 `DelegatecallOnly`，EOA 直调时 `onlyDelegatecall` 守卫（immutable 变量 `_self = address(this)` 在构造期求值锚定 sibling 部署地址、其值嵌入 sibling 自身 bytecode，delegatecall 上下文切换下不被 proxy 覆盖）显式 revert `DelegatecallOnlyCall`；自身 storage 永久未初始化（无 `Initializable`、无自身 storage）亦不构成可利用路径。
  - 证据：`src/verse/MemeverseLaunchImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setLaunchImpl`；`src/verse/interfaces/IMemeverseLaunchImpl.sol::registerMemeverse`、`::genesis`、`::preorder`、`::changeStage`；`src/verse/interfaces/IMemeverseLauncher.sol::LaunchImplNotSet`
- `MemeverseSettlementImpl` 同属 Launcher proxy 受信 `delegatecall` 目标集；`setSettlementImpl` 为 `onlyOwner`，与 `setLaunchImpl` 一致。`[代码已证]`
  - sibling 与 Launcher / LaunchImpl / LiquidityImpl 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；升级 `MemeverseLauncherStorage` struct 时三者必须用相同 struct 同步重编，否则 facade 经 delegatecall 调任一 sibling 时读写错位。
  - facade inline `require(settlementImpl != address(0), SettlementImplNotSet())` 前置守卫，防零地址 void `delegatecall` 静默成功、refund / claim / fee（`collectAndDistributeFees` + `_captureLockedAuxiliaryFees`）/ unlock / post-unlock swap protection 不执行却推进状态，与 `LaunchImplNotSet` 同理。
  - sibling 继承 `DelegatecallOnly`，EOA 直调时 `onlyDelegatecall` 守卫（immutable 变量 `_self = address(this)` 在构造期求值锚定 sibling 部署地址、其值嵌入 sibling 自身 bytecode，delegatecall 上下文切换下不被 proxy 覆盖）显式 revert `DelegatecallOnlyCall`；自身 storage 永久未初始化（无 `Initializable`、无自身 storage）亦不构成可利用路径。
  - 证据：`src/verse/MemeverseSettlementImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setSettlementImpl`；`src/verse/interfaces/IMemeverseSettlementImpl.sol::collectAndDistributeFees`、`::unlockFromLocked`；`src/verse/interfaces/IMemeverseLauncher.sol::SettlementImplNotSet`
- `MemeverseLiquidityImpl` 同属 Launcher proxy 受信 `delegatecall` 目标集；`setLiquidityImpl` 为 `onlyOwner`，与 `setLaunchImpl` / `setSettlementImpl` 一致。`[代码已证]`
  - sibling 与 Launcher / LaunchImpl / SettlementImpl 共享同一 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；升级 `MemeverseLauncherStorage` struct 时三者必须用相同 struct 同步重编，否则 facade 经 delegatecall 调任一 sibling 时读写错位。
  - facade inline `require(liquidityImpl != address(0), LiquidityImplNotSet())` 前置守卫，防零地址 void `delegatecall` 静默成功、bootstrap（`deployBootstrapLiquidity`）/ `mintPOLToken` / `redeemAuxiliaryLiquidity` / `settleLeveragedAuxiliaryLiquidity` / `redeemMemecoinLiquidity` / LP helper 不执行却推进状态，与 `LaunchImplNotSet` / `SettlementImplNotSet` 同理。
  - sibling 继承 `DelegatecallOnly`，EOA 直调时 `onlyDelegatecall` 守卫（immutable 变量 `_self = address(this)` 在构造期求值锚定 sibling 部署地址、其值嵌入 sibling 自身 bytecode，delegatecall 上下文切换下不被 proxy 覆盖）显式 revert `DelegatecallOnlyCall`；自身 storage 永久未初始化（无 `Initializable`、无自身 storage）亦不构成可利用路径。
  - 证据：`src/verse/MemeverseLiquidityImpl.sol`；`src/verse/MemeverseLauncherUpgradeable.sol::setLiquidityImpl`；`src/verse/interfaces/IMemeverseLiquidityImpl.sol::deployBootstrapLiquidity`、`::mintPOLToken`、`::redeemAuxiliaryLiquidity`、`::settleLeveragedAuxiliaryLiquidity`、`::redeemMemecoinLiquidity`；`src/verse/interfaces/IMemeverseLauncher.sol::LiquidityImplNotSet`

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
