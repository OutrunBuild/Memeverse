# MemeverseV2 运维语义（Operator / Keeper Runbook）

## 1. 说明

本文是“当前实现语义”的操作手册，不定义链下组织流程。  
标签说明：

- `[代码已证]`：源码可直接验证
- `[未知]`：依赖生产部署或链外系统信息

## 2. 角色与职责边界

- `owner`：改配置、地址指针调整。`[代码已证]`
- `keeper/executor`：推进阶段、触发 fee 分发并领取执行奖励。`[代码已证]`
- 任意用户：参与 Genesis/Preorder、领取、赎回、staking。`[代码已证]`
- registrar/center：注册链路入口与跨链 fan-out。`[代码已证]`

## 3. 核心操作语义

### 3.1 注册（本地或异链发起）

1. 先 quote，再提交：
 - 本地路径：`MemeverseRegistrarAtLocal.quoteRegister(...)` -> `registerAtCenter(...)`
 - 异链路径：`MemeverseRegistrarOmnichain.quoteRegister(...)` -> `registerAtCenter(...)`
2. 中心链 `registration(...)` 成功后会：
 - 校验参数与 symbol 锁
 - 生成 `uniqueId/endTime/unlockTime`
 - 对目标链本地调用或 LZ 发送
3. 成功信号：
 - `Registration`
 - 目标链完成后 `RegisterMemeverse` + `SetExternalInfo`

补充说明：

- `SetExternalInfo` 中 `uri` 和 `description` 采用增量覆盖语义（空字符串不覆盖旧值）。`communities` 数组中，空数组不触发任何操作，但数组内的空字符串会删除对应索引的条目——调用时需确保非目标位置传入现有值而非空字符串。

失败要点：symbol 未解锁、uAsset 未支持、`msg.value` 不足、目标链 endpointId 未配置。`[代码已证]`

#### 3.1.1 新 uAsset 冷启动（onboarding）

新 uAsset 接入需要四个登记面，顺序敏感；统一入口为部署脚本 `MemeverseScript.s.sol::onboardUAsset`（代码轮实现，本 checklist 先定义顺序语义），脚本按 fail-closed 顺序写入并在每步后断言，任一漏配在部署/注册前失败，而不是用户注册时才 revert。

1. launcher 面：`MemeverseLauncherUpgradeable.sol::setFundMetaData`（onlyOwner，入参校验 `ZeroInput` / `FundBasedAmountTooHigh` / `VirtualAssetsTooLow`）。漏配 → 注册路径 `MemeverseLaunchImpl.sol::registerMemeverse` 在 `fundMetaData.minTotalFund/fundBasedAmount` 为 0 时 revert `ZeroInput`，注册事务注册前 fail-fast。`[代码已证]`
2. POLendUpgradeable 面：`POLendUpgradeable.sol::setMaxSettlementDustReserve`（onlyOwner；`maxReserve == 0` 被 setter 以 `ZeroInput` 拒绝，其"未配置"哨兵语义由 `POLendUpgradeable.sol::registerLendMarket` / `_debtCapacity` / `fundSettlementDustReserve` 复用，不存在"已配置但禁用"状态）。漏配 → `POLendUpgradeable.sol::registerLendMarket` revert `InvalidConfig`，该调用发生在 `MemeverseLaunchImpl.sol::registerMemeverse` 内 token 部署之后、同一条注册事务里，整笔事务（含已部署 token 克隆）原子回滚，可干净重试。`[代码已证]`
3. 可选 credit 面：`GenesisCreditFactory.sol::deployCredit`（onlyOwner，per-uAsset CREATE3，同 uAsset 重复部署 revert）——仅启用 credit path 时执行。漏配 → `POLendUpgradeable.sol::leveragedGenesisWithCredit` revert `NoCreditForUAsset`，普通 genesis 路径不受影响。`[代码已证]`
4. center 面（**最后**开启，完成标志）：`MemeverseRegistrationCenter.sol::setSupportedUAsset(uAsset, true)`（onlyOwner）。漏配 → 注册参数校验 `MemeverseRegistrationCenter.sol::_registrationParamValidation` 在 `supportedUAssets[uAsset]` 未配置时 revert `InvalidUAsset`，注册直接被拒；前三步 readiness 断言通过前不得开启。`[代码已证]`

补充说明：

- 四个面全是 onlyOwner setter，无任何自动接线，遗漏只能在部署/注册时暴露；注册事务是单事务原子回滚（token 克隆一并回滚），可干净重试，无残留状态。
- 脚本 readiness 断言复用 canonical 对（UETH/UUSD）已验证的 `_requireFundMetaDataReady` / `_requireReserveReady` 语义，泛化到任意 uAsset；`setMaxSettlementDustReserve` 此前无任何脚本调用，是冷启动漏配的高发面。
- credit 面（`deployCredit`）与费分发 revert 无因果：费分发要求的是治理 incentivizer 的 treasury token 登记（`GovernanceCycleIncentivizerUpgradeable.sol::recordTreasuryIncome` revert `NonTreasuryToken`），属独立第五个登记面，不在本 checklist 顺序内。
- 18-dec 约束：credit path 只支持 `uAsset.decimals() == 18`（`deployCredit` revert `InvalidUAssetDecimals`）。
- `setFundMetaData` 为全局活读配置：注册后可继续由 owner 调整，调整立即影响所有已注册未 `Locked`（Genesis 期）verse 的启动门槛、铸币比、V 缓冲与 POLendUpgradeable 杠杆上限（方向非单调：调高 `minTotalFund` 使 launch gate 变严但扩大杠杆上限）；变更前需评估 pending verse 影响。已 `Locked` verse 不受影响。

### 3.2 阶段推进（keeper 高频）

入口：`MemeverseLauncherUpgradeable.changeStage(verseId)`。  
语义：

- `Genesis -> Locked`：满足募资条件（`flashGenesis` 可提前）并执行部署/建池/preorder 结算
- `Genesis -> Refund`：到期未达标
- 当前实现中的 `Locked -> Unlocked`：需要 `block.timestamp > unlockTime`，并在该次 `changeStage()` 交易里把受保护公开 swap 的恢复时刻写成 `block.timestamp + 24 hours`

补充说明：

- 当前实现没有新增独立阶段，而是通过解锁迁移时写入 pool-level `publicSwapResumeTime`，把保护窗口叠加在 `Unlocked` 状态上
- 因此 keeper 推进到 `Unlocked` 后，仍需按窗口语义理解“赎回已开放，但受保护公开 swap 可能仍被阻断”
- 这是显式接受的产品规则；保护窗口现为固定 `24 hours` 产品常量

注意：`Locked` 且未到解锁时间时，调用不回退，但事件仍是 `ChangeStage(..., Locked)`。`[代码已证]`

### 3.3 费用分发（keeper）

入口：`quoteDistributionLzFee(verseId)`（经 `MemeverseFeePreviewReader`，地址取 `getLauncherContracts().feePreviewReader`）与 `redeemAndDistributeFees(verseId,rewardReceiver)`（仍调 Launcher）。  
语义：

- 先从 `memecoin/uAsset` 主池与三个辅助池捕获 fee；目标分流规则见 [docs/spec/polend/README.md](spec/polend/README.md)
- 主池 `memecoin/uAsset` fee：`memecoin` fee 进入 yield 路径；`uAsset` fee 拆成 `executorReward + govFee`
- 辅助池 `POL/uAsset`、`PT/uAsset`、`PT/POL` fee：POL fee burn；普通侧 `uAsset/PT` fee 进入普通 fee 领取账本；杠杆侧 `uAsset` fee 进入 governor treasury 路径；杠杆侧 `PT` fee 在 settle 前 `preRedeemPTFee` 预兑付，settle 后 `redeemPT` 后分发；settle 前捕获但未主动分发的杠杆侧 PT fee 作为 pending，后续 settled 后再 `redeemPT` 分发
- 本链治理：经 `yieldDispatcher.distributeSameChain` 分发到 governor / yieldVault（amount 为持币转账桶 + PT 赎回直达桶的合计，对账口径见 [settlement-and-fees.md §8](spec/polend/settlement-and-fees.md)）
- 异链治理：走 OFT `send`，目标链由 LayerZero endpoint 调用 `yieldDispatcher.lzCompose`，`msg.value` 必须精确等于总报价

失败要点：未到 `Locked`、`rewardReceiver=0`、跨链费用不精确、外部依赖回退。`[代码已证]`

### 3.4 Preorder 相关

- 参与：`preorder(...)`（仅 Genesis）
- 退款：`refundPreorder(...)`（仅 Refund）
- 领取：`claimUnlockedPreorderMemecoin(...)`（至少 Locked，按线性释放）

建议：先读 `previewPreorderCapacity(...)` 与 `claimablePreorderMemecoin(...)`。`[代码已证]`

### 3.5 Memecoin staking（跨链/本链）

入口：`MemeverseOmnichainInteroperation.quoteMemecoinStaking(...)` 与 `memecoinStaking(...)`。  
语义：

- 治理链在本链：`msg.value` 必须为 0，直接存入 yieldVault
- 治理链在异链：先 quote，`msg.value` 必须精确匹配，走 OFT 到 `OmnichainMemecoinStaker`

成功信号：`OmnichainMemecoinStaking`（发起侧）与 `OmnichainMemecoinStakingProcessed`（治理链接收侧）。`[代码已证]`

### 3.6 Swap/LP 运维配置

- Hook owner 可改：`treasury`、protocol fee 币种支持、launch fee 衰减参数。
- Hook owner 可通过 `setLpTokenImplementation` 替换 LP token 克隆模板，但替换仅影响后续新建的 pool。已部署 pool 的 LP token 是 EIP-1167 minimal proxy（clone），实现地址在部署时固化，无法迁移或升级。如果旧 LP 实现被发现漏洞，已部署池的 LP token 永久运行旧代码，只能引导流动性迁移到新池。这是 clone 模式的固有局限性，非 bug。`[代码已证]`
- 公开 swap 始终使用正常费率路径：`feeBps = max(current launch fee, dynamic fee, FEE_BASE_BPS)`；dynamic fee 故障通过 `setFacet(DYNAMIC_FEE_FACET_ROLE, newAddr)` 升级/修复处理，不提供 bypass mode。`[代码已证]`
- Launcher owner 配置 router / hook 时，会同时校验 `router.hook()==hook`、`hook.launcher()==launcher`、`hook.poolInitializer()==router`，配置不一致会直接拒绝；其中 `memeverseUniswapHook` 仅允许首次设置。`[代码已证]`
- `launcher` 由 hook `initialize` 一次性固化（initializer write-once），不可 retarget，与 set-time 三重校验共同保证 binding 一致。`[代码已证]`
- `createPoolAndAddLiquidity(...)` 的 `onlyLauncher` 是有意设计；建池要求 `Launcher -> Router` 调用链，并要求 Hook 的 `poolInitializer` 授权 Router。部署或配置变更后必须复核：`launcher.memeverseSwapRouter()==router`、`launcher.memeverseUniswapHook()==hook`、`router.hook()==hook`、`hook.launcher()==launcher`、`hook.poolInitializer()==router`；`Genesis -> Locked` 建池前也会做 launch-time preflight 复核，避免配置漂移到运行建池时才失败。`[代码已证]`
- Launcher pause 不会直接阻断 `changeStage(...)` 驱动的建池，因为 `changeStage(...)` 不是 `whenNotPaused`；但 Router/Hook/Initializer 配置漂移会阻断后续新池创建（`launcher` binding 由 initialize 固化，运行时不可偏离）。`[代码已证]`

### 3.7 POLendUpgradeable / POLSplitterUpgradeable 运维边界

- Launcher proxy 初始化时保存 `POLendUpgradeable` 与 `POLSplitterUpgradeable` 的 proxy 地址，当前规范不支持地址级替换，也不支持降级为零地址模式。`[代码已证]`
- 这不等于实现不可升级：`POLendUpgradeable` 与 `POLSplitterUpgradeable` 是 UUPS proxy，`_authorizeUpgrade(...)` 为 `onlyOwner`。`[代码已证]`
- POLSplitterUpgradeable owner 可经 `setTokenImplementations` 成对替换 PT/YT 克隆模板指针，但替换仅影响此后 `initializeVerse` 创建的 verse。已存在 verse 的 PT/YT 是 EIP-1167 clone，模板地址在克隆时固化，无法迁移；若旧模板被发现漏洞，存量 verse 只能依赖 UUPS 升级 splitter 逻辑层面处置，凭证层无热修通道（多代并存是设计边界）。链上校验只覆盖非零与有代码，新模板 ABI 兼容是 owner 责任；执行该操作的 owner 应为多签。`[代码已证]`
- `POLendUpgradeable.setLeveragedDebtFactor` 的技术上限为 `uint128.max * 1e18`；该值是有效上限，不代表运营最优值。普通创世与杠杆创世的累计部署资金必须保持 `totalNormalFunds + totalLeveragedDebt <= type(uint128).max`。`[代码已证]`
- 地址级替换、迁移或从零地址恢复不在当前规范内；如需支持，必须先给出显式迁移设计。`[代码已证]`
- `SettlementDustInsufficient` 出现在回退交易上时，不会留下可用事件日志，不能按失败交易已发事件监控。keeper/monitor 应在目标区块状态用 `eth_call` 或 fork simulation 预执行 `MemeverseLauncherUpgradeable.changeStage(verseId)` 的 `Locked -> Unlocked` 路径；如需单独模拟内部结算步骤，可预执行 `POLendUpgradeable.executeGlobalSettlement(verseId)`。若模拟回退 `SettlementDustInsufficient(uint256 deficit,uint256 availableReserve)`，需先用 `POLendUpgradeable.getLendMarket(verseId).uAsset` 确认目标 uAsset，再计算 `topUpAmount = deficit - availableReserve`，对该 uAsset 完成 approve/transfer 后调用 `fundSettlementDustReserve(uAsset, topUpAmount)`，随后重试 settlement / `changeStage`。补资前还要检查 `settlementDustStates(uAsset)` 的容量：若 `topUpAmount` 超过剩余 capacity，非 Launcher 调用 `fundSettlementDustReserve` 会回退 `SettlementDustReserveExceeded(amount, capacity)`；此时应走告警、升级或配置处理，不能盲目重试。当前合约没有暴露完整 side-effect-free preview 来提前得出 `recoveredUAsset`，因为 settlement 会通过移除 LP、POL redemption、PT redemption 路径回收 uAsset。`[代码已证]`

reserve 是单向池：`POLendUpgradeable.sol::fundSettlementDustReserve` 只增、`POLendUpgradeable.sol::executeGlobalSettlement` 的 bounded deficit 消耗只减，无主动取回路径；`POLendUpgradeable.sol::setMaxSettlementDustReserve` 不允许归零、下调不得低于当前 reserve。退役 uAsset 的未消耗 reserve 余额永久留在 `POLendUpgradeable`，不提供 sweep，唯一回收通道是协议升级。

### 3.8 unlock 后固定保护窗口语义

- 正常 `Locked -> Unlocked` 路径由 initialize 固化的绑定 Launcher 为既有非零 ERC-20 池写入固定 24 小时 `publicSwapResumeTime` 保护窗口；窗口内不开放普通公开 swap，运维与 keeper 优先支持退出/结算。
- `launcher` 由 hook initialize 固化不可 retarget，resume time 写入仅正常 Locked→Unlocked 路径由真实 Launcher 执行。
- launcher 由 initialize 固化，无 retarget 可能，无需恢复操作。

### 3.9 Proxy 升级操作步骤

本节覆盖所有 UUPS 可升级合约（含 diamond Router Hook）的升级操作规程。升级的本质是让 proxy 指向新的 implementation 合约，proxy 地址不变、storage 数据不变、用户无感知。部署记录还必须把不可升级但一等返回的 `lpTokenImplementation` 与 3 个 facet（`SwapFacet` / `DynamicFeeFacet` / `SettlementFacet`）作为独立 artifacts 记录。

#### 3.9.1 可升级与可替换实现合约汇总

| 合约 | proxy 来源 / proxy salt label | implementation 部署来源 | 当前可证 implementation salt label | 授权门控 | 特殊约束 |
| --- | --- | --- | --- | --- | --- |
| **UUPS 可升级** | | | | | |
| `MemeverseLauncherUpgradeable` | `MemeverseScript._deployMemeverseLauncher`; proxy salt = `MemeverseLauncher + nonce` | `MemeverseScript._deployMemeverseLauncher` 内部署 | `MemeverseLauncherImplementation + nonce` | `onlyOwner` | 存储 `polend`/`polSplitter` proxy 地址，不可运行时替换 |
| `POLendUpgradeable` | `MemeverseScript._deployPOLend`; proxy salt = `POLend + nonce` | `MemeverseScript._deployPOLend` 内部署 | `POLendImplementation + nonce` | `onlyOwner` | 存储 `launcher`/`splitter` 地址；`leveragedDebtFactor` 技术上限 `uint128.max * 1e18` |
| `POLSplitterUpgradeable` | `MemeverseScript._deployPOLSplitter`; proxy salt = `POLSplitter + nonce` | `MemeverseScript._deployPOLSplitter` 内部署 | `POLSplitterImplementation + nonce` | `onlyOwner` | 存储 `launcher`/`polend` 地址；初始化时读 `launcher.polend()` |
| `YieldDispatcherUpgradeable` | `MemeverseScript._deployYieldDispatcher`; proxy salt = `YieldDispatcher + nonce` | `MemeverseScript._deployYieldDispatcher` 内部署 | `YieldDispatcherImplementation + nonce` | `onlyOwner`（经 `YieldDispatcherUpgradeable.sol::_authorizeUpgrade`） | `constructor() { _disableInitializers(); }`；CREATE3 两步部署（impl + ERC1967Proxy + `YieldDispatcherUpgradeable.sol::initialize` calldata），proxy 地址 = f(OutrunDeployer, deployer, salt) 与 creationCode 无关，故改 UUPS 后 proxy 地址不变（仍等于原 dispatcher 地址） |
| **UUPS 可升级（diamond Router）** | | | | | |
| `MemeverseUniswapHookUpgradeable` | `DeployMemeverseHookProxy.getPredictedProxy(..., nonce, hookOwner, hookTreasury, poolManager)`；内部 `_selectProxySalt` 使用 `keccak256(abi.encodePacked("MemeverseUniswapHookProxy", nonce, i))` 选择 nonce-scoped hook-flag proxy salt | `DeployMemeverseHookProxy` 通过 `new MemeverseUniswapHookUpgradeable(poolManager)` 部署 | `MemeverseUniswapHookImplementation + nonce` | `onlyOwner`（Hook `owner()`，经 UUPS `_authorizeUpgrade`） | diamond Router：`poolManager` 不在 proxy storage 中，是字节码级绑定；callback/fee/settlement logic 外移到 SwapFacet / DynamicFeeFacet / SettlementFacet（共享 Router storage，经 Router entry `delegatecall`）；3 facet 地址存 Router storage，`setFacet(role, addr)` onlyOwner 独立升级每个 facet；3 facet 部署时必须传与 hook 同一个 `poolManager` |
| **治理代理可升级** | | | | | |
| `MemecoinDaoGovernorUpgradeable` | `MemeverseProxyDeployer.deployGovernorAndIncentivizer`; proxy salt = `keccak256(abi.encode(uniqueId))` | `MemeverseScript._deployMemecoinGovernorImplementation` | `MemecoinDaoGovernorImplementation + nonce` | `onlyGovernance` | 需走 OZ Governor 提案流程；`_authorizeUpgrade` 由 Governor 合约内部 `_governanceCall` 放行 |
| `GovernanceCycleIncentivizerUpgradeable` | `MemeverseProxyDeployer.deployGovernorAndIncentivizer`; proxy salt = `keccak256(abi.encode(uniqueId))` | `MemeverseScript._deployImplementation` | `GovernanceCycleIncentivizerImplementation + nonce` | `onlyGovernance` | 实际校验 `msg.sender == _governor`（即 Governor proxy 地址） |
| **Facade delegatecall 目标（非 proxy，可替换实现）** | | | | | |
| `MemeverseLaunchImpl` | N/A（非 proxy，Launcher `delegatecall` 目标） | `MemeverseScript` 单角色模式 `new MemeverseLaunchImpl()` | N/A | `setLaunchImpl`（`onlyOwner`） | 与 Launcher 共享 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；替换方式为部署新 sibling + owner `setLaunchImpl`（非 UUPS `upgradeToAndCall`）；sibling 读 proxy storage；继承 `DelegatecallOnly`，EOA 直调被 `onlyDelegatecall` 守卫显式 revert `DelegatecallOnlyCall` |
| `MemeverseSettlementImpl` | N/A（非 proxy，Launcher `delegatecall` 目标） | `MemeverseScript` 单角色模式 `new MemeverseSettlementImpl()` | N/A | `setSettlementImpl`（`onlyOwner`） | 与 Launcher 共享 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；替换方式为部署新 sibling + owner `setSettlementImpl`；delegatecall-only by construction（继承 `DelegatecallOnly`，EOA 直调被 `onlyDelegatecall` 守卫显式 revert `DelegatecallOnlyCall`） |
| `MemeverseLiquidityImpl` | N/A（非 proxy，Launcher `delegatecall` 目标） | `MemeverseScript` 单角色模式 `new MemeverseLiquidityImpl()` | N/A | `setLiquidityImpl`（`onlyOwner`） | 与 Launcher 共享 ERC-7201 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；替换方式为部署新 sibling + owner `setLiquidityImpl`；delegatecall-only by construction（空 constructor、无 `Initializable`、自身 storage 永久未初始化；继承 `DelegatecallOnly`，EOA 直调被 `onlyDelegatecall` 守卫显式 revert `DelegatecallOnlyCall`） |
| **Diamond facet（非 proxy，可替换实现，经 hook Router entry `delegatecall`）** | | | | | |
| `SwapFacet` | N/A（非 proxy，hook Router entry `delegatecall` 目标） | `DeployMemeverseHookProxy` 部署 `new SwapFacet(poolManager)` | N/A | `setFacet(SWAP_FACET_ROLE, addr)`（`onlyOwner`，经 hook） | 与 hook Router 共享 ERC-7201 namespace `outrun.storage.MemeverseUniswapHook` 与 `IMemeverseHookStorage` struct；替换方式为部署新 facet + owner `setFacet(SWAP_FACET_ROLE, addr)`；constructor 须传与 hook 同一个 `poolManager`（DELEGATECALL 下 facet 读自己 bytecode 的 immutable）；logic 函数开头检查 `address(this) != __self` 防直接 CALL（`__self` 为 facet 自身地址 immutable） |
| `DynamicFeeFacet` | N/A（非 proxy，hook Router / SwapFacet / SettlementFacet `delegatecall` 目标） | `DeployMemeverseHookProxy` 部署 `new DynamicFeeFacet(poolManager)` | N/A | `setFacet(DYNAMIC_FEE_FACET_ROLE, addr)`（`onlyOwner`，经 hook） | 与 hook Router 共享 ERC-7201 namespace `outrun.storage.MemeverseUniswapHook` 与 `IMemeverseHookStorage` struct；替换方式为部署新 facet + owner `setFacet(DYNAMIC_FEE_FACET_ROLE, addr)`；constructor 须传与 hook 同一个 `poolManager`（fee logic 本身不调 PoolManager，但 `initialize`/`setFacet` 经 `_requireFacetPoolManager` 校验其 immutable 一致性） |
| `SettlementFacet` | N/A（非 proxy，hook Router entry `delegatecall` 目标） | `DeployMemeverseHookProxy` 部署 `new SettlementFacet(poolManager)` | N/A | `setFacet(SETTLEMENT_FACET_ROLE, addr)`（`onlyOwner`，经 hook） | 与 hook Router 共享 ERC-7201 namespace `outrun.storage.MemeverseUniswapHook` 与 `IMemeverseHookStorage` struct；替换方式为部署新 facet + owner `setFacet(SETTLEMENT_FACET_ROLE, addr)`；constructor 须传与 hook 同一个 `poolManager`；Router 与 facet 必须使用同一 `ISettlementFacet` typed callback ABI，升级任一侧都要验证 `SettlementCallbackData` / `SettlementResult` 编解码一致；hook self-call 被 v4 同时跳过 `beforeSwap` / `afterSwap`，非 hook 发起的重入 swap 走普通公开费率路径（INV-04A）。`[代码已证]` |
| **Staticcall view sibling（非 proxy，可替换实现）** | | | | | |
| `MemeverseFeePreviewReader` | N/A（非 proxy，独立 view 合约；通过 immutable `PROXY` staticcall 读 Launcher 状态） | `MemeverseScript` 单角色模式 `new MemeverseFeePreviewReader(launcherProxy)` | N/A | `setFeePreviewReader`（`onlyOwner`） | 不绑名域、不被 delegatecall、不可写 proxy storage；替换方式为部署新 reader + owner `setFeePreviewReader`；构造时 immutable 绑定 Launcher proxy，部署后无法 retarget 到其他 proxy；§3.9.7 readiness 要求未接线时阻断 registration 打开 |

#### 3.9.2 升级前：Storage 兼容性验证

下表所列合约均使用 ERC7201 名域存储（namespaced storage）。每个合约的自定义数据存在一个由 namespace 字符串计算出的固定槽位起始位置。下表列出各合约的 annotation（`@custom:storage-location`，含 `erc7201:` scheme 前缀）和实际参与 slot hash 的 namespace ID：

| 合约 | annotation（代码注解） | namespace ID（hash 输入） |
|---|---|---|
| `MemeverseLauncherUpgradeable` | `erc7201:outrun.storage.MemeverseLauncher` | `outrun.storage.MemeverseLauncher` |
| `POLendUpgradeable` | `erc7201:outrun.storage.POLend` | `outrun.storage.POLend` |
| `POLSplitterUpgradeable` | `erc7201:outrun.storage.POLSplitter` | `outrun.storage.POLSplitter` |
| `MemeverseUniswapHookUpgradeable` | `erc7201:outrun.storage.MemeverseUniswapHook` | `outrun.storage.MemeverseUniswapHook` |
| `SwapFacet` | `erc7201:outrun.storage.MemeverseUniswapHook` | `outrun.storage.MemeverseUniswapHook`（与 `MemeverseUniswapHookUpgradeable` 相同） |
| `DynamicFeeFacet` | `erc7201:outrun.storage.MemeverseUniswapHook` | `outrun.storage.MemeverseUniswapHook`（与 `MemeverseUniswapHookUpgradeable` 相同） |
| `SettlementFacet` | `erc7201:outrun.storage.MemeverseUniswapHook` | `outrun.storage.MemeverseUniswapHook`（与 `MemeverseUniswapHookUpgradeable` 相同） |
| `MemecoinDaoGovernorUpgradeable` | `erc7201:outrun.storage.MemecoinDaoGovernor` | `outrun.storage.MemecoinDaoGovernor` |
| `GovernanceCycleIncentivizerUpgradeable` | `erc7201:outrun.storage.GovernanceCycleIncentivizer` | `outrun.storage.GovernanceCycleIncentivizer` |
| `YieldDispatcherUpgradeable` | `erc7201:outrun.storage.YieldDispatcher` | `outrun.storage.YieldDispatcher` |
| `MemeverseLaunchImpl` | `erc7201:outrun.storage.MemeverseLauncher` | `outrun.storage.MemeverseLauncher`（与 `MemeverseLauncherUpgradeable` 相同） |
| `MemeverseSettlementImpl` | `erc7201:outrun.storage.MemeverseLauncher` | `outrun.storage.MemeverseLauncher`（与 `MemeverseLauncherUpgradeable` 相同） |
| `MemeverseLiquidityImpl` | `erc7201:outrun.storage.MemeverseLauncher` | `outrun.storage.MemeverseLauncher`（与 `MemeverseLauncherUpgradeable` 相同） |

`MemeverseLaunchImpl`、`MemeverseSettlementImpl` 与 `MemeverseLiquidityImpl` **均为** `MemeverseLauncherUpgradeable` facade 的 delegatecall sibling，共享同一 namespace `outrun.storage.MemeverseLauncher` 与 `IMemeverseLauncherStorage` struct；升级 facade 或任一 sibling 的 storage layout 时，**所有**共享该 namespace 的合约必须用相同 struct 同步重编，否则 facade 经 delegatecall 调 sibling 时读写错位。三行 namespace 均经 `layout at erc7201("outrun.storage.MemeverseLauncher")` 绑定，`@custom:storage-location` 注解实际挂在 `src/verse/interfaces/IMemeverseLauncherStorage.sol::MemeverseLauncherStorage`。

`SwapFacet`、`DynamicFeeFacet` 与 `SettlementFacet` **均为** `MemeverseUniswapHookUpgradeable` diamond Router 的 delegatecall facet，共享同一 namespace `outrun.storage.MemeverseUniswapHook` 与 `IMemeverseHookStorage` struct；升级 Router 或任一 facet 的 storage layout 时，**所有**共享该 namespace 的合约必须用相同 struct 同步重编，否则 Router 经 delegatecall 调 facet 时读写错位。三行 namespace 均经 `layout at erc7201("outrun.storage.MemeverseUniswapHook")` 绑定，`@custom:storage-location` 注解实际挂在 `src/swap/interfaces/IMemeverseHookStorage.sol::IMemeverseHookStorage`。

ERC7201 槽位计算公式：`keccak256(abi.encode(uint256(keccak256(“outrun.storage.XXX”)) - 1)) & ~bytes32(uint256(0xff))`。注意：`erc7201:` 仅是 annotation scheme 前缀，用于标识 struct 使用 ERC7201 存储，**不参与** slot hash 计算。可以用 `cast storage <proxy> <slot>` 直接读链上数据验证。

**验证步骤：**

1. 导出旧 implementation 的 storage layout：
```bash
forge inspect <ContractName> storage-layout --pretty > old-layout.txt
```
2. 导出新 implementation 的 storage layout：
```bash
forge inspect <ContractName> storage-layout --pretty > new-layout.txt
```
3. 对比差异：
```bash
diff old-layout.txt new-layout.txt
```
4. 确认规则：
   - namespace 字符串不变（变了意味着整个 storage 重新映射，所有数据丢失）
   - struct 字段只能在末尾追加（additive），不能删除、不能重排、不能改类型
   - 继承链中的公共 storage（`OutrunOwnableInit`、`OutrunERC20Init` 等）布局不变
   - 如果 diff 显示字段顺序变化或类型变化，**停止升级**，修复 implementation 后重新编译部署

`[代码已证]`

#### 3.9.3 部署新 Implementation

UUPS 模式下，implementation 是一个独立的合约实例，proxy 通过 `delegatecall` 调用它的代码。升级就是让 proxy 的 implementation 指针从旧地址换成新地址。

**操作步骤：**

1. 编译新 implementation：
```bash
forge build
```
2. 部署到目标链。不要默认所有 UUPS 合约都有 implementation salt label；按 3.9.1 的 `implementation 部署来源` 执行：
   - `MemeverseLauncherUpgradeable`：使用 `MemeverseLauncherImplementation + nonce` 部署新的 implementation；不要重跑会重新部署同一 proxy salt 的完整 proxy 部署步骤。
   - `MemecoinDaoGovernorUpgradeable`：使用 `MemeverseScript._deployMemecoinGovernorImplementation` 的 deployment source，salt label 为 `MemecoinDaoGovernorImplementation + nonce`。
   - `GovernanceCycleIncentivizerUpgradeable`：使用 `MemeverseScript._deployImplementation` 中的 incentivizer implementation 部署逻辑，salt label 为 `GovernanceCycleIncentivizerImplementation + nonce`。
   - `MemeverseUniswapHookUpgradeable`：只复用 `DeployMemeverseHookProxy` 的 implementation 部署逻辑，不重跑 proxy 部署分支；必须传入与当前 proxy 一致的 `POOL_MANAGER`。升级 Router implementation 不替换 facet 地址（facet 独立存于 Router storage，经 `setFacet` 升级）；若需单独升级某个 facet，部署新 facet（SwapFacet / DynamicFeeFacet / SettlementFacet 均须传同一 `POOL_MANAGER`）后调 `hook.setFacet(role, newAddr)`；链上 setFacet 经 _requireFacetPoolManager 对三者统一强制校验，不匹配 revert FacetPoolManagerMismatch。
   - `POLendUpgradeable`：使用 `MemeverseScript._deployPOLend` 中的 implementation 部署逻辑，salt label 为 `POLendImplementation + nonce`。
   - `POLSplitterUpgradeable`：使用 `MemeverseScript._deployPOLSplitter` 中的 implementation 部署逻辑，salt label 为 `POLSplitterImplementation + nonce`。
3. 记录新 implementation 地址。后续 UUPS `upgradeToAndCall` 会把 proxy 指向这个地址。

**新 implementation 记录模板：**

```text
contract:
proxy:
oldImplementation:
newImplementation:
deploymentSource:
saltLabel:
nonce:
constructorArgs:
codeHash:
deploymentTx:
```

- `contract`：被升级的合约名。
- `proxy`：用户和其它合约继续访问的 proxy 地址。
- `oldImplementation`：升级前 proxy 指向的 implementation 地址。
- `newImplementation`：本次准备切换到的新 implementation 地址，即 `$NEW_IMPL`。
- `deploymentSource`：部署 `$NEW_IMPL` 的脚本或外部流程。
- `saltLabel`：如适用，记录 human-readable salt label；不适用写 `N/A`。
- `nonce`：如 salt 使用 nonce，记录 nonce；不适用写 `N/A`。
- `constructorArgs`：implementation constructor 参数；例如 Hook 必须记录 `POOL_MANAGER`。
- `codeHash`：用 `cast codehash $NEW_IMPL --rpc-url $RPC` 记录链上代码哈希。
- `deploymentTx`：部署 `$NEW_IMPL` 的交易哈希。

`[代码已证]`

#### 3.9.4 执行升级

UUPS 合约通过 `upgradeToAndCall(address newImplementation, bytes memory data)` 升级。它做两件事：
- 把 proxy 的 implementation 指针改成 `newImplementation`
- 可选：在新 implementation 上执行一段初始化调用，编码在 `data` 参数里

**当前项目中，可升级合约没有 `reinitialize` 函数，也没有 `__gap` 存储预留模式（ERC7201 不需要）。** 因此大多数升级场景下 `data` 传空 bytes 即可。

**UUPS 调用方式：**

```bash
# data 为空（最常见的升级场景，不需要额外初始化）
cast send $PROXY "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL 0x \
  --private-key $OWNER_KEY --rpc-url $RPC

# 如果未来新 implementation 增加了 reinitialize，用 abi 编码 data：
# cast calldata "reinitialize(uint8)" 2
# 然后把输出的 hex 作为 data 参数传入
```

**按授权门控分类：**

- `onlyOwner` UUPS 合约（Launcher, POLendUpgradeable, POLSplitterUpgradeable）：owner 地址（通常是多签）直接发起交易。
- `onlyGovernance` 合约（Governor, Incentivizer）：当前 Governor 没有 Timelock extension，OZ base `queue` 没有实现；升级必须通过 `propose` -> vote -> `execute`，把 `upgradeToAndCall` 的 calldata 包装成治理提案执行。如果未来增加 Timelock extension，`queue` 才放在成功投票和 `execute` 之间。owner 或多签直接调用不能通过 `onlyGovernance` UUPS 升级授权。
- `MemeverseUniswapHookUpgradeable`（UUPS）：由 Hook `owner()` 直接对 `$HOOK_PROXY` 调用 `upgradeToAndCall(address newImplementation, bytes data)`，授权经 implementation 的 `_authorizeUpgrade => onlyOwner`。

```bash
# Hook owner 直接对 hook proxy 调 upgradeToAndCall（UUPS，无 ProxyAdmin；data 为空 = 无 migration calldata）
# 注意：$NEW_IMPL 需在步骤 2 重设为 Hook 的新实现地址（非上方通用 UUPS 块的 Launcher/POLendUpgradeable/POLSplitterUpgradeable 实现）
cast send $HOOK_PROXY "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL 0x \
  --private-key $HOOK_OWNER_KEY --rpc-url $RPC
```

`[代码已证]`

#### 3.9.5 MemeverseUniswapHookUpgradeable（UUPS）升级检查

Hook implementation 提供 UUPS 升级入口（`_authorizeUpgrade` `onlyOwner`）。`_authorizeUpgrade` 先对新 implementation 做无代码守卫：若 `newImplementation.code.length == 0`，revert `UpgradeTargetCodeNotReady(newImplementation)`（快速失败，给命名错误而非 ABI-decode 晦涩 revert）。随后内置 on-chain `poolManager` drift 检查：通过 `ImmutableState(newImplementation).poolManager()` 读取新 implementation 的 immutable PoolManager，与当前 `poolManager` 比较，不匹配 revert `UpgradePoolManagerMismatch`。这是运维护栏而非安全边界（恶意 owner 可伪造 getter 绕过）。off-chain pre-check 仍建议执行作为双保险。

account-session feature 的 Hook implementation 与 SwapFacet 是同一兼容 release unit 的已落地配对。已上线环境不得将两个 artifact 的两笔顺序升级交易宣称为安全。此类上线变更必须另有明确批准的原子性、回滚与兼容性 runbook；该 feature 不需要 persistent state migration，也不新增 Event。

**Pre-check：**

```bash
cast call $HOOK_PROXY "poolManager()(address)" --rpc-url $RPC
# 记录当前 Hook proxy PoolManager

cast call $NEW_IMPL "poolManager()(address)" --rpc-url $RPC
# 必须等于当前 Hook proxy poolManager()
```

`poolManager` 地址不在 proxy storage 中，它是字节码级绑定（在 implementation constructor 中设置的 immutable 或 constructor 参数）。`_authorizeUpgrade` 先对新 implementation 做无代码守卫（`newImplementation.code.length == 0` 时 revert `UpgradeTargetCodeNotReady`），再在链上断言新 implementation 的 `poolManager()` 与当前一致（不匹配 revert `UpgradePoolManagerMismatch`），防止误升级到绑了错误 PoolManager 的 implementation。若绕过该守卫（如恶意 owner 伪造 getter），hook 回调将指向错误目标，所有 swap 和流动性操作会永久失效。off-chain pre-check 仍建议执行作为双保险。

**Post-check：**

```bash
cast call $HOOK_PROXY "poolManager()(address)" --rpc-url $RPC
# 应仍等于预期 PoolManager

# 3 facet 地址存 Router storage, 经 setFacet 升级后核验指针已更新
cast call $HOOK_PROXY "swapFacet()(address)" --rpc-url $RPC
# 应等于记录的 SwapFacet 地址（非零、有代码）

cast call $HOOK_PROXY "dynamicFeeFacet()(address)" --rpc-url $RPC
# 应等于记录的 DynamicFeeFacet 地址（非零、有代码）

cast call $HOOK_PROXY "settlementFacet()(address)" --rpc-url $RPC
# 应等于记录的 SettlementFacet 地址（非零、有代码）

# facet 部署时 poolManager 一致性（initialize/setFacet 经 _requireFacetPoolManager 对 3 facet 强制）
cast call $SWAP_FACET "poolManager()(address)" --rpc-url $RPC
# 应等于 Hook proxy poolManager()
cast call $SETTLEMENT_FACET "poolManager()(address)" --rpc-url $RPC
# 应等于 Hook proxy poolManager()
cast call $DYNAMIC_FEE_FACET "poolManager()(address)" --rpc-url $RPC
# 应等于 Hook proxy poolManager()

cast call $HOOK_PROXY "lpTokenImplementation()(address)" --rpc-url $RPC
# 应等于记录的 LP token implementation
```

Hook 对 ABI 中不存在的 selector 统一回退 `UnsupportedSelector(selector)`；接线校验使用上文 `swapFacet()` / `dynamicFeeFacet()` / `settlementFacet()`。

完成后执行 swap / liquidity smoke tests，覆盖至少一次 swap 路径和一次 add/remove liquidity 路径。

Hook ownership transfer 即升级授权转移（UUPS 下只有一个 owner，无 ProxyAdmin 对齐需求）。

#### 3.9.6 POLSplitterUpgradeable 升级顺序约束

POLSplitterUpgradeable 的 storage 中保存了 `launcher` 和 `polend` 的 proxy 地址（在 `initialize` 时从 `launcher.polend()` 读取写入）。这些地址是 POLSplitterUpgradeable 运行时的核心依赖——`split`、`settle`、`redeemPT` 等函数都通过这些地址回调 Launcher 和 POLendUpgradeable。

**升级 POLSplitterUpgradeable 时的约束：**

1. 升级本身**不会**改变 storage 中的 `launcher`/`polend` 地址。`upgradeToAndCall` 只替换 implementation 指针，不碰 proxy storage
2. 确保 `launcher` 和 `polend` proxy 在升级前后都在线且地址未变
3. 如果新 POLSplitterUpgradeable implementation 的 `initialize` 逻辑有变化，不要误触发 re-initialization——`Initializable` modifier 会阻止，但要确认新 implementation 没有绕过 `initializer` 的路径
4. 升级完成后，验证 `launcher.polend()` 和 `launcher.polSplitter()` 返回值仍然正确（见 3.9.7）

**storage 地址不变：** 升级本身不会改变 proxy storage 中的 `launcher`/`polend`/`polSplitter` 地址。`upgradeToAndCall` 只替换 implementation 指针，三个合约的地址引用在升级前后保持一致。`[代码已证]`

**升级顺序建议：** 如果同时升级 Launcher + POLendUpgradeable + POLSplitterUpgradeable，建议先升级 POLendUpgradeable 和 POLSplitterUpgradeable，最后升级 Launcher。这样在升级窗口期内，Launcher 始终指向已更新的依赖。这是防御性运维建议，不是代码强制约束——因为 storage 地址不变，任何顺序都不会破坏运行时回调链。

#### 3.9.7 升级后 Readiness Checks

升级完成后必须验证 proxy 的功能正常。以下是按合约分类的检查清单：

**通用检查（所有 UUPS 合约）：**

```bash
# 确认 proxy 的 implementation 指针已更新
# ERC1967 implementation slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage $PROXY \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $RPC
# 返回值应等于 $NEW_IMPL 地址

# 确认 new implementation 的 UUPS UUID
cast call $NEW_IMPL "proxiableUUID()(bytes32)" --rpc-url $RPC
# 返回值应等于 ERC1967 implementation slot:
# 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

```

**UUPS guard sanity check（可选，负向验证，不计入 readiness 通过条件）：**

通过 `$PROXY` 调用 `proxiableUUID()` 应因 `notDelegated` guard 以 `UUPSUnauthorizedCallContext()` revert。这是可选诊断的预期成功信号，不是 readiness failure。

自动化脚本必须断言回退错误精确为 `UUPSUnauthorizedCallContext()`；任何其他失败均为运维故障，不能视为通过。

```bash
expected_revert_selector=$(cast sig "UUPSUnauthorizedCallContext()")
if result=$(cast call "$PROXY" "proxiableUUID()(bytes32)" --rpc-url "$RPC" 2>&1); then
  echo "Unexpected success: proxy proxiableUUID() must revert" >&2
  exit 1
fi
if ! printf '%s\n' "$result" | grep -Fq "$expected_revert_selector"; then
  echo "Unexpected revert: expected UUPSUnauthorizedCallContext()" >&2
  printf '%s\n' "$result" >&2
  exit 1
fi
```

**MemeverseLauncherUpgradeable：**

```bash
cast call $LAUNCHER_PROXY "owner()(address)" --rpc-url $RPC
# 应等于预期 owner 地址

# polend 是唯一保留的 direct getter（不在 LauncherContracts 内）
cast call $LAUNCHER_PROXY "polend()(address)" --rpc-url $RPC
# 应等于 POLendUpgradeable proxy 地址

# 其余接线地址经一次 getLauncherContracts() typed decode 读出（12 个 address，按 struct 声明顺序）
# 字段顺序：localLzEndpoint, lzEndpointRegistry, yieldDispatcher, memeverseRegistrar,
#          memeverseProxyDeployer, memeverseSwapRouter, polSplitter, launchImpl,
#          memeverseUniswapHook, settlementImpl, feePreviewReader, liquidityImpl
cast call $LAUNCHER_PROXY \
  "getLauncherContracts()(address,address,address,address,address,address,address,address,address,address,address,address)" \
  --rpc-url $RPC
# 逐字段校验（返回值按上面顺序的第 N 个）：
#   [4] memeverseRegistrar   == 预期 Registrar 地址
#   [7] polSplitter           == POLSplitterUpgradeable proxy 地址
#   [8] launchImpl            == 当前接线的 MemeverseLaunchImpl，非零且有代码
#   [9] memeverseUniswapHook  == Hook proxy 地址
#  [10] settlementImpl        == MemeverseSettlementImpl，非零且有代码
#  [11] feePreviewReader      == MemeverseFeePreviewReader，非零且有代码
#  [12] liquidityImpl         == MemeverseLiquidityImpl，非零且有代码
# impl 类字段可用 cast codehash $IMPL --rpc-url $RPC 二次确认非空
```

fee sibling 进 readiness check：`settlementImpl`、`liquidityImpl` 与 `feePreviewReader` 由脚本 `_requireDeploymentReady` 经一次 `getLauncherContracts()` typed decode 后取值（同一次 decode 也读出 `launchImpl`），再 `_requireContractCode` 校验非零且有代码，与 `launchImpl` 对称（均为用户路径上使用的 delegatecall/view sibling：`changeStage` Locked→Unlocked 会 delegatecall `settlementImpl`，Genesis→Locked 成功路径会 delegatecall `liquidityImpl`，`feePreviewReader` 供链下预览）；未接线时 readiness 失败（`SETTLEMENT_IMPL_NOT_READY` / `LIQUIDITY_IMPL_NOT_READY` / `FEE_PREVIEW_READER_NOT_READY`）、阻断 registration 打开，运行时 `SettlementImplNotSet` / `LiquidityImplNotSet` 守卫仅作兜底。`[代码已证]`

> readiness 不再使用不存在的 launcher direct config getter（`memeverseRegistrar()` / `memeverseProxyDeployer()` / `yieldDispatcher()` / `polSplitter()`）：这些不是 launcher 真实 ABI。脚本通过一次 typed decode `getLauncherContracts()` 读出全部依赖字段；`polend()` 保留 direct getter（真实 ABI，不在 `LauncherContracts`）。

`creditFactory` 进 readiness check：POLendUpgradeable 的 `creditFactory` 指针由脚本 `_readAddress(POLEND, "creditFactory()")` 取值后 `_requireContractCode` 校验有代码，与 bootstrap/fee sibling 同类（用户路径接线指针——`leveragedGenesisWithCredit` 经 `IGenesisCreditFactory(creditFactory).creditOf(uAsset)` 解析 GenesisCredit）；未接线或被占位 owner 兜底（`_buildPOLendCreationCode` 在未设 `CREDIT_FACTORY_PROXY` 时写入的 EOA，无代码）时 readiness 失败、阻断 registration 打开。`cast call $POLEND_PROXY "creditFactory()(address)" --rpc-url $RPC` 应返回非零且有代码的 factory 地址。`[代码已证]`

`staker` 进 readiness check：`OMNICHAIN_MEMECOIN_STAKER` 由脚本 `_requireContractCode` 校验有代码（错误串 `STAKER_CODE_NOT_READY`）——dispatcher 已有三重检查（code/双向接线）而 staker 此前零检查，env 配错（EOA/错合约）时 readiness 全绿、`memecoinStaking` 远端路径静默指向坏 composer 的缺口关闭。`cast call $OMNICHAIN_MEMECOIN_STAKER --rpc-url $RPC` 应返回有代码地址。`[代码已证]`

`staker` endpoint 读回进 readiness check：脚本 `_readAddress(OMNICHAIN_MEMECOIN_STAKER, "localEndpoint()")` 读回值须 `== endpoints[uint32(block.chainid)]`（错误串 `STAKER_ENDPOINT_NOT_READY`）——与 dispatcher 读回对称（`YIELD_DISPATCHER_ENDPOINT_NOT_READY`），关闭 staker 侧 endpoints 配成非零但错误值时 `lzCompose` 恒 `PermissionDenied` 的静默缺口。`[代码已证]`

dispatcher endpoint 读回进 readiness check：脚本 `_readAddress(MEMEVERSE_YIELD_DISPATCHER, "localEndpoint()")` 读回值须 `== endpoints[uint32(block.chainid)]`（错误串 `YIELD_DISPATCHER_ENDPOINT_NOT_READY`）——endpoints 配成非零但错误值时 `lzCompose` 恒 `PermissionDenied` 的静默缺口关闭（对比 launcher 已有 `LAUNCHER_ENDPOINT_MISMATCH` 部署期读回）。`[代码已证]`

`endpoint` 能力校验进 readiness check：脚本 `_requireDeploymentReady` 对 `endpoints[uint32(block.chainid)]` 追加两层校验——`_requireContractCode(..., "ENDPOINT_CODE_NOT_READY")` 校验有代码，加 `composeQueue(address,address,bytes32,uint16)` selector staticcall 探针（占位参数，错误串 `ENDPOINT_COMPOSE_QUEUE_NOT_READY`）。身份读回（staker/dispatcher `localEndpoint()` == `endpoints[chainid]`）两侧同源——部署函数用同一 `endpoints[chainid]` 填构造器——env 配错时同步通过、无法拦截；能力探针把 `endpoint` env 配成非 LZ 合约（EOA/缺 composer 面的合约）在系统打开前转为具名失败。全跨链栈（OFT `sendCompose`/`lzCompose`、两 composer `verifySettle` 的 `composeQueue` 读）共享该假设。`[代码已证]`

独立入口 `openSupportedUAssetsAfterReadiness` 与 `run()` 流程一致：内部先 `_loadReadinessEnv()` 装载 `OMNICHAIN_MEMECOIN_STAKER`，再 `_chainsInit()` 装载全部 9 链 ENDPOINT/EID env；任一 env 缺失时该入口响亮 revert，而非静默跳过检查（此前只 `_loadReadinessEnv` 不填 endpoints 映射、恒误拒绝）。`[代码已证]`

registration center `DAY` 读回进 readiness check：`MemeverseScript.s.sol::_requireRegistrationCenterReady`（由 `::_openSupportedUAssetsAfterReadiness` 与 `::onboardUAsset` 两条 registration 打开路径调用）断言 `IMemeverseRegistrationCenter(registrationCenter).DAY() == expectedRegistrationDay`，前置 `_requireContractCode(registrationCenter, "REGISTRATION_CENTER_CODE_NOT_READY")`（脚本存储变量，`_loadReadinessEnv` 从 `EXPECTED_DAY` env 装载：testnet 部署在 `.env` 设 `EXPECTED_DAY=180` 保留快窗，未设默认生产值 `24 * 3600`；错误串 `REGISTRATION_DAY_NOT_READY`）——`DAY` 为源码级 `constant` 且 center 以构造部署（非 proxy），错误值永久烧入字节码、无 setter 可救；该断言把「测试值漏改生产值」从人工记忆转为部署闸门，fail-closed 朝向生产值（mainnet 漏改 180 会被阻断），任一路径失配即阻断 registration 打开。`[代码已证]`

**MemeverseUniswapHookUpgradeable：**

```bash
cast call $HOOK_PROXY "poolManager()(address)" --rpc-url $RPC
# 应等于 Uniswap V4 PoolManager 地址

cast call $HOOK_PROXY "launcher()(address)" --rpc-url $RPC
# 应等于 Launcher proxy 地址

cast call $HOOK_PROXY "owner()(address)" --rpc-url $RPC
# 应等于 Hook owner 地址（UUPS 升级授权人）

# 3 facet 接线 readiness: 地址非零、有代码（部署时须传与 hook 同一 poolManager）
cast call $HOOK_PROXY "swapFacet()(address)" --rpc-url $RPC
cast call $HOOK_PROXY "dynamicFeeFacet()(address)" --rpc-url $RPC
cast call $HOOK_PROXY "settlementFacet()(address)" --rpc-url $RPC
# 三者均应非零、有代码；未接线阻断建池/swap/settlement 路径
```

**POLendUpgradeable：**

```bash
cast call $POLEND_PROXY "owner()(address)" --rpc-url $RPC
cast call $POLEND_PROXY "launcher()(address)" --rpc-url $RPC
# 应等于 Launcher proxy 地址

cast call $POLEND_PROXY "splitter()(address)" --rpc-url $RPC
# 应等于 POLSplitterUpgradeable proxy 地址
```

**POLSplitterUpgradeable：**

```bash
cast call $SPLITTER_PROXY "owner()(address)" --rpc-url $RPC
cast call $SPLITTER_PROXY "launcher()(address)" --rpc-url $RPC
# 应等于 Launcher proxy 地址
```

**Governor / Incentivizer：**

```bash
# Governor: 这些检查证明当前 proxy 仍连接到预期的治理模型。
cast call $GOVERNOR_PROXY "name()(string)" --rpc-url $RPC
# 返回预期 DAO 名称，证明读到的是目标 Governor proxy。

cast call $GOVERNOR_PROXY "token()(address)" --rpc-url $RPC
# 返回预期投票 token 地址，证明投票权来源未漂移。

cast call $GOVERNOR_PROXY "votingDelay()(uint256)" --rpc-url $RPC
# 返回预期投票延迟，证明提案创建后到投票开始的等待期正确。

cast call $GOVERNOR_PROXY "votingPeriod()(uint256)" --rpc-url $RPC
# 返回预期投票周期，证明投票窗口长度正确。

cast call $GOVERNOR_PROXY "proposalThreshold()(uint256)" --rpc-url $RPC
# 返回预期提案门槛，证明发起提案所需投票权正确。

# 提案创建前：Governor 的 propose 使用 clock() - 1 做 proposer 门槛检查。
GOVERNOR_CLOCK="$(cast call $GOVERNOR_PROXY "clock()(uint48)" --rpc-url $RPC --json | jq -r '.[0]')"
PROPOSER_TIMEPOINT=$((GOVERNOR_CLOCK - 1))
cast call $YIELD_VAULT "getPastVotes(address,uint256)(uint256)" $PROPOSER $PROPOSER_TIMEPOINT --rpc-url $RPC
# 返回值必须不小于 proposalThreshold；这里使用 proposer timepoint，而非 proposal voting snapshot。

# 提案已创建后，先把 proposal id 放入 PROPOSAL_ID，再读取它的投票 snapshot。
: "${PROPOSAL_ID:?set PROPOSAL_ID to an existing proposal id}"
PROPOSAL_SNAPSHOT="$(cast call $GOVERNOR_PROXY "proposalSnapshot(uint256)(uint256)" $PROPOSAL_ID --rpc-url $RPC --json | jq -r '.[0]')"
CURRENT_CLOCK="$(cast call $GOVERNOR_PROXY "clock()(uint48)" --rpc-url $RPC --json | jq -r '.[0]')"
if (( PROPOSAL_SNAPSHOT >= CURRENT_CLOCK )); then
  printf 'proposal snapshot is not past: %s >= %s\n' "$PROPOSAL_SNAPSHOT" "$CURRENT_CLOCK" >&2
  exit 1
fi

# 仅在 proposal snapshot 已成为 past timepoint 后查询 quorum 与历史总票基数。
cast call $YIELD_VAULT "getPastTotalSupply(uint256)(uint256)" $PROPOSAL_SNAPSHOT --rpc-url $RPC
# 返回值必须达到 Governor 的 quorum 下限；低于该值时动态 quorum 也会被固定 minQuorum 覆盖。

cast call $GOVERNOR_PROXY "quorum(uint256)(uint256)" $PROPOSAL_SNAPSHOT --rpc-url $RPC
# 确认实际 quorum（动态资产票权与固定全量供给下限的较大值）。

# 部署后不按 vault 当前余额比例换算治理门槛。当前策略是完整 memecoin 供给提供安全分母、
# vault 质押资产提供投票权；vault 票权达到门槛前，治理处于未准备状态。

cast call $GOVERNOR_PROXY "governanceCycleIncentivizer()(address)" --rpc-url $RPC
# 返回 Incentivizer proxy 地址，证明 Governor 指向正确的激励合约。

cast call $GOVERNOR_PROXY "upgradeSupermajorityRatio()(uint256)" --rpc-url $RPC
# 返回预期升级超级多数比例，证明 Governor 自升级提案的更高通过门槛未漂移。

cast call $GOVERNOR_PROXY "state(uint256)(uint8)" $PROPOSAL_ID --rpc-url $RPC
# Governor 升级提案执行完成后应返回 Executed，即 OpenZeppelin Governor enum 值 7。

# Incentivizer
cast call $INCENTIVIZER_PROXY "governor()(address)" --rpc-url $RPC
# 应等于 Governor proxy 地址
```

**功能性冒烟测试（可选但建议）：**

- 对 FeePreviewReader 调用 `quoteDistributionLzFee(verseId)`（地址取 `getLauncherContracts().feePreviewReader`）确认 fee 计算逻辑正常
- 对 Hook 调用 `getHookPermissions()` 确认 hook 权限配置正确
- 对 Governor 调用 `state(proposalId)` 确认治理状态机正常

`[代码已证]`

### 3.10 Hook + Facet 部署流程

部署脚本 `script/DeployMemeverseHookProxy.s.sol` 通过 OutrunDeployer（CREATE3）按序部署核心 proxy 与 helper artifacts：

1. LP token implementation（`UniswapLP`，无依赖 helper artifact）
2. SwapFacet（`new SwapFacet(poolManager)`，须传与 hook 同一个 `POOL_MANAGER`）
3. DynamicFeeFacet（`new DynamicFeeFacet(poolManager)`，须传与 hook 同一个 `POOL_MANAGER`）
4. SettlementFacet（`new SettlementFacet(poolManager)`，须传与 hook 同一个 `POOL_MANAGER`）
5. Hook 实现（`MemeverseUniswapHookUpgradeable`，diamond Router）
6. Hook proxy（`ERC1967Proxy` + UUPS，initialize 绑定 owner/treasury/3 facet 地址/lpTokenImplementation）

固定 salt 的 helper artifacts（`hookImplementation`、`lpTokenImplementation`、3 facet）由 `(deployer, DEPLOYMENT_NONCE)` 唯一确定。`hookProxy` 在同一 nonce 下经 hook-flag mining 选型：干净链上通常等于首个 flag candidate；若更早的 flag 候选被无关代码占用（implementation 不匹配），`_selectProxySalt` 会跳过并选用后续候选。同一 nonce 重跑：完整同配置 hook 部署幂等复用；fresh 路径上固定 salt 中间 artifact 已占用则 revert（`ExistingIntermediateDeploymentNotReusable` / `ArtifactCreate3SaltConsumed`）。

**所需环境变量**：

> 下表 6 个 `EXPECTED_*_CODEHASH` 仅在 **same-nonce 复用部署**（目标 nonce 的 hook proxy 已存在）时必需，任一未设脚本 `revert`（`ExpectedCodehashNotSet(envVar)`，统一 error，`envVar` 字段指明缺失的具体变量名）；fresh 部署可全部省略。其中 `EXPECTED_HOOK_PROXY_CODEHASH` 对应经 hook-flag mining 选址的 proxy，其余 5 个对应经固定 seed + nonce 预测的 artifact（implementation / lpTokenImplementation / 3 facet）。其余非 codehash 变量任何部署模式都必需。

| 变量 | 说明 |
| --- | --- |
| `PRIVATE_KEY` | 部署者私钥 |
| `OUTRUN_DEPLOYER` | 目标链 OutrunDeployer 地址 |
| `POOL_MANAGER` | 目标链 Uniswap v4 PoolManager 地址 |
| `HOOK_OWNER` | Hook proxy owner |
| `HOOK_TREASURY` | protocol fee 接收地址 |
| `DEPLOYMENT_NONCE` | 部署版本号，首次用 `0`，每次新部署递增 |
| `EXPECTED_HOOK_PROXY_CODEHASH` | 同 nonce 复用部署时校验 Hook proxy runtime 字节码 |
| `EXPECTED_HOOK_IMPLEMENTATION_CODEHASH` | 同 nonce 复用部署时校验 hook 实现字节码 |
| `EXPECTED_SWAP_FACET_CODEHASH` | 同 nonce 复用部署时校验 SwapFacet 字节码 |
| `EXPECTED_DYNAMIC_FEE_FACET_CODEHASH` | 同 nonce 复用部署时校验 DynamicFeeFacet 字节码 |
| `EXPECTED_SETTLEMENT_FACET_CODEHASH` | 同 nonce 复用部署时校验 SettlementFacet 字节码 |
| `EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH` | 同 nonce 复用部署时校验 `lpTokenImplementation` 字节码 |

**`DEPLOYMENT_NONCE` 语义**：

- 嵌入所有 CREATE3 salt：固定 salt artifacts 的地址由 `(deployer, nonce)` 决定；`hookProxy` 还取决于 `_selectProxySalt` 在 flag 候选上的 eligibility（干净链上通常为首个 flag candidate）
- 同 nonce + 完整同配置 hook → 幂等复用（走 `_selectProxySalt` reuse 分支，不重部署中间件）
- 同 nonce + fresh 路径：固定 salt 中间 artifact 已占用 → revert；本 hook 配置/codehash 冲突 → revert；仅 hook 最终地址被无关代码占用且中间 artifact 仍空 → mining 跳过该候选，不必然换 nonce
- 不同 nonce → 全新地址集
- same-nonce 复用验证必须覆盖 `hookImplementation`、`lpTokenImplementation` 与 3 facet 地址：这五者经固定 seed + nonce 预测，必须等于同 nonce 预测地址、非零且有代码；`hookProxy` 经 `_selectProxySalt` eligibility 选址（flag + dirty skip / reuse / consumed-or-config-conflict revert；见上表 `EXPECTED_HOOK_PROXY_CODEHASH`），不适用固定预测地址路径，复用校验由 `_validateExistingImplementationCodehashes`（proxy / implementation / lpToken / 3 facet codehash）与 `_validateExistingDeployment`（implementation 地址 / owner / treasury / poolManager / facet 绑定）完成。部署选中地址预测用完整 `getPredictedProxy(..., nonce, hookOwner, hookTreasury, poolManager)`，勿用仅返回首个 flag candidate 的三参数 overload。
- `lpTokenImplementation` 与 3 facet 的运行期 codehash 都必须等于预期值（`hookImplementation` 的 codehash 由 `EXPECTED_HOOK_IMPLEMENTATION_CODEHASH` 单独覆盖）；复用校验中四者均要求 codehash、地址与代码存在性匹配，3 facet 的 `poolManager` immutable 一致性分路径保证：复用路径由 codehash 隐式覆盖（poolManager 构造时以 immutable 烧进字节码，codehash 匹配即必然一致，故复用路径不另跑 `_requireFacetPoolManager`）；部署路径经 `_validateDeployedArtifactCode`→`_requireFacetPoolManager` 显式校验（mismatch revert `ExistingHookFacetPoolManagerMismatch`，覆盖 SwapFacet / DynamicFeeFacet / SettlementFacet）；运行期则由 hook 链上 `_requireFacetPoolManager` 在 `initialize`/`setFacet` 独立强制（mismatch revert `FacetPoolManagerMismatch`，错误名与前两者不同）。

**原子性保证**：

两个部署入口的原子性不同，须区分对待：

- `deployHookProxy(...)`（无 broadcaster 修饰器）：编程/测试入口，6 次 CREATE3 deploy 在单笔交易内部、任一步失败整笔回滚、不耗 salt；它用于在非广播上下文验证 `_executeDeployment`，生产部署不走此入口（见下）。
- `run()` / `run(uint256)`（`run(uint256)` 带 `startBroadcast`）：`forge script` + `vm.startBroadcast` 下，`_executeDeployment` 中的 6 次 `outrunDeployer.deploy()` 会被 Foundry 当作 6 笔独立交易按 nonce 依次广播（广播语义见 `script/AGENTS.md`），非原子。仿真阶段任一笔失败则零笔上链、不耗 salt；仿真通过后才依次广播，若后续某笔链上失败（mempool/gas/nonce 抢占，或仿真与上链之间的状态漂移），已上链的前序交易不会回滚，对应 CREATE3 salt 被消耗，须递增 `DEPLOYMENT_NONCE` 重部。
- 两入口共享 `_executeDeployment`。部署必须严格遵循 `lpTokenImpl → swapFacet → dynamicFeeFacet → settlementFacet → hookImpl → hookProxy`；不得跳过或重排任何步骤。（同 nonce 完整复用分支例外：`reuseExistingProxy==true` 时 `_executeDeployment` 提前 return、仅做 view 校验、广播 0 笔交易，见 §3.10 `DEPLOYMENT_NONCE` 语义中的幂等复用。）

**部署顺序约束**。Hook proxy 在部署时立即以 3 facet 地址与配置初始化。hook 的 `initialize()` 会校验 facet 地址非零，并经 `_requireFacetPoolManager` 校验 facet 字节码就绪（`FacetCodeNotReady`）且 poolManager 与 hook 一致（`FacetPoolManagerMismatch`），因此必须先完成 LP token implementation、3 个 facet 与 Hook implementation 的顺序部署，最后部署 Hook proxy。Hook proxy 地址在部署前已通过 CREATE3 salt 挖矿确定。

**失败恢复**：

两入口失败对 salt 的消耗不同：`deployHookProxy()` 单笔调用失败不耗 salt；`run()` 下仅仿真阶段失败零笔上链不耗 salt，`--broadcast` 后部分链上失败会耗 salt。`run()` + `--broadcast` 多笔广播的部分链上失败是预期/标准行为（非异常），非"手动拆分"所致。操作建议：`--slow` 让 Foundry 逐笔等收据、防 nonce 抢占；`--resume` 从 broadcast log 续发已签名的未完成交易、不重新仿真/不重跑脚本（见 `script/AGENTS.md`）：若仅 timeout/gas 中断、salt 未耗，可成功续发剩余交易；若某笔 salt 已耗，续发该笔时 `_deployArtifact` 的 guard 逻辑根本不会运行（--resume 不执行脚本），真实失败发生在链上 `outrunDeployer.deploy` 内部 CREATE3（solmate `DEPLOYMENT_FAILED`），仍须递增 `DEPLOYMENT_NONCE` 重部。该 nonce 不可安全复用，恢复方式为递增 `DEPLOYMENT_NONCE` 重新执行；残留地址不会被新 nonce 覆盖，不影响新部署。若仅 hook 最终地址被无关代码占用、而固定 salt 中间 artifact 与 CREATE3 槽仍空，脚本会跳过该 dirty flag 候选并继续 mining，不必因此换 nonce。

在正常脚本执行且 `_deployArtifact` guard 会运行的路径，脚本为失败路径提供明确的错误类型（`Create3SaltConsumed`、`ExistingIntermediateDeploymentNotReusable` 等）。`forge script --resume` 不重新执行脚本或 guard；续发交易在链上 CREATE3 失败时可能直接暴露 solmate `DEPLOYMENT_FAILED`。

### 3.11 返佣（Referral Rebate）运维

普通 swap 携带 referrer 时，protocol fee 切 rebate 到 hook proxy custody；rebate 配置与领取入口均在 hook。

- **领取 rebate（referrer 主动）**：`MemeverseUniswapHookUpgradeable::claimRebate(currency, recipient)`（Router 直接实现）。无 onlyOwner / caller 白名单，任何地址可作为 `recipient`；caller 是 referrer（`pendingRebate` 按 `msg.sender` 索引），`recipient` 非零。`pendingRebate` 在 external transfer 前清零（CEI），并带 `nonReentrant` 双重防重入。currency 与该 referrer 累计 rebate 的 protocol fee currency 一致（in-kind）。`pendingRebate` 是 `[referrer][token]` 二级 mapping 记账（Router storage），hook 无批量 claim 入口；referrer 若在多 token 累积 rebate 须逐 token 调用 `claimRebate`。前端/SDK 应先从 `ReferralRebateAccrued` 事件历史聚合 distinct currency（`currency` 已 indexed，可按 referrer+currency topic 直接 filter），再对每个 currency 逐次调用 `claimRebate`。
- **查询未领 rebate**：`MemeverseUniswapHookUpgradeable::pendingRebateOf(referrer, currency)`（view）。注意 hook proxy 持有的 token 余额 ≥ Σ 所有 referrer 的 `pendingRebate` 是返佣偿付能力不变量（见 [docs/spec/invariants.md](spec/invariants.md) INV-20）。
- **改返佣率**：`MemeverseUniswapHookUpgradeable::setReferrerRebateBps(bps)`（Router 直接实现，`onlyOwner`）。约束 `bps <= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`），否则 revert `RebateExceedsProtocolShare`。触发 `ReferrerRebateBpsUpdated(oldBps, newBps)`。
- **查询当前返佣率**：`MemeverseUniswapHookUpgradeable::referrerRebateBps()`（view）。默认 `1000`（10%）。
- **rebate 职责归属**：返佣逻辑分布在 Router 与 SwapFacet，与 DynamicFeeFacet 无关——`setReferrerRebateBps` / `claimRebate` / `pendingRebateOf` / `referrerRebateBps` 在 Router 直接实现，`pendingRebate` 的 accrual 在 SwapFacet 的 `_settleProtocolFee`（`_collectProtocolFee` 与 beforeSwap 主路径均调用它）；`referrerRebateBps` 与 `pendingRebate` 均存于 Router 共享 storage（ERC7201 namespace `outrun.storage.MemeverseUniswapHook`）。
- **Router implementation 升级（UUPS `upgradeToAndCall`）对 rebate 的影响**：`referrerRebateBps` 与 `pendingRebate` 位于 Hook Router 的 ERC7201 storage；常规升级以空 `data` 运行，在新 implementation 保持兼容 storage layout 的前提下保留其值。`initialize` 仅在 proxy 首次初始化时写入默认 `DEFAULT_REFERRAL_REBATE_BPS`（`1000`），不会在常规升级中再次执行或重置该值。`referrerRebateBps == 0` 只停止新的 rebate accrual；既有 `pendingRebate` 仍可通过 `claimRebate` 领取。启用或调整 rebate 必须由 owner 显式调用 `setReferrerRebateBps(...)`。现有代码没有 versioned reinitializer，因此升级 `data` 必须为空。
- **facet 替换（`setFacet`）对 rebate 的影响**：换 SwapFacet 切换 rebate accrual 逻辑实现，账本与率仍在 Router storage；换 DynamicFeeFacet 只影响动态费率计算（`dynamicFeeState`：EWVWAP / 波动率 / 短期冲击），不触及 rebate。facet 替换保留 Router storage 中的全部状态。三类 facet 替换均经 `setFacet` → `_requireFacetPoolManager` 强制 PoolManager 一致。
- **coverage**：返佣只在普通 swap（SwapFacet 的 `beforeSwapLogic` / `afterSwapLogic`）路径触发；preorder settlement（SettlementFacet 的 `executeSettlementLogic`）不携带 referrer，不参与返佣。

#### 3.11.1 返佣相关 revert 条件

- `RebateExceedsProtocolShare`：`MemeverseUniswapHookUpgradeable::setReferrerRebateBps(bps)` 当 `bps > FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`）时触发，保证单次 swap 的 rebate ≤ protocol fee，不会透支 protocol share。`[代码已证]`
- `OutrunSafeERC20.SafeERC20FailedOperation(address token)`：`MemeverseUniswapHookUpgradeable::claimRebate(currency, recipient)` 经 `CurrencySettler.transferWithGuard` → `OutrunSafeERC20.safeTransfer` 执行 rebate token 转账，当 transfer 返回 `false`、返回非 bool 数据（非标准 ERC20）、或 low-level call 失败时触发；CEI 下 `pendingRebate` 已先清零，整笔 revert 回滚清零，账本与余额同步。`[文档已对齐实现]`

#### 3.11.2 treasury 必须非零配置

- `treasury` 必须在 hook 上非零配置；`MemeverseUniswapHookUpgradeable::setTreasury` 已 reject 零地址。若 treasury 未配置或在运行期被清零（当前实现无 zero-address 清零路径，但运维侧若错误 retarget 到零地址），普通 swap 在 `_takeToTreasury`（`SwapFacet`）有显式零地址守卫，treasury 为零时在任何 `poolManager.take` 之前直接 `revert Unauthorized()`，不依赖 token 行为；preorder settlement 在 `_collectPreorderSettlementInputFees`（`SettlementFacet`）直接 `transferFrom` 到 treasury，无显式零地址守卫，零地址时是否 revert 取决于具体 token（非标返 false 触发 `ERC20TransferFailed`，标准实现通常自身 revert）。`[代码已证]`

#### 3.11.3 返佣记账（pendingRebate accrual）只在 swap unlock session 内执行

- SwapFacet 的 `_settleProtocolFee`（`_collectProtocolFee` 调用；beforeSwap 主路径直接调）先内联累加 `pendingRebate[referrer][currency] += amount` 并 emit `ReferralRebateAccrued`（effect），再通过 `_takeToTreasury` 调用 `PoolManager.take`（interaction），最后 emit `ProtocolFeeCollected`。返佣记账这一步是纯 storage effect，无 PoolManager 调用、外部调用或 facet→facet delegatecall；它先于 treasury take 与调用方执行的 rebate take，`_settleProtocolFee` 现为严格 CEI（effect → interaction → event）。`PoolManager.take` 不触发 v4 hook callback；对于 ERC20 currency，它仍会调用 token 的 `transfer`，执行外部 token 代码。fee currency 必须为标准 ERC20（注册的协议费代币；普通池下为输入代币），并保持 treasury 为被动收款方；任一 take 或 token transfer 失败会回滚整笔 swap。beforeSwap 主路径把 rebate take 与 LP fee take 合并为一次 `poolManager.take(currencyIn, address(this), knownLpInputFee + rebate)`，afterSwap / beforeSwap 边界由 `_collectProtocolFee` 独立执行 rebate take。所有调用点均在 PoolManager unlock session 内；SwapFacet logic 函数开头检查 `address(this) != __self` 防直接 CALL（`__self` 为 facet 自身地址 immutable）。`[代码已证]`

`[代码已证]`

### 3.12 GenesisCredit 冷启动运维

GenesisCredit 是 per-uAsset ERC20+OFT 凭证，固定 18 decimals，与某个 18-dec `uAsset` raw-unit 1:1 对应（符号约定 `cr` + uAsset symbol，如 `crUUSD`）。`leveragedGenesisWithCredit` 用它抵扣杠杆利息，等价"免费借贷参与创世"。`[代码已证]`

> 精度约束：当前 credit path 只支持 `uAsset.decimals() == 18`。非 18-dec `uAsset`（如 6-dec 稳定币）可走普通 `genesis` / `leveragedGenesis`，但不得部署 GenesisCredit、不得启用 `leveragedGenesisWithCredit`；否则 `1e18` raw credit 会被当作 `1e18` raw uAsset 利息，导致 debt / launch gate / YT / residual 按错误数量级计算。

#### 部署时序

- `GenesisCreditFactory` 必须先于 `POLendUpgradeable` 部署完成。`_buildPOLendCreationCode` 将本次脚本部署的 factory 地址写入 POLendUpgradeable `initialize` 的 `creditFactory` 参数；未在本次运行部署 factory 时使用 `CREDIT_FACTORY_PROXY` env。`leveragedGenesisWithCredit` 经 `creditOf(uAsset)` 查 GenesisCredit 地址，`setCreditFactory`（owner-only）用于事后修正或迁移。readiness 校验 `POLendUpgradeable.creditFactory()` 有代码，阻断占位（未设 `CREDIT_FACTORY_PROXY` 时 owner 兜底写入的 EOA，无代码）无声通过——避免系统开放后 `leveragedGenesisWithCredit` 首次解析因对无代码地址 staticcall 返空、`abi.decode` revert 而阻断 credit 路径。
- 无循环依赖：`GenesisCreditFactory` 自内联 CREATE3（不依赖 `OutrunDeployer`），仅依赖 LayerZero `lzEndpoint`，不依赖 POLendUpgradeable / Launcher。
- per-uAsset GenesisCredit 通过 `deployCredit(uAsset, name, symbol, delegate)` 按需部署，`salt = keccak256(abi.encode(uAsset))` 保证本链确定性地址（同链不同 uAsset 不冲突、`predictCredit` 可预测；factory 地址作 CREATE3 namespace）。跨链同址需 `factory + uAsset` 均跨链同址（部署前提），非合约强制；`uAsset` 是外部 Outrun 资产，其跨链同址性非本代码校验。`setPeer` 必须按各链实际 `creditOf(localUAsset)` 配置，不得复用本链地址。

#### `deployCredit(uAsset, name, symbol, delegate)` 流程

- owner-only；`uAsset != address(0)`。
- `delegate != address(0)`：delegate 是 GenesisCredit 初始 owner / LayerZero admin delegate；零值调 `deployCredit` 直接 revert `ZeroDelegate()`（零 delegate 时构造链由 OZ Ownable v5 构造器零地址校验先于 OAppCore 触发 revert，入口校验保证 fail-fast 与清晰错误）。
- `uAsset.decimals() == 18`：GenesisCredit 固定 18 decimals，credit path 要求 credit 与 `uAsset` 同 raw-unit 口径；非 18-dec `uAsset` 调 `deployCredit` 直接 revert `InvalidUAssetDecimals`，部署前运维必须核验该 `uAsset` decimals。
- CREATE3 部署 GenesisCredit（ERC20+OFT），初始化 `name / symbol / delegate`。
- 成功后返回（或可经 `creditOf(uAsset)` 读到）GenesisCredit 地址；同 `uAsset` 重复部署 revert（salt consumed）。
- 部署后须把目标链设为 peer（OFT `setPeer`），否则跨链桥 revert。
- OFT 精度决策：`decimals() = 18`（全链恒定，跨链不变）；`sharedDecimals()` 用默认 6，禁止覆写为 18（否则单笔跨链上限骤降到 18.4 单位）。

#### 执行模板（cast）

```bash
# 1) 按需部署 per-uAsset GenesisCredit（GenesisCreditFactory owner 私钥）
#    $CREDIT_FACTORY = 脚本部署输出，或 cast call $POLEND_PROXY "creditFactory()(address)" 读回
#    name/symbol 取值：符号约定 "cr" + uAsset symbol（如 crUUSD）；$UASSET 必须 18-dec，
#    非 18-dec revert InvalidUAssetDecimals；$DELEGATE = credit 初始 owner / LZ admin delegate
#    （零地址会在 GenesisCredit 构造时 revert OwnableInvalidOwner(0)——OZ Ownable v5 先于
#    LZ OAppCore 的 InvalidDelegate 检查触发；home 链上它就是 setMerkleRoot 操作方）
cast send $CREDIT_FACTORY "deployCredit(address,string,string,address)" \
  $UASSET "cr<SYMBOL>" "cr<SYMBOL>" $DELEGATE \
  --rpc-url $RPC --private-key $FACTORY_OWNER_KEY

# 部署后核验：creditOf(uAsset) 返回 GenesisCredit 地址（同 uAsset 重复部署 revert，salt consumed）
cast call $CREDIT_FACTORY "creditOf(address)(address)" $UASSET --rpc-url $RPC

# 2) 各链把本链 credit 的对端 peer 指向目标链实际 creditOf(localUAsset)（credit owner 私钥）
#    $CREDIT_ADDR = 上一步本链 creditOf(localUAsset) 返回值；$REMOTE_EID = 目标链 LayerZero
#    endpoint id（部署 env endpoints[chainid] 同名值，可 cast call <目标链 endpoint> "eid()(uint32)" 核验）；
#    $REMOTE_CREDIT_ADDR = 目标链 creditOf(localUAsset) 实际地址（须在目标链部署该 uAsset credit
#    后、用目标链 RPC 查询，cast call $REMOTE_CREDIT_FACTORY "creditOf(address)(address)" $UASSET；
#    uAsset 跨链同址是部署前提、非合约强制——目标链 uAsset 地址不同时须改用目标链地址查询，
#    否则返回 0 且 setPeer 到 bytes32(0) 等于删除 peer，运行时才 NoPeer 暴露），不得复用本链地址；
#    A↔B 双向互通须两链各自执行一次 setPeer
cast send $CREDIT_ADDR "setPeer(uint32,bytes32)" $REMOTE_EID \
  $(cast to-bytes32 $REMOTE_CREDIT_ADDR) \
  --rpc-url $RPC --private-key $CREDIT_OWNER_KEY
```

#### `homeChainEid` 部署参数护栏

- `GenesisCreditFactory.homeChainEid` 与 `GenesisCredit.homeChainEid` 均为 immutable：factory 构造时写入并注入每个 credit 的 init_code，部署后无法修正。它是 `claim` 的 home-chain 门控（`endpoint.eid() == homeChainEid`）的参数来源——远程链 factory 若误把 `homeChainEid_` 设成本地 remote eid，门控在远程成立，叠加 owner 在远程也 `setMerkleRoot` 即可双铸。
- 脚本无法自动判定此误配：远程链把 `HOME_CHAIN_EID` 填成本地 eid 时，`homeChainEid == localEid` 在远程成立，与合法的 home 链部署不可区分。故护栏是程序性的三层（与 `script/MemeverseScript.s.sol::_deployGenesisCreditFactory` NatSpec 对齐）：
  1. 单一来源：部署脚本 `_deployGenesisCreditFactory`（`script/MemeverseScript.s.sol`）从 `HOME_CHAIN_EID` env 读规范 home eid，**绝不**从本地 endpoint 派生。每条链（home 与 remote）都传同一个规范值，消除"照搬本地 eid"的脚枪。
  2. 部署后链上复核：脚本 re-read factory 的 `homeChainEid()` 并 assert 等于 env 值（防构造参数打包/顺序错误，**不**防 env 本身填错）。
  3. 日志人工对照：脚本打印 `homeChainEid` 与 `localEid`（localEid 为 best-effort，无 fork simulate 时退化为 `<unavailable>`），运维据此判定 home/remote 关系。
- 部署后人工对照（runbook）：home 链日志须 `homeChainEid == localEid`；remote 链日志须 `homeChainEid != localEid`。任一链不符合则立即停手，已部署 factory 作废重部。
- 第二道防线（运维纪律）：`setMerkleRoot` 仅在 home 实例调用；远程实例 `merkleRoot` 恒为 `bytes32(0)`，即便门控因 `homeChainEid` 误配在远程成立，`claim` 路径对零 root 仍 revert `InvalidProof`。此纪律是 homechain-only claim 设计的隐式防线，不得破坏。（`setMerkleRoot` 在 home 实例可重复调用；此纪律约束的是调用位置，不是调用次数。）
- 部署路径唯一性：`GenesisCreditFactory` 必须仅经 `_deployGenesisCreditFactory` 部署，运维不得带外手动 `new GenesisCreditFactory(...)`——手动部署绕过上述全部护栏（单一来源 / re-check / 日志），会引入双铸风险。若因故必须带外部署，必须人工完成等价校验：构造参数 `homeChainEid_` 取规范 home eid、部署后 `cast call <factory> homeChainEid()` 核对、`cast call <endpoint> eid()` 对照 home/remote 关系。
- 合约侧 fail-fast：factory 构造时 `homeChainEid_ == 0` 直接 revert `ZeroHomeChainEid`（immutable 零值会让该 factory 所有 credit 的 claim 恒 revert `NotHomeChain`，无链上修复手段，只能换新 factory + `POLendUpgradeable.setCreditFactory` 迁移）。脚本 `require(envEid != 0)`（`ZERO_HOME_CHAIN_EID`）之上再叠加合约防线。该合约防线仅覆盖零 eid 误配；非零但错误的 eid 仍须人工等价校验（见上条部署路径唯一性）。

#### `setMerkleRoot` 配置

- GenesisCredit 的 `claim(...)` 是 permissionless merkle claim：任何地址凭 merkle proof 领取分配给它的 credit。
- merkle root 由链下快照生成（链下计算每个 claimer 的分配额，构造 merkle tree，发布 root）。
- root 只在 **home 链（Ethereum 主网）** 写入：操作方可先通过 `GenesisCreditFactory.creditOf(uAsset)` 查询对应 GenesisCredit 地址；只有该 GenesisCredit 的 owner（部署时传入 `deployCredit(..., delegate)` 的 `delegate`，或后续 `transferOwnership` 后的新 owner）可以直接调用 `GenesisCredit.setMerkleRoot(root)`；非 home 链调用 `claim` 直接 revert，防止跨链重复领取。
- 安全敏感：root 必须仅 home 链；目标链上的 GenesisCredit 不接受 claim，只能从 home 链 claim 后经 OFT 桥过来。

#### home 链运维要点

- home 链是 Ethereum 主网；GenesisCredit 的 merkle claim 单点写入发生在这里。
- 运维发布 merkle root 前必须核验链下快照（claimer 列表 + 分配额）正确性；已 claim 的 credit 不可撤销（合约无 clawback 路径），但 root 本身可由 home 链 owner 在 claim 发生后多次 `setMerkleRoot` 替换/清空（生命周期语义见下文）。
- 目标链的 GenesisCredit 是 OFT 接收端，不持有可 claim 的 merkle root；用户在 home 链 claim 后把 token 经 OFT `send` 到目标链即可在目标链使用。
- root 生命周期语义（与「写入一次」的直觉相反，均经代码核验）：
  - `GenesisCredit.sol::setMerkleRoot` 可被 home 链 owner 任意多次调用（替换或清空为 `bytes32(0)`），无 one-shot 守卫、无链门控（`onlyOwner` 即全部限制）。
  - 已 claim 用户永久锁定原分配：`claimed` 守卫先于 proof 校验（`GenesisCredit.sol::claim` 中 `require(claimed[msg.sender] == 0)` 先于 `MerkleProof.verifyCalldata`），即使新树给更大分配也无法补领。
  - 未领取用户旧 proof 在新 root 下失效（孤儿化）；迁移路径 = 在新树中重新包含该用户，无协议内迁移机制。
  - root 清空为 `bytes32(0)` 等于全局禁用剩余 claim（任何 proof 对零 root 恒 `InvalidProof`）；`MerkleRootSet` 事件无旧值参数（`IGenesisCredit` 事件签名仅 `bytes32 merkleRoot`），树版本追踪只能外部记录。
  - 轮换属于正常运维操作（修正快照、扩展空投），勿按「写入一次」假设不可变。

### 3.13 跨链 compose 失败的人工重试（YieldDispatcherUpgradeable）

入口：`MemecoinYieldVault.reAccumulateYields(dispatcher, guid, message)`（MEMECOIN 路径）或 `YieldDispatcherUpgradeable.settlePendingCompose(token, guid, message)`（MEMECOIN/UASSET 通用）。本节（dispatcher 侧）两个入口都 permissionless——任何地址可执行，不需要 admin 权限；协议有意不提供 onlyOwner 恢复入口。跨链 staking compose 的恢复入口在 `OmnichainMemecoinStaker`，权限与结算语义不同（仅接收人可调、恒释放裸币不建仓），见 §3.13.1。

适用时机（失败都来自外部瞬时原因，不是 vault/governor 损坏——vault/governor 部署即验证，不假设永久故障）：

恢复前提是 payload 金额非零、格式合法——格式合法 = 可解码（内层 ≥ 64 字节、静态元组前两 word 内容有效；尾部忽略，>64 字节可解析帧可经 settle 恢复，见下）。零金额（amountLD=0）与格式非法 payload 均不可经 settle 重试恢复，但 `lzCompose` 路径对这两类都能收敛——完整收敛矩阵见本节末尾「边界——零金额/格式非法 payload 均不可经 settle 重试恢复」条目，零金额收敛行为另见 interoperation-details.md §3.4。

注：本节收敛断言均为 dispatcher 侧——「零金额与格式非法 payload 两类都能收敛」中，格式非法类仅 dispatcher 对全部子类收敛（`_parseCompose` 消费路径）；staker 对 64 字节脏 receiver 帧消费、脏 vault 帧释放，对长度畸形帧（内层 ≠ 64 字节）以 `MalformedComposeMsg` revert（CEI `Settled` 回滚、guid 回 `None`、endpoint 队列 pin、executor 重试恒失败），不收敛，见 §3.13.1「跨 composer 判定」；零金额 × 64 字节帧两 composer 均收敛（staker 侧 vault 无 code 时 `_transferOut(0)` no-op、vault 有 code 且 `asset()` 匹配时 `deposit(0)` 提前返回；命名 `asset()` 不匹配真实 vault 的帧 `TokenVaultMismatch` revert、`asset()` 缺失/主动 revert/OOG 的 vault 帧经空数据/自带错误 revert（无 staker 具名错误，见 §3.13.1「asset() 不可读」边界条目）、receiver==0 且非零金额的帧经零地址守卫 revert（零金额 × receiver=0 因两分支早退同样收敛，见 §3.13.1 receiver=0 边界），见 §3.13.1 畸形条目末注与 receiver=0 边界）。`[代码已证]`

- 目标链 `lzCompose` 执行失败（如跨链执行 gas 不足、executor 投递中断），且 LayerZero 自动重试未成功
  - 注：该条件可经 endpoint 的 `LzComposeAlert` 事件提前感知：`lzComposeAlert` 为公开 permissionless 入口，`reason` 字段携带失败原因字节——OOG 等耗尽型失败时被调帧 returndata 为空、`reason` 为 0x。该入口免许可、事件可被任意地址伪造，仅作告警信号，投递/失败证明仍以 composeQueue 哈希匹配 / `ComposeDelivered` 为准。
- `settlePendingCompose` 调用过但交易 revert（如调用者给的 gas 不足），资金仍在 dispatcher
- UASSET 路径：`receiveTreasuryIncome` 内部 `recordTreasuryIncome` 要求 token 已注册为 treasury token，分两种情况：
  - 金额非零但 token 未注册 → revert `NonTreasuryToken`——配置时序问题，先完成 token 注册（治理路径）再重试，可恢复。**注意治理周期延迟**：`registerTreasuryToken` 为 `onlyGovernance`（`GovernanceCycleIncentivizerUpgradeable.sol`），唯一路径是治理提案；生产 governor 无 timelock extension、`votingDelay=1 days` + `votingPeriod=1 weeks`（`MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer`），故从提交提案到执行完成需约 8 天。提案执行前 token 仍未注册（`_treasuryTokens[token]` 仍 false），此窗口内任何 settle 重试恒 revert `NonTreasuryToken`，属预期而非恢复失败——资金仍滞留 dispatcher、重试幂等可无限次执行（见下方「为什么失败后直接重试即可恢复」），须待提案执行完成后再重试
  - 零金额（amountLD=0）→ revert `ZeroInput`——settle 路径上该 revert 由 `YieldDispatcherUpgradeable.sol::settlePendingCompose` 自身的 `ZeroInput` 检查在到达 governor 前先抛出（`recordTreasuryIncome` 内同为 `ZeroInput` 先于 `NonTreasuryToken`，selector 一致），注册 token 无法修复；经 settle 不可收敛，但 lzCompose 路径经 `_settle` 零金额短路在到达 recordTreasuryIncome 前即收敛（收敛矩阵见下方边界条目）
- MEMECOIN 路径：`accumulateYields` 因 gas/时序等外部原因失败

为什么失败后直接重试即可恢复：

- 失败交易原子回滚，`composeStates[token][guid]`（按真实桥接 token 键控）在成功前恒为 `None`；重试天然幂等，可无限次执行。仅对可恢复原因（gas 不足、时序、token 未注册）成立；零金额/格式非法 payload 不可经 settle 重试恢复，见下方边界条目
- 与 `lzCompose` 互斥：先成功者定终态（`Settled`/`Released`），重试不会双花；`Released` 后迟到的 `lzCompose` 重试由 composer 幂等放行（no-op），不迁移状态、不二次结算
- `message` 由 endpoint `composeQueue` 哈希绑定、接收方从 message 解码，调用者不可篡改
- 边界——零金额/格式非法 payload 均不可经 settle 重试恢复（超长帧内容可解析类除外，见下）：
  - 格式非法/不可解码 payload（内层 composeMsg <64 字节、receiver 槽高位脏，或 TokenType raw 越界）：`lzCompose` 解析失败即置 `Settled`（不结算、不动资金）并发出 `ComposeRejected(guid, token, amount)`，endpoint 状态机收敛（队列槽→`RECEIVED_MESSAGE_HASH`、`ComposeDelivered`）、executor 停止重试；消息内容对 guid 由 endpoint 队列哈希永久绑定，畸形消息永远无法结算，故消费槽不封堵任何合法结算；资金仍滞留 dispatcher（自伤边界，只能从发送端杜绝）。`settlePendingCompose` 对未消费的畸形 composeMsg 在 `abi.decode` 前显式 revert `MalformedComposeMsg`，而非不可读的 decode 回退——`verifySettle` 在 codec 切片（`amountLD` 切 `[12:44]`、`composeMsg` 切 `[76:]`）前先校验帧长 ≥ 76 字节（OFT compose header 全长 = nonce 8 + srcEid 4 + amountLD 32 + composeFrom 32），header 不完整帧（<76 字节，header 即不完整、内层 composeMsg 切片必然越界；区别于 events.md `ComposeRejected` 「短帧为 0」所指 amountLD 不可读的 <44 字节帧）在此前置守卫即被具名拒绝，随后再校验内层 composeMsg 长度 >= 64 字节；裸 `abi.decode` 回退边界仅存在于 dispatcher 的 `settlePendingCompose`——它是唯一裸 decode 入口：守卫只有长度校验（>= 64，仅校验 schema 形状），静态元组 `(address, TokenType)` 的 `abi.decode` 忽略 64 字节后的尾部，故 >64 帧经 settle 与正向按前两 word 结算完全一致；receiver 高位脏 / TokenType raw 越界等长度合法但内容非法的 payload 仍会在此入口的 `abi.decode` 处 revert（空数据回退）；staker 侧无此边界：`lzCompose` 消费/释放内容非法帧（见 §3.13.1），`settlePendingCompose` 以 ≥32 长度守卫 + 具名 `MalformedComposeMsg` 拒绝。但 settle 路径与 `lzCompose` 的**结算**语义不同：settle revert 回滚、`composeStates` 保持 `None`，而 `lzCompose` 置 `Settled` + emit `ComposeRejected` 收敛。该 revert 发生在任何结算之前。这类畸形 payload 的消息内容由 endpoint 队列哈希永久绑定、无第三方可触发，唯一恢复入口 `settlePendingCompose` 即因 decode 失败而不可达，资金永久滞留——这是显式记录的自伤边界（持币人用自己发起的畸形 composeMsg 困住自己的资金，只能从发送端杜绝），协议不为此提供 owner 回收入口。对已消费槽 revert `AlreadyResolved`。
    - 上述 `MalformedComposeMsg` 断言中**内层长度守卫**的部分均指非零金额帧：`settlePendingCompose` 的 `ZeroInput` 检查先于内层长度守卫（`YieldDispatcherUpgradeable.sol::settlePendingCompose`），零金额 × 内层 <64 字节帧（帧 ≥ 76 通过 `verifySettle`）实际 revert `ZeroInput` 而非 `MalformedComposeMsg`；verifySettle 的帧长 ≥ 76 守卫与金额无关、恒先于 `ZeroInput`（仅受 hash 匹配限定，见下）；「<76 字节帧在此前置守卫即被具名拒绝」同样仅对 hash 与队列槽匹配的真实投递帧成立——`verifySettle` 守卫序为 `NotDelivered` → `AlreadyExecuted` → `InvalidProof` → 帧长 ≥ 76，损坏/猜测 message 探测一律先 revert `InvalidProof`（按错误名 grep 的监控须对得上号）。`[代码已证]`
  - 超长帧类（内层 composeMsg > 64 字节，帧长 > 140 字节）：内容可解析（前两 word 干净、enum 在 0/1 范围、receiver 非自引用）的 >64 帧：`lzCompose` 固定偏移解析、按前两 word 结算、尾部忽略；`settlePendingCompose` 以 >= 64 守卫接受并重跑一致结算——兜底承诺对该子类成立；前两 word 脏/越界的 >64 帧仍归格式非法类（上一条）——`lzCompose` 触发 `ComposeRejected`、settle 在 `abi.decode` 空数据回退。仅自伤帧可达（协议发送端恒编码 64 字节内层，`MemeverseLauncherLib.sol::buildSendParamAndMessagingFee` 的 `abi.encode(receiver, tokenType)`），无资金错配
  - 零金额类（amountLD=0）：`settlePendingCompose` 两条路径仍以 `ZeroInput` 拒绝零金额（YieldDispatcherUpgradeable.sol::settlePendingCompose、OmnichainMemecoinStaker.sol::settlePendingCompose）、不可经 settle 收敛；但 `lzCompose` 路径对除自引用分支外的全部分支收敛（零金额自引用帧被 `lzCompose` 的自引用守卫先于 `_settle` 拦截——守卫无金额检查——emit `ComposeRejected(guid, token, 0)` 而非 `OFTProcessed`，见下条自引用类）——`_settle` 在 amount==0 时短路（不 burn、不记账），槽位→`Settled` + emit `OFTProcessed(amount=0, burnedAtDispatcher=false)`、endpoint 状态机收敛到 `ComposeDelivered`（与 vault 分支的零金额收敛行为一致）；收敛行为见 interoperation-details.md §3.4
  - 协议发送端已保证非零投递，两条协议 send 路径均在发送前预校验 `quoteOFT` 截断结果，按各自语义拒绝会截断到零的金额（被拒金额永不移动调用方代币/费用）：
    - staking 路径（`MemeverseOmnichainInteroperation.memecoinStaking` / `quoteMemecoinStaking`，远程分支）：在 `_transferIn` 之前校验 `quoteOFT(sendParam).oftReceipt.amountReceivedLD != 0`，拒绝会被 `_removeDust` 截断到零的亚尘金额（`amount < decimalConversionRate`，如 18 位小数 + 6 位共享小数时 `< 1e12`）——此类金额原本会全额拉进合约却零投递、零头寸、全额 LZ 费、dust 永久滞留（合约无 sweep/withdraw）。非零余数（`amount >= decimalConversionRate` 但 `amount % decimalConversionRate != 0`）不 revert：OFT `send` 烧掉截断后的 `amountSentLD` 后，`memecoinStaking` 在同一笔交易内把未烧的余数（`amount - amountSentLD`）经 `_transferOut` 退回 `msg.sender`（源链），无任何滞留；整数倍金额（`amount % rate == 0`，如整数 ether）余数为 0、不退款。
    - 费用分发路径（`MemeverseSettlementImpl._sendRedeemedFeesCrossChain`，govFee/memecoinFee）：在每个 `send` 之前校验 `quoteOFT(sendParam).oftReceipt.amountReceivedLD != 0`，仅拒绝截断到零的亚尘费用（费用 < `decimalConversionRate`）——费用为协议内部计算（swap 手续费累积），要求整数倍会 revert 正常结算，故非零余数（费用 % rate != 0）作为该路径已记录的 dust 滞留取舍保留（滞留在 launcher/dispatcher 而非 router）；预览路径 `MemeverseFeePreviewReader.quoteDistributionLzFee`（view）不加守卫、保持报价语义。
  - 故协议路径不可达零金额 compose；本条零金额收敛矩阵仅对第三方持币人经 permissionless OFT `send` 自行伪造的零金额（自伤）帧成立。`[代码已证]`
  - 自引用类（receiver == dispatcher 自身地址，非零金额、格式合法 payload；零金额子帧同被守卫拦截，emit `ComposeRejected(guid, token, 0)`，见上条零金额类）：持币人经 permissionless OFT `send` 自行伪造 `encode(dispatcher, TokenType)` 的 composeMsg 投入 dispatcher 队列时（协议发送端 `MemeverseSettlementImpl` 的 receiver 恒为 `verse.governor`（UASSET）或 `verse.yieldVault`（MEMECOIN），正常用户路径不可达，仅自伤），`lzCompose` 在 `_parseCompose` 后、`_settle` 前检测 `receiver == address(this)` 并走与畸形 payload 相同的消费路径（置 `Settled` + emit `ComposeRejected`、不结算、不动资金），endpoint 状态机收敛、executor 停止重试——消费而非 revert 是必要的：`_settleToContract` 会调用 `accumulateYields`/`receiveTreasuryIncome` 于 dispatcher 自身，dispatcher 既不实现这两个函数也无 fallback，故结算恒 revert；若不消费而是 revert，CEI 的 `Settled` 写入回滚、guid 回 `None`、endpoint 队列永久 pending，与本节声明的收敛目标相悖。`settlePendingCompose` 路径无 `ComposeRejected` 等价物，对该 payload 同其它内容非法帧一样 revert（`Released` 写入回滚、guid 保持 `None`），但 settle 是 permissionless 且仅重触发同一失败结算，第三方调用只浪费自己 gas、不放大损害。资金仍滞留 dispatcher（自伤边界，与 §3.13.1 staker `receiver==address(0)` 同哲学：协议不为此提供 owner 回收入口，只能从发送端杜绝）。与上述两类边界的区别：畸形 payload（不可解析）与零金额（可短路）都不进入 `_settleToContract`；自引用是唯一被消费守卫覆盖的"可解析、非零金额、却结算恒 revert"类（代码可静态识别 `receiver == address(this)`，见下一条「结算失败类」），故消费守卫落在 `_settle` 之前。`[代码已证]`
  - 结算失败类（可解析、非零金额，但结算恒失败——消费守卫未覆盖、队列不收敛的自伤边界）：以下子类经 `lzCompose`/ `settlePendingCompose` 两入口结算恒失败——`_settle` revert 使 CEI 的 `Settled`/ `Released` 写入随整笔交易回滚、`composeStates` 恒 `None`、endpoint 队列槽永久停留 `keccak256(message)`（`ComposeDelivered` 永不触发、executor 重试恒失败），无任何恢复出口（settle 重跑同一 `_settle` 同 revert；协议不提供 owner 回收入口）——(d) 除外：槽位保持 `None`，治理侧修复 incentivizer 指针后重试可恢复，见下（governor 无指针 setter，修复途径为 onlyGovernance 的治理 UUPS 升级）；资金滞留 dispatcher：(a) 合约 receiver 有 code 但不实现 `accumulateYields`/ `receiveTreasuryIncome` 且无 fallback（如 receiver = memecoin token 自身）——`_settleToContract` 回调恒 revert（solc 0.8.x 语义：有 code、无匹配 selector、无 fallback 的调用 revert）；(b) MEMECOIN-typed 的 EOA receiver + 无 caller-callable 单参 `burn(uint256)` 的 token——EOA 分支 `IBurnable(token).burn(amount)` 恒 revert（UASSET no-code 已不进 burn 分支：改走 `_transferOut(token, protocolTreasury, amount)` 成功、`burnedAtDispatcher=false`，见「receiver == address(0) 销毁类」与 §3.3）；(c) MEMECOIN 帧 receiver = 真实 vault 但 `asset()` ≠ 投递 token——绑定层拦截：`_settleToContract` MEMECOIN 分支在 approve 前 `require(IMemecoinYieldVault(receiver).asset() == token, TokenVaultMismatch())`（与 staker 同 selector），伪造 (fakeToken, realVault) 帧在资金移动前具名 revert（本轮 code writer 同步落地）；错误从拉取处 `ERC20InsufficientAllowance` 变为 approve 前 `TokenVaultMismatch`，绑定关闭该类、防御不再依赖"dispatcher 对该 vault 自身 asset 存在预存授权"的授权不变量。仍属结算失败/不收敛（本条首句 CEI 语义不变：revert 回滚 `Settled`、endpoint 队列不收敛）；(d) receiver = 真实 governor 但 `_governanceCycleIncentivizer` 指针损坏——`recordTreasuryIncome` 恒 revert（与"token 未注册"的 `NonTreasuryToken` 在重试流程中不可区分，但注册无法修复）。子类 (a)-(c) 仅自伤可达（协议发送端恒编码 governor/vault；持币人经 permissionless OFT `send` 自行构造），与畸形/零金额/自引用类同哲学：资金滞留 dispatcher 属接受的自伤边界，只能从发送端杜绝；(d) 的暴露帧与真实协议帧同构、仅在指针损坏前提下触发，修复路径是治理侧修复指针而非发送端杜绝。另注：与「超长帧类」条目的交集——>64 字节可解析帧若 receiver 属本类 (a)-(d)，兜底结算同样恒失败（超长帧可恢复性仅对结算成功类成立）。solc 0.8.x 高调 void 调用（`burn`/ `recordTreasuryIncome`）对无代码目标（EOA/address(0)/precompile/空 runtime）经 EXTCODESIZE 前置检查直接 revert（非静默 no-op）；仅「有 code 且 fallback 放行未知 selector」或空实现回调的目标静默成功（见下一条）。`[代码已证]`
  - fallback 吸收类（静默成功、零资金移动）：合约 receiver 有 code 且 fallback 放行未知 selector（或空实现回调），`_settleToContract` 的 approve+pull 回调"成功"返回但 receiver 从不 `transferFrom` 拉取 → dispatcher 照常 emit `OFTProcessed`/ `ComposeSettled`（burnedAtDispatcher=false）并终态化槽位（`Settled`/ `Released`），资金永久滞留 dispatcher、残留精确 allowance、无恢复出口——对账若按「false=已转账」会误判；`burnedAtDispatcher=false` 仅表示已发起 approve+pull，不保证实际拉取。MEMECOIN EOA 分支同类：token 有 code 且 fallback 放行 `burn` selector（或空实现 burn）→ `burnedAtDispatcher=true` 假报、零销毁（仅 MEMECOIN no-code 触达 `burn`；UASSET no-code 不调 `burn`、改走 `_transferOut`→`OutrunSafeERC20.safeTransfer`，空 returndata + 有 code 判成功、显式 `false`/revert 才 pin，终态 `burnedAtDispatcher=false`、非假报）。仅自伤可达。`test/mocks/verse/AttackComposeToken.sol` 不再为此类实证：该 mock 的 `asset()` 恒为 `address(0)`，MEMECOIN 帧将其命名为 receiver 时在绑定处（approve 前）即被拦截（`asset()` 永不等于投递 token，revert `TokenVaultMismatch`），不达回调；吸收类现仅对 UASSET 帧（无绑定分支，receiver 为 no-op `receiveTreasuryIncome` 合约）或 `asset()` 自洽（`asset() == 投递 token`）的 absorbing 合约 receiver 实证。`[代码已证]`
  - 伪造帧事件语义：`ComposeSettled`/ `OFTProcessed` 的 `token` 键不保证是真实桥接 token——endpoint `MessagingComposer.sendCompose` 免许可、按 `msg.sender` 键控，任何人可写自己的队列槽；permissionless `settlePendingCompose` 对该槽仍可走通结算，但伪造 settle 成功仅当 MEMECOIN 帧的合约 receiver 分支满足绑定（receiver 为自洽假 vault：`asset() == 攻击者 token`、空回调 no-op，攻击者无需持有/桥接任何代币）——该分支 receiver 为真实 vault 或未实现 `asset()` 的合约时经绑定校验 revert（真实 vault 具名 `TokenVaultMismatch`；无 `asset()` 合约对该调用的空数据 revert），不再"任意攻击者 token + 空回调即可成功"；绑定只存在于 MEMECOIN 合约 receiver 分支，另两处例外仍可伪造成功（无真实资产移动、零影响、语义不变）：(a) EOA/no-code receiver 分支：MEMECOIN → `IBurnable(token).burn(amount)`（攻击者自有 token 实现 no-op `burn(uint256)` 时成功、`burnedAtDispatcher=true`、无资金移动）；UASSET → `_transferOut` 到 `protocolTreasury`（任意可转账 token 即成功、`burnedAtDispatcher=false`、攻击者伪 token 被转入 `protocolTreasury`——有伪资产移动）；(b) UASSET 合约 receiver 帧（假 governor 实现 no-op `receiveTreasuryIncome` 时成功）；可零成本伪造 `ComposeSettled(guid, 攻击者token, 自洽假vault, 任意amount, burnedAtDispatcher)`（amount 可至 `uint256.max`；无真实资产移动；真实槽不受影响——msg.sender 键控使攻击者无法在真实 token 键下写槽）。对账/告警须按已知 token 地址过滤该事件。`[代码已证]`
  - receiver == address(0) 销毁类（EOA-burn 真实价值销毁，自伤，与 §3.13.1 staker 同帧 revert-pin 分叉）：当 composeMsg 的 receiver 解码为干净零 word（`_parseCompose` 放行：`0 >> 160 == 0`、parseable=true、enum 在范围、`0 ≠ address(this)` 故不进`lzCompose` 的自引用守卫）、金额非零时，`lzCompose`/`settlePendingCompose` 两入口均直达 `_settle` 的非合约 receiver 分支（`if (receiver.code.length == 0)`——EVM 中 `EXTCODESIZE(address(0)) == 0`，故 receiver=0 被当作普通 EOA）；该分支按 tokenType 分流：MEMECOIN → `IBurnable(token).burn(amount)`（销毁，`burnedAtDispatcher=true`），UASSET → `_transferOut(token, protocolTreasury, amount)`（路由协议金库，`burnedAtDispatcher=false`，非销毁）。本条目下文「销毁/总供应量」语义仅对 MEMECOIN 成立。与上述「结算失败类 (b)」（EOA + 无 burn 的 token → burn revert）的区别：本类的 token 实现了 caller-callable 单参 `burn(uint256)`（memecoin），burn 成功而非 revert。amount>0 子档（销毁、总供应量 −X）：对 memecoin 触发真实销毁（`Memecoin.sol::burn` `burn(amount)` → `_burn(msg.sender, amount)` → `_update(msg.sender, address(0), amount)`，`Transfer(to=0)`、跨链总供应量下降 X），槽位→`Settled`（lzCompose）/ `Released`（settle）、emit `OFTProcessed`/`ComposeSettled`（`burnedAtDispatcher=true`）、endpoint 状态机收敛（`ComposeDelivered`）——**与 §3.13.1 staker 同一自伤帧的语义相反**：staker 对 receiver=0 非零金额帧经零地址守卫 revert（fallback 分支 `_transferOut(memecoin,0,amount)` 触发 `ERC20InvalidReceiver`、vault 有 code 分支经 `ZeroSharesDeposit`/`ERC20InvalidReceiver`），CEI 回滚、资金滞留 staker 托管、总供应量不变、endpoint 队列 pin（不收敛）。即同一自伤帧在两 composer 呈现「销毁 vs 滞留」两种不可逆终态：dispatcher 销毁后无任何可对账的余额（资金从总供应量抹除、无恢复面），staker 滞留可对账余额但同样无 owner 回收入口。amount==0 子档（收敛、与 staker 一致）：`_settle` 零金额短路（`Settled` + emit `OFTProcessed(amount=0, burnedAtDispatcher=false)`、endpoint 收敛），与 §3.13.1 staker 零金额 × receiver=0 子档（fallback `TokenHelper.sol::_transferOut` 早退、vault `MemecoinYieldVault.sol::deposit` 早退、endpoint 收敛）行为一致。对账指引：dispatcher 侧 receiver=0 非零金额帧须结合底层 token `Transfer(to=0)` 与总供应量变化核对销毁，**不能按 §3.13.1 staker 的滞留语义去 dispatcher 余额找代币**（已被 burn、余额为 0、`burnedAtDispatcher=true`）。可达性：仅 permissionless OFT 直接 `send` 自伤（协议发送端 `MemeverseOmnichainInteroperation.sol::memecoinStaking` guard `receiver != address(0)`、`MemeverseSettlementImpl` 恒编码 `verse.governor`/`verse.yieldVault`，正常用户路径不可达）。行为由 `YieldDispatcher.t.sol::testLzComposeBurnsZeroReceiver`（断言 `lastBurnAmount()==amount`、`balanceOf(dispatcher)==0`）与 `YieldDispatcher.t.sol::testSettlePendingComposeBurnsForEoaReceiver` 钉住。`[代码已证]`

人工重试步骤：

> 误用警告（dispatcher 地址来源）：恢复用的 `dispatcher` **必须**取自步骤 1 的 `ComposeSent` 事件 `to` 字段。**不要**读 `MemecoinYieldVault.yieldDispatcher()`（vault 的 public storage 槽）——它是该 vault `initialize` 时绑定的快照，`reAccumulateYields` 改为参数化 dispatcher 后从不读取它，仅保留以维持 clone + initializer 存储布局。launcher 的 `setYieldDispatcher` 可在此 vault 创建后旋转 canonical dispatcher，故 compose 实际滞留的 dispatcher 可能与该槽相悖；按旧槽地址调 `reAccumulateYields` 会进错 dispatcher 的空 `composeQueue` 槽 → revert `NotDelivered`（见步骤 3 失败矩阵）。`[代码已证]`

1. 定位滞留 `message`：拉取目标链 endpoint 的 `ComposeSent` 事件（`to` = YieldDispatcherUpgradeable、`from` = asset OFT、`index` = 0），链下解码 data 区后按 `guid` 匹配，原样拷贝 `message` 字段（布局见 [docs/spec/interoperation/layerzero-oapp-oft.md §4](spec/interoperation/layerzero-oapp-oft.md)）。注意：`ComposeSent` 的 `guid`/`to`/`from`/`index` 字段均非 indexed，raw RPC `eth_getLogs` 无法按这些字段做 topic 过滤，只能按事件签名（topic0）拉取后在链下匹配 guid（或改用解码型索引器如 The Graph）。
2. 以足够 gas 调用 `reAccumulateYields(dispatcher, guid, message)`（MEMECOIN，`dispatcher` 为步骤 1 中 ComposeSent 事件的 `to`）或 `YieldDispatcherUpgradeable.settlePendingCompose(asset, guid, message)`（通用）。两个入口均 permissionless（任何地址可调，结算目标由 message 编码决定，与调用者身份无关），且均**非 payable**——附带 `msg.value` 会 EVM 层 revert（无资金滞留，与步骤 4 的 payable `lzCompose` 风险 profile 不同）
3. 成功信号：`ComposeSettled(guid, token, receiver, tokenType, amount, burnedAtDispatcher)`（`tokenType` 为消息解码的结算类型：MEMECOIN→vault / UASSET→governor）且 `composeStates[token][guid] == Released`；`burnedAtDispatcher=true` 表示 EOA receiver 分支执行了 burn 调用——实际销毁仅对实现 caller-callable 单参 `burn(uint256)` 的 token（memecoin）成立；UASSET no-code 改走 `_transferOut` 到 `protocolTreasury`——成功、emit `ComposeSettled(...,burnedAtDispatcher=false)`、槽位收敛（非 revert、非不发）；「恒 revert（事件不发）」仅对 MEMECOIN no-code + 无单参 `burn(uint256)` 的 token 成立（见上方「结算失败类」边界）；对 fallback 吸收型 token 可能静默成功而无销毁（burnedAtDispatcher=true 假报）。`false` 仅表示已发起 approve+pull 给合约 receiver（vault/governor），不保证实际拉取（fallback 吸收型 receiver 零移动）——对账时以此区分 burn 与转账，但 burnedAtDispatcher=false 仅表示 dispatcher 发起了转账动作：空 vault 的 MEMECOIN 结算在 vault 内部直接销毁（无 vault 事件），对账须结合底层 token Transfer(to=0) 核对销毁；失败则交易回滚、状态不变，查明原因（gas 不足 / token 未注册）后重试；`reAccumulateYields` 入口另有入口级失败（按代码守卫执行序排列）：message <108 字节 → `ComposeMessageTooShort`；message 内层 receiver ≠ 本 vault → `NotComposeBeneficiary`；dispatcher 无代码（EOA/空合约）→ 空数据 revert（无具名错误，核对地址是否取自 ComposeSent 事件 `to`）；dispatcher 返回零金额（壳/空实现 dispatcher）→ `ComposeSettlementFailed`；误传 staker 地址：真实 staking message → `NotComposeBeneficiary`（内层 receiver=staking 用户 ≠ vault，入口门先触发）、yield message → `NotDelivered`（staker 队列槽空）；`NotBeneficiary` 仅直连 `OmnichainMemecoinStaker.settlePendingCompose` 时出现（§3.13.1）（特例：内层 receiver 恰为 vault 的 staking 帧会经 staker settle 裸转至 vault——staker 的 msg.sender==receiver 被 vault 自洽满足，金额限发送者自身 amountLD、资金惰性滞留 vault，属自伤类）
4. 终态核验（可选但建议）：确认目标链 endpoint 的 `composeQueue` 槽位已收敛到 `RECEIVED_MESSAGE_HASH`（`ComposeDelivered` 事件已触发）——executor 若仍在重试窗口会自行收敛；若已放弃，任何人可用步骤 1 拷贝的 `message`（`index` = 0）调用 endpoint 的 `MessagingComposer.lzCompose`（permissionless、校验 `composeQueue[from][to][guid][index]` 与 `message` 哈希一致）驱动同一终态化，队列槽归位终态、executor 停止重试。调用时 `from` 传步骤 1 ComposeSent 事件的 `from`（资产 OFT 地址）、`to` 传 composer 地址（即步骤 1 的 `to` = YieldDispatcherUpgradeable）、`guid` 传步骤 1 匹配值、`index` = 0、`extraData` 传空——`from` 是校验键的一部分，误传非 OFT 地址会恒 revert `LZ_ComposeNotFound`。**调用时 `msg.value` 必须为 0**：`MessagingComposer.lzCompose` 为 payable 且把 `msg.value` 全额转发给 composer 的 payable `lzCompose`（`ILayerZeroComposer(_to).lzCompose{value: msg.value}`），而 `YieldDispatcherUpgradeable`/`OmnichainMemecoinStaker` 的 `lzCompose` 从不消费/退还 value、两合约均无 native 取回入口（无 receive/fallback/withdraw/sweep，协议不提供 onlyOwner 兜底）——误带或按 executor 惯例附带 value 将永久滞留 composer 余额。**此步骤仅当步骤 3 已成功（`composeStates==Released`）后执行**：若步骤 3 失败（`composeStates==None`）且失败原因已消除（如 UASSET token 完成治理注册），重驱动 endpoint `lzCompose` 会走**正常结算路径**（置 `Settled` + emit `OFTProcessed`、资金按 message 编码 receiver 释放、方向不变）而非仅收敛——`Settled` 为终态，此后步骤 2/3 的 settle 入口恒 revert `AlreadyResolved`，步骤 3 的 `Released`+`ComposeSettled` 成功判据永久不可达；该时序下应改回步骤 2/3 重试，勿直接执行本步骤。若重驱动 revert `LZ_ComposeNotFound`（`composeQueue` 槽已为 `RECEIVED_MESSAGE_HASH`，`keccak256(message) != RECEIVED`），表示槽已收敛到终态（已由 executor 或先前驱动执行），原子无害、无需再驱动。此步骤只补齐 endpoint 状态机终态，不改变资金结果（前提是不带 `msg.value` 且步骤 3 已成功；资金已在步骤 3 兜底结算释放）。

边界：

- `YieldDispatcherUpgradeable.settlePendingCompose` 的兜底结算语义是重跑与正向路径完全一致的结算（approve+pull 到 message 编码的 receiver：vault/governor；非合约 receiver 按 tokenType 分流：MEMECOIN → burn、UASSET → `protocolTreasury`），不是退回调用者——此“完全一致”仅对 dispatcher 成立；`OmnichainMemecoinStaker.settlePendingCompose` 语义不同（恒释放裸币、不建仓），见 §3.13.1
- 若 `lzCompose` 已成功（`composeStates[token][guid] == Settled`），重试入口 revert `AlreadyResolved`——槽位已定终态不可再次解析；已结算资金不可撤销，畸形消费（见上方边界条目）则不涉及资金移动
- `settlePendingCompose` 成功（`composeStates[token][guid] == Released`）后，若迟到的 endpoint `lzCompose` 重试到达，composer 幂等放行（no-op）：不迁移 `ComposeState`、不二次结算，让 endpoint 状态机走到 `ComposeDelivered` 终态——队列槽从 pending 收敛到 `RECEIVED_MESSAGE_HASH`，executor 停止重试；这是预期终态，资金已在 `settlePendingCompose` 兜底结算释放。若 executor 已放弃重试，任何人也可用 `ComposeSent` 事件里的 `message` 调用 endpoint 的 `lzCompose` 触发同一终态化（endpoint `MessagingComposer.lzCompose` permissionless，仅校验消息哈希；**调用时 `msg.value` 必须为 0**——composer 无 native 取回入口，附带 value 将全额转发并永久滞留，见步骤 4）。
- 若外部原因持续，资金滞留 dispatcher 直至重试成功；这是接受的韧性取舍，协议不提供单方 admin 转走资金的能力 `[代码已证]`

#### 3.13.1 跨链 staking compose 的人工重试（OmnichainMemecoinStaker）

入口：`OmnichainMemecoinStaker.settlePendingCompose(memecoin, guid, message)`。权限与 §3.13 的 dispatcher 入口相反：**仅 message 编码的接收人（receiver）本人可调**，其他地址（含运维）调用 revert `NotBeneficiary`——运维不能代办，职责是识别滞留后通知接收人本人执行；协议同样不提供 onlyOwner 恢复入口。

部署期守卫：composer 构造器拒绝零地址（`ZeroAddress()`），部署脚本对 `localEndpoint`/`MEMEVERSE_LAUNCHER`/`OMNICHAIN_MEMECOIN_STAKER`/`OUTRUN_DEPLOYER` 零配置以具名错误在部署期失败（`ZERO_LOCAL_ENDPOINT` / `ZERO_MEMEVERSE_LAUNCHER` / `ZERO_OUTRUN_DEPLOYER` / `ZERO_OMNICHAIN_MEMECOIN_STAKER`）——`ZERO_OUTRUN_DEPLOYER` 覆盖由 dispatcher 扩展至 interoperation 与 staker 部署函数（`_deployMemeverseOmnichainInteroperation` / `_deployOmnichainMemecoinStaker` 亦前置 require `OUTRUN_DEPLOYER != address(0)`）；错误配置不再静默产出不可用 composer；恢复入口语义（§3.13/§3.13.1 所述）不变。`[代码已证]`

适用时机（失败都来自外部瞬时原因，资金滞留 staker（composer）托管；本链 staking 失败是源交易回滚、不产生滞留，不在本节范围）：

- vault 已部署但 `amount` 映射 0 份额：`deposit` revert `ZeroSharesDeposit()`（份额向下取整为 0），endpoint 重试永远无法成功，须 settle 兜底释放滞留资金（见 [docs/spec/interoperation/interoperation-details.md §4.3](spec/interoperation/interoperation-details.md) 失败矩阵）。（staker 侧另对 deposit 调用结果做 amount 门控校验：非零金额 deposit 返回 0 份额（vault 变体不 revert 时）同样在 lzCompose 内 revert ZeroSharesDeposit——防「返回 0 不 revert」变体静默建仓失败、槽 Settled 封死兜底；amount==0 豁免，零金额收敛契约不变，见下方零金额边界）该指引对 receiver==staker 帧不成立：receiver==staker × `deposit` revert 时 CEI 回滚、槽回 `None`、settle 因 `NotBeneficiary` 不可达（`msg.sender` 永不为 staker 合约自身），归自伤边界，见下方「自伤自负」bullet
- 目标链 `lzCompose` 执行失败（跨链执行 gas 不足、executor 投递中断）且 LayerZero 自动重试未成功
  - 注：该条件可经 endpoint 的 `LzComposeAlert` 事件提前感知（入口与伪造风险见 §3.13 对应 bullet 注），仅作告警信号，投递证明仍以 composeQueue 哈希匹配 / `ComposeDelivered` 为准。
- `settlePendingCompose` 调用过但交易 revert（如调用者给的 gas 不足），资金仍在 staker

人工重试步骤：

1. 定位滞留 `message`：拉取目标链 endpoint 的 `ComposeSent` 事件（`to` = OmnichainMemecoinStaker、`from` = memecoin OFT、`index` = 0），链下解码 data 区后按 `guid` 匹配，原样拷贝 `message` 字段（布局同 §3.13 步骤 1）。注意：`ComposeSent` 字段均非 indexed，raw RPC 无法按 guid/to/from 做 topic 过滤，需拉取后链下匹配（见 §3.13 步骤 1 说明）。
2. 由接收人本人（非运维账户）以足够 gas 调用 `OmnichainMemecoinStaker.settlePendingCompose(memecoin, guid, message)`。该入口**非 payable**——附带 `msg.value` 会 EVM 层 revert（无资金滞留，与步骤 4 的 payable `lzCompose` 风险 profile 不同）；权限语义（仅接收人本人可调）见本节入口段
3. 成功信号：`StakingComposeSettled(guid, memecoin, receiver, amount)`（staker 变体 4 字段、无 `burnedAtDispatcher`——staker 兜底恒为转账、从不 burn）且 `OmnichainMemecoinStaker.composeStates(memecoin, guid) == Released`；失败则交易回滚、状态不变，查明原因后由接收人重试
4. 终态核验（可选但建议）：确认目标链 endpoint 的 `composeQueue` 槽位已收敛到 `RECEIVED_MESSAGE_HASH`（`ComposeDelivered` 事件已触发）——executor 若仍在重试窗口会自行收敛；若已放弃，任何人（不限于接收人）可用步骤 1 拷贝的 `message`（`index` = 0）调用 endpoint 的 `MessagingComposer.lzCompose`（permissionless、校验 `composeQueue[from][to][guid][index]` 与 `message` 哈希一致）驱动同一终态化，队列槽归位终态、executor 停止重试。调用时 `from` 传步骤 1 ComposeSent 事件的 `from`（memecoin OFT 地址）、`to` 传 composer 地址（即步骤 1 的 `to` = OmnichainMemecoinStaker）、`guid` 传步骤 1 匹配值、`index` = 0、`extraData` 传空——`from` 是校验键的一部分，误传非 OFT 地址会恒 revert `LZ_ComposeNotFound`。**调用时 `msg.value` 必须为 0**（原因与风险同 §3.13 步骤 4：误带或按 executor 惯例附带 value 将全额转发并永久滞留 staker 余额）。**此步骤仅当步骤 3 已成功（`composeStates==Released`）后执行**：若步骤 3 失败（`composeStates==None`）且失败原因已消除，重驱动 endpoint `lzCompose` 会走**正常结算路径**而非仅收敛——`Settled` 为终态，此后步骤 2/3 的 settle 入口恒 revert `AlreadyResolved`，步骤 3 的 `Released`+`StakingComposeSettled` 成功判据永久不可达；该时序下应改回步骤 2/3（由接收人本人）重试，勿直接执行本步骤。若重驱动 revert `LZ_ComposeNotFound`（`composeQueue` 槽已为 `RECEIVED_MESSAGE_HASH`，`keccak256(message) != RECEIVED`），表示槽已收敛到终态，原子无害、无需再驱动。此步骤只补齐 endpoint 状态机终态，不改变资金结果（前提是不带 `msg.value` 且步骤 3 已成功；资金已在步骤 3 兜底结算释放）；`NotBeneficiary` 权限限制仅作用于 staker 的 `settlePendingCompose` 入口，不适用于 endpoint 驱动。

语义分叉（与 §3.13 dispatcher 兜底的关键差异，对账与用户沟通必须明示）：

- staker settle **恒把裸币转给 receiver，不建仓**：`lzCompose` 正向路径在 vault 有 code 时 approve+deposit 建仓（vault 无 code 才 fallback 转账），而 `settlePendingCompose` 无条件 `_transferOut`——"重跑与正向路径完全一致的结算"仅为 dispatcher 语义，对 staker 不成立
- 一旦 settle 成功（`Released`），迟到的 `lzCompose` 被幂等放行（no-op），deposit 永不发生：该笔金额的份额、治理票（vault 为 ERC20Votes，份额即投票权）与后续收益累积永久让渡为裸余额。治理票前提：governor 按 vault 份额的资产面 votes 计票（`IVotes(yieldVault)` 传入 governor.initialize，计票面接线见 [docs/spec/governance/governance-yield-details.md §2](spec/governance/governance-yield-details.md)，memecoin 自身非 votes token）；份额持有人须先 `delegate(self)` 激活 checkpoint 才产生票权（OZ Votes 默认不自动激活，未 delegate 时 `getPastVotes` 恒为零、对 proposalThreshold/quorum 不计票）；settle 释放的裸 memecoin 非 votes token，不产生任何 governor 票——故本条「让渡」的实质是失去 vault 份额及其（经 delegate 后的）票权
- 接收人如需头寸，治理链上 vault 已部署时**在治理链本地重存零跨链费**：调 `MemeverseOmnichainInteroperation.memecoinStaking`（`govChainId == block.chainid` 走同链分支，`_transferIn` + 本地 `deposit`，不产生跨链费用）或直接向 vault `deposit`；仅当从源链重新发起时才经 `quoteMemecoinStaking` / `memecoinStaking` 重新支付跨链费
- 边界（与 §3.13 有差异）：零金额 payload 在 settle 入口以 `ZeroInput` 拒绝；与 dispatcher 不同，staker 的 `lzCompose` 对零金额不设检查——vault 有 code 且 `asset() == memecoin` 时 `deposit(0)` 提前返回、无 code 时 `_transferOut(0)` no-op，均成功置 `Settled` 并收敛 endpoint 状态机（`asset()` 失配或不可读的命名 vault 不在此列：绑定守卫无金额检查、先于 `deposit`，零金额帧同样 revert、CEI 回滚不收敛，见「vault 有 code 但 `asset()` 不可读」边界条目），故"槽位恒 `None` 且无清理入口"仅在 `lzCompose` 始终未执行时成立；`Settled`/`Released` 后重复结算 revert `AlreadyResolved`；`Released` 后迟到的 endpoint `lzCompose` 由 composer 幂等放行、endpoint 状态机正常收敛到 `ComposeDelivered`
- 边界（畸形 composeMsg，两入口不对称：建仓严格 / 释放宽松）：两入口均先校验帧长 ≥ 76 字节（`OmnichainMemecoinStaker.sol::lzCompose` 帧长守卫、`verifySettle`，OFT compose header 完整、内层 composeMsg 切片不会越界），但对内层 composeMsg 长度的守卫不对称——(1) `lzCompose`（**建仓路径**）保持 `composeMsg.length == 64` 严格守卫：长度 ≠ 64 即 revert `MalformedComposeMsg`，原子回滚 CEI 置位（`Settled` 写入回滚、guid 仍为 `None`），endpoint 可重试或受益人改走 settle（长度 ≥ 32 时受益人可改走 settle；< 32 字节帧两入口均具名拒绝）；对长度恰为 64 字节的帧不再裸 `abi.decode`——本次修复改为固定偏移 word 解析（receiver = 首 32 字节、yieldVault = 次 32 字节）并显式校验干净 160 位：(i) receiver word 高位脏（`>> 160 != 0`）→ 帧被**消费**：CEI 先写 `Settled`、emit 新的 staker 事件 `ComposeRejected(bytes32 indexed guid, address indexed memecoin, uint256 amount)` 后 return——endpoint 队列收敛、executor 停止重试，资金滞留 staker 托管（自伤边界，与 §3.13 dispatcher 畸形帧消费同哲学；settle 入口对同一脏 receiver 帧也具名拒绝 `MalformedComposeMsg`，故该帧无任何恢复出口）；(ii) receiver word 干净、vault word 高位脏 → 视同 vault 缺失：走 `_transferOut` fallback 释放给干净 receiver（同 vault 未部署分支），emit `OmnichainMemecoinStakingProcessed`（yieldVault = address(0)）；(iii) 两 word 均干净 → 既有 vault 有 code / 无 code fallback 分支不变。(2) `settlePendingCompose`（**裸币释放路径**）放宽为 `composeMsg.length >= 32`（`OmnichainMemecoinStaker.sol::settlePendingCompose` 的 `composeMsg.length >= 32` 守卫），取 composeMsg 首 32 字节作 receiver、校验干净 address（`receiverWord >> 160 == 0`，防脏高位截断成伪地址）后释放，只解码首 word（`abi.decode(composeMsg, (uint256))`）、丢弃 yieldVault 及尾部字节（首 word 即 receiver slot；无论后续字节是否存在或为多少，一律忽略，仅校验首 word 高 12 字节为零）。不对称的语义依据：建仓需 `(receiver, yieldVault)` 双字段才能 deposit 进 vault；而 settle 恒 `_transferOut`、从不碰 yieldVault（settle 以 `abi.decode` 读首 word 作 receiver，从不读取 vault word），只需 receiver 单字段故 `>= 32` 足够——这不是疏漏。受益人本人可回收：message 经 endpoint `composeQueue` 哈希绑定 guid，第三方无法注入或篡改；`require(msg.sender == receiver, NotBeneficiary())`（`OmnichainMemecoinStaker.sol::settlePendingCompose` 的 `msg.sender == receiver` 检查）保证只有该受益人能取，不影响他人。仍 revert 的子情形（均指非零金额帧——零金额帧在 settle 入口先于长度守卫 revert `ZeroInput`）：内层 composeMsg < 32 字节（首 word 取不到，settle 仍 revert `MalformedComposeMsg`）；receiver == `address(0)`（见下一条边界，`msg.sender` 永不为 0，不可达）；receiver 高位脏（`>> 160 != 0`，settle 仍 revert）。内层 < 32 字节（帧 < 108）是无任何收敛/恢复出口的死类：lzCompose `== 64` 与 settle `>= 32` 两入口均具名拒绝、endpoint 队列槽永久 pending（`ComposeDelivered` 永不触发、executor 重试恒失败）、资金永久滞留 staker 托管（receiver=0 与 receiver 高位脏两子情形同样无恢复出口，见上文与下一条边界）。与 dispatcher 对同一帧类的消费收敛策略相反系有意取舍：staker 对长度畸形帧 revert 而非消费，保住 ≥ 32 内层帧经 settle 恢复裸币的通道（消费置 `Settled` 会以 `AlreadyResolved` 封死该出口），并让自伤类保持 revert 的响亮可观测（receiver=0 同哲学）。注：本条仅指 composeMsg 长度畸形；`lzCompose` 因 `TokenVaultMismatch`（真实 token + 命名 vault 的 `asset()` 不匹配，`OmnichainMemecoinStaker.sol::lzCompose` 的 `asset()` 校验）revert 的帧不受影响——settle 从不校验 `asset()`、恒 `_transferOut`，对该类帧始终成功，与本条的 `>= 32` 放宽无关。安全不变量：放宽不扩大攻击面——只有发送畸形 payload 的受益人本人能取回自己的钱。`[代码已证]`
- 边界（命名 vault 有 code 但 `asset()` 不可读——缺失/主动 revert/OOG，自伤类）：建仓分支的绑定守卫 `require(IMemecoinYieldVault(yieldVault).asset() == memecoin, TokenVaultMismatch())`（`OmnichainMemecoinStaker.sol::lzCompose`）仅在命名合约**实现了 `asset()` 且返回字可读**时才能给出具名错误 `TokenVaultMismatch`；自伤 `send` 命名任意有 code 合约作为 vault word 时，`asset()` 外部调用失败模式随被命名合约而异，`TokenVaultMismatch` 均不触发：(1) 缺失——合约无 `asset()` selector 且无 fallback 时按 solc 语义以**空 returndata** revert（无具名错误；与 §3.13 dispatcher 侧记录的空数据 revert 语义同源）；(2) 主动 revert——被命名合约自身错误/原因原样上抛（仍非 `TokenVaultMismatch`）；(3) OOG——`asset()` 死循环/超长循环在 EIP-150 下经 STATICCALL 最多转发 63/64 剩余 gas、可将其耗尽后以 OOG 失败（空数据）。三类均使整个 `lzCompose` 回滚：CEI `Settled` 写入回滚、guid 回 `None`、endpoint 队列 pin、executor 重试恒失败，且失败无 staker 具名错误可 grep——运维按本矩阵其它条目无法对号入座，应结合 endpoint 队列 pending 与 `LzComposeAlert` 判定并走本节 settle 兜底。恢复面不受损：`settlePendingCompose` 从不读取 vault word（只取首 word 作 receiver）、恒 `_transferOut` push，对该类帧始终成功（与 `TokenVaultMismatch` 帧同，见上条畸形条目末注）；守卫无金额检查、先于 `_safeApprove`/`deposit`，零金额 × 该类帧同样 revert、不收敛（见零金额边界条目限定语）。`[代码已证]`

跨 composer 判定：dispatcher 侧对内容可解析的 >64 帧两入口一致结算（尾部忽略，见 §3.13），staker 侧 `lzCompose` 保持 ==64 严格拒绝（CEI 回滚、槽 `None`、受益人可经 settle ≥32 恢复裸币）——跨 composer 判定不一致为有意保留（staker 建仓需 `(receiver, yieldVault)` 双字段；dispatcher 兜底=重跑正向完整结算），监控/对账须按 composer 区分可观测类：dispatcher >64 帧发 `OFTProcessed`/`ComposeSettled`，staker >64 帧 `lzCompose` revert `MalformedComposeMsg`（无事件、槽 `None`）。
- 边界（部分拉取/0 拉取 vault，余量滞留自伤有界）：消息指名的 vault 在 deposit 内只拉取部分（或 0）金额但返回非零份额时，`lzCompose` 照常置 `Settled` 并 emit `OmnichainMemecoinStakingProcessed(guid, memecoin, yieldVault, receiver, amount)`——amount 为投递金额、不保证实际拉取额，对账须以 vault 侧余额/事件变动为准；未被拉取的余量滞留 staker 托管且无恢复出口（槽 `Settled` 封死 `settlePendingCompose` 的 `AlreadyResolved`）。staker 侧在 deposit 后已清零精确 approve 残留（`_safeApprove(..., 0)`），此类 vault 无法借残留额度事后盗取他人滞留资金；单笔拉取有界于该 compose 金额，vault 与 receiver 均为发送者自选（自伤自负，协议不设防），与「自引用帧」「receiver==0」同哲学。`[代码已证]`
- 边界（receiver == address(0)，自伤永久锁死）：当某笔跨链 staking compose 的 `message` 内层 composeMsg 解码出的 `receiver` 恰为 `address(0)`（协议发送端 `MemeverseOmnichainInteroperation.sol::memecoinStaking` 已 guard `receiver != address(0)`，故正常用户路径不可达；仅持币人经 permissionless OFT `send` 自行伪造 encode(address(0), vault) 的 composeMsg 才会进入 staker 队列，属自伤），该笔资金（非零金额帧）**零出口、永久滞留 staker 托管**：(1) `settlePendingCompose` 的 `require(msg.sender == receiver, NotBeneficiary())` 对 receiver=0 恒不可满足——EVM 中 `msg.sender` 永不为 `address(0)`，故该 auth 永久 revert；(2) 先声明：该断言仅对非零金额帧成立；amount > 0 子档：fallback 分支 `_transferOut(memecoin, 0, amount)` 经外部 `transfer(0)` 触发 `OutrunERC20Init.sol::_transfer` 零地址守卫（`ERC20InvalidReceiver`）；vault 有 code 分支 `deposit(amount, 0)` 先经 `_convertToShares`——金额映射 0 份额（大 vault + 尘额桥接）时先 revert `ZeroSharesDeposit`（先于零地址守卫），映射非零份额时才经 `_mint` 零账户守卫 revert `ERC20InvalidReceiver`。两类均整体回滚：跨链供应量从未减少、CEI `Settled` 写入回滚、guid 回 `None`、endpoint 无限重试恒 revert（不收敛）；amount == 0 子档：fallback 分支 `_transferOut(memecoin, 0, 0)` 在 TokenHelper.sol::_transferOut 早退（先于零地址守卫）、vault 有 code 且 `asset()` 匹配分支的 `deposit(0, address(0))` 在 MemecoinYieldVault.sol::deposit 早退（先于 `_convertToShares` 与 `_mint`）——两子路径均无资金移动、`Settled` 保留、emit `OmnichainMemecoinStakingProcessed`、endpoint 收敛 `ComposeDelivered`（与 §3.13 零金额收敛契约一致）；命名 `asset()` 不匹配真实 vault 的零金额 × receiver=0 帧仍先 revert `TokenVaultMismatch`（该守卫无金额检查、先于 deposit）、CEI 回滚不收敛；链下监控对零金额 × receiver=0 帧（vault 无 code 或 `asset()` 匹配子档）应归零金额收敛类，不应按本条目矩阵判「永久锁死」；(3) 与畸形 composeMsg 自伤边界（上一条）同源，协议**不为此提供 onlyOwner 回收入口**。唯一恢复路径是从发送端杜绝：用户经 `memecoinStaking` 正常入口发送时 `receiver != address(0)` 已被 guard，不会触发。`[代码已证]`
- 边界（receiver 为 staker 自身地址或任意非零地址，自伤自负）：自引用帧不再被守卫拦截——receiver 填 staker 自身地址（或任意非零地址）时，fallback 分支自转 no-op、vault 有 code 分支份额 mint 给该 receiver，均照常置 `Settled` + emit `OmnichainMemecoinStakingProcessed`、endpoint 收敛，与把 receiver 填成任意无出口地址（如 0xdead）同责，协议不设防；仅保留 receiver == `address(0)`（响亮 revert、槽 pinned，见上条）与 receiver 高位脏（`ComposeRejected` 消费）两条硬边界，发送者自选 receiver、自伤自负。另：receiver==staker 且 vault 有 code 时走 deposit 分支，若 deposit revert（如份额向下取整为 0 的 `ZeroSharesDeposit`、伪造 vault 的 `TokenVaultMismatch`、恶意 vault 主动 revert），CEI 的 `Settled` 写入随交易回滚、槽回 `None`、endpoint 队列永久 pending（executor 恒重试恒失败），settle 兜底不可达（`NotBeneficiary` 对 receiver==staker 恒不可满足——`msg.sender` 永不为 staker 合约自身）——归入文档化的「结算失败类」自伤边界（见 §3.13），协议不设防。`[代码已证]`
- 边界（receiver 为合约，恢复入口要求其自身可发起调用）：`settlePendingCompose` 的 `require(msg.sender == receiver, NotBeneficiary())`（`OmnichainMemecoinStaker.sol::settlePendingCompose`）要求 receiver **自身**发起调用，故合约 receiver 能否兜底恢复取决于其是否具备自调用路径——可自调用合约（Safe 类智能钱包经 owner 授权执行、vault 等实现相关调用面的合约）可正常 settle；无任意调用路径的合约（无 owner 可触发函数的托管/锁定合约等）在 `lzCompose` 永久失败类（如 `ZeroSharesDeposit`，见本节「适用时机」首条）下 settle 恒 `NotBeneficiary`、资金滞留 staker 托管、零恢复出口（协议无 onlyOwner 回收入口）——与 §3.13「结算失败类」(a)（dispatcher 侧合约 receiver 无回调实现 → 结算恒失败）同哲学。正向路径不受影响：合约 receiver 在 `lzCompose` 建仓（vault `deposit` mint 份额）与 vault 缺失 fallback（`_transferOut` 直转）两分支均正常。运维识别滞留后按本节约定通知接收人本人执行时，须先确认该 receiver 具备自调用能力；不具备者归自伤边界（发送者自选 receiver，只能从发送端选择上杜绝，与「自伤自负」条目同哲学），协议不提供代办或代执行入口。`[代码已证]`

#### 3.13.2 compose 执行 gas 预算与最小推荐值

跨链 compose 的执行 gas 预算由发送端 compose options 注入（staking 路径 `addExecutorLzComposeOption(0, omnichainStakingGasLimit, 0)`，`MemeverseOmnichainInteroperation`；yield 路径 `addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0)`，`MemeverseSettlementImpl`）。该预算必须覆盖目标链 `lzCompose` 主体（endpoint 哈希校验 + RECEIVED sentinel 写入之后、成功事件之前的全部开销）外加 endpoint wrapper 固定开销 + EVM 21k intrinsic + tx calldata + 首触地址/槽的冷访问附加费；若配低于实际峰值，目标链 `lzCompose` 恒 OOG、executor 重试恒失败、endpoint 队列 pin，受益人被迫走 §3.13/§3.13.1 settle 兜底（staker 恒裸币不建仓、yield 路径 permissionless）成为常态而非异常——无资金损失，但 UX 降级。

与 compose 面不同，**receive 面没有 settle 兜底**：staking 发送路径的 receive 预算由 `addExecutorLzReceiveOption(oftReceiveGasLimit, 0)`（`MemeverseOmnichainInteroperation`，`_buildStakingSendParam`）注入，覆盖治理链 memecoin OFT `lzReceive`（mint）主体；若配低于实际峰值，executor 投递恒 OOG、重试恒失败、endpoint 队列 pin——源链 OFT `_debit` 已 burn、目标链未 mint，且 `settlePendingCompose` / `reAccumulateYields` 只覆盖 compose 面（消息未送达时 compose 不会入队），协议内无自动恢复、无 settle 兜底；**但资金不丢失**——投递本身免许可：`EndpointV2.lzReceive` 无调用者限制（option gas 仅封顶 executor 尝试，`Executor` 调用处注入、链上不强制），任何人可持消息字节（源链 `PacketSent` 事件）以自己的 tx gas 调 `EndpointV2.sol::lzReceive(origin, receiver, guid, message, extraData)` 完成 OFT `lzReceive`（mint + sendCompose；调用时 `msg.value` 必须为 0——`EndpointV2.lzReceive` 会把 value 全额转发给 OFT 的 payable `lzReceive`，OFT 不消费/退还、无 native 取回入口，误带永久滞留，同 §3.13 步骤 4 value 警示），与 §3.13 免许可 `lzCompose` 重驱动同类（同一 (receiver, srcEid, sender) 路径上已通过 DVN 验证的消息可按任意次序投递——`_clearPayload` 仅要求把 `lazyInboundNonce` 前推到目标 nonce 时区间内消息的 payload hash 槽均非空（未验证即槽为空），先投后序会把 lazy 前推、前序之后仍可投递；`LZ_InvalidNonce` 只在区间内存在 payload hash 槽为空的 nonce（即该消息从未验证）时触发，与投递次序无关；被消费（含 OApp `clear`）的消息已随 lazy 前推至区间外，重投只 revert `LZ_PayloadHashNotFound`）。故误配后果 = 滞留至人工介入（可用性/运维负担），非永久丢失。`setGasLimits` 对两参仅校验 `> 0`、不设最小执行预算，故调低 `oftReceiveGasLimit` 属 owner 误配类风险：任何下调必须按与本节相同的实测方法论留足余量（正向路径 receive 主体 + endpoint wrapper 固定开销 + EVM 21k intrinsic + calldata + 冷访问尾；本表仅列 compose 面实测，receive 面主体须按同法另行测量后再定值），不得以低于该和的量配置。yield 路径 receive 预算（`MemeverseLauncherUpgradeable.setGasLimits` 第一参，`MemeverseSettlementImpl` 的 `addExecutorLzReceiveOption`）同构、同样无兜底；其 compose 面（第二参）OOG 则可经 §3.13 settle 恢复（yield 路径 permissionless），无资金损失。

最小推荐值以下表实测为基准。测量由 `test/interoperation/LzComposeGasBenchmark.t.sol`（`gasleft()` 前后差，仅计 `lzCompose` 主体、不计 endpoint wrapper）给出，采用**暖状态模型**：基准测试在测量前对 vault/governor 做一次预结算以把生产中长期暖的存储槽（`totalAssets`、checkpoint、share 余额、allowance、dispatcher 托管余额）预热至 EIP-2929 暖价，被测 guid 的 compose-state 槽保持新建（与生产每个 guid 仅 resolve 一次一致）。直接对全新 clone vault 测量会因冷槽附加费高估约 3.4×（staker deposit 分支冷测 ~268k vs 暖测 ~79k，268/79≈3.4），故必须按暖状态读数。

| composer / 分支 | 暖状态实测主体 gas | 脚本默认预算 | 判定 |
|---|---|---|---|
| staker deposit（vault 有 code：`asset()` + `_safeApprove`×2 + `deposit`）| ~79000 | `omnichainStakingGasLimit`=135000（`MemeverseOmnichainInteroperation` 构造器第 6 参，`script/MemeverseScript.s.sol`）| 足够（余量 ~56k 覆盖 endpoint wrapper + 冷访问尾） |
| staker fallback（vault 无 code：`_transferOut` 直转）| ~64000 | 135000 | 足够 |
| dispatcher MEMECOIN（`asset()` 绑定 + `accumulateYields` pull）| ~61000 | `yieldDispatcherGasLimit`=135000（`MemeverseLauncherUpgradeable.initialize` 第 11 参）| 足够（见下保真度注；mock 下界，真实 vault 主体约 +25-35k checkpoint 写，仍 < 135000） |
| dispatcher UASSET（`receiveTreasuryIncome` pull）| ~60000 | 135000 | 足够（见下保真度注；mock 下界，真实 governor 主体约 +15-25k incentivizer 转发，仍 < 135000） |
| dispatcher EOA-burn（MEMECOIN `burn` 直销）| ~38000 | 135000 | 足够 |

保真度注（dispatcher 行 vs staker 行）：staker deposit 行用**真实** `MemecoinYieldVault` minimal-proxy clone 测量，主体 gas 准确反映生产（`deposit` 内部 `_writeTotalAssetCheckpoint` + `_mint` 全计入）。dispatcher 三行用 **mirror mock receiver**（`GasVault.accumulateYields`/`GasGovernor.receiveTreasuryIncome` 仅做 `transferFrom` + 轻量记账，见 `test/interoperation/LzComposeGasBenchmark.t.sol`），**不含**真实 vault 的 `_accumulateYield` → `_writeTotalAssetCheckpoint`（OZ checkpoint push：length SLOAD + 数据 SSTORE + clock SLOAD + SafeCast，约 +25-35k）与真实 governor 的 `recordTreasuryIncome` 外部转发到 incentivizer（2×require + SLOAD + SSTORE + emit，约 +15-25k）。故 dispatcher 行是 mock 下界，真实 dispatcher 主体比表中高约该量；即便按保守上沿（MEMECOIN ~96k / UASSET ~85k）仍 < 135000 默认预算，结论不变。若需 dispatcher 行直接反映生产，可后续把 mirror mock 换成真实 vault + 真实 governor（需 incentivizer fixture）重测。

部署 readiness：脚本默认值（`omnichainStakingGasLimit`=135000、`yieldDispatcherGasLimit`=135000）在暖状态下均覆盖实测主体（含 dispatcher 行 mock 下界的保守上沿修正）且有舒适余量，**当前默认无需上调**。运行时调参两入口均 onlyOwner：staking 路径 `MemeverseOmnichainInteroperation.setGasLimits`（第一参 `oftReceiveGasLimit` 为 receive 面预算——调低无协议内兜底、消息滞留需免许可手工重放投递恢复，见本节上方警告；第二参 `omnichainStakingGasLimit` 为 compose 面预算）、yield 路径 `MemeverseLauncherUpgradeable.setGasLimits`（第一参 receive 面同构无兜底；第二参 `yieldDispatcherGasLimit` 为 compose 面预算）——若未来代码改动使某分支主体接近预算上限（基准测试 `assertLt` 失败即信号），经对应入口上调部署 gas 值，不得在未重测下放宽上限。本表数字随代码变更重测后更新。

边界（自伤 forge 路径的不可信 `asset()` 消耗面）：staker deposit 分支的 `asset()` STATICCALL 位于协议发送端恒编码真实 `verse.yieldVault` 的正向路径，故正常跨链 staking 不可达不可信 vault；但持币人经 permissionless OFT `send` 自伤伪造（命名任意有 code 合约为 vault word）可达——此时被命名合约的 `asset()` 在 EIP-150 下经 STATICCALL 最多转发 63/64 剩余 gas、可耗尽后以 OOG 失败。该面**不可由任何静态 gas 快照给出上界**（消耗由被命名合约控制），已作为自伤类边界记录于 §3.13.1「命名 vault 有 code 但 `asset()` 不可读」条目；恢复面不受损（`settlePendingCompose` 从不读 vault word、恒 `_transferOut` push）。脚本默认预算的余量覆盖正向路径（vault 协议控制，`asset()` 恒为真实 vault 的轻量 view）；该自伤对抗面不构成跨用户风险（自伤发送者只能困住自己的钱），故最小推荐值不为该面额外上调，部署方亦不应据此下调。

## 4. 治理周期相关操作语义

- `finalizeCurrentCycle()` 是对外开放入口，时间到即可执行，不要求 `onlyGovernance`。`[代码已证]`
- `syncTreasuryBalance()` 是对外开放的整额对账入口，把当前周期 treasury ledger 重设为 `max(governor 实际托管余额 - 上一周期未领 reward 储备, 0)`；synced 值由真值确定性导出，调用者无法控制，不转移 token，不要求 `onlyGovernance`。`[代码已证]`
- `claimReward()` 是用户自领入口，以 `msg.sender` 为 reward owner，不要求 `onlyGovernance`。`[代码已证]`
- `accumCycleVotes()`、token 注册/注销、reward ratio 修改等由 governor 路径调用（`onlyGovernance`）。`[代码已证]`

## 5. 观察与告警建议（最小集）

- 阶段机：`ChangeStage` + `RegisterMemeverse`
- 资金分发：`RedeemAndDistributeFees`、`OFTProcessed`
- 跨链 staking：`OmnichainMemecoinStaking`、`OmnichainMemecoinStakingProcessed`
- 兜底结算（compose 失败人工重试，§3.13）：`ComposeSettled`（YieldDispatcherUpgradeable）/ `StakingComposeSettled`（OmnichainMemecoinStaker）
- 畸形 compose 消费：`ComposeRejected(guid, token, amount)`——不可结算的 compose payload 被消费（置 `Settled`、不结算）的信号，用于监控发送端畸形/自伤消息与对账。两个 composer 同签名发出：`YieldDispatcherUpgradeable`（畸形内层 composeMsg 解析失败，或干净可解析帧 receiver == dispatcher 自身地址的自引用帧——见 §3.13 自引用类）与 `OmnichainMemecoinStaker`（64 字节帧 receiver word 高位脏）。receiver 非自引用的内容可解析 >64 帧不触发 ComposeRejected：dispatcher 正常结算（发正向/兜底事件），staker `lzCompose` 长度守卫 revert `MalformedComposeMsg`（无事件、槽 None）。
- 配置变更：Launcher/Hook/RegistrationCenter 的 `Set*` 事件

## 6. EVM 兼容性要求

- 部署链必须支持 **Cancun 硬分叉（EIP-1153 transient storage）** 或更新版本（Prague）。`[代码已证]`
- 编译目标：`foundry.toml` 中 `evm_version = "prague"`，`pragma solidity ^0.8.35`。编译器对 `transient` 关键字生成 `tload`/`tstore` 操作码，部署到 pre-Cancun 链上将导致所有涉及 `nonReentrant` 修饰符的函数直接 `invalid opcode` 回退。`[代码已证]`
- 受影响合约及使用点：
  - `ReentrancyGuard.nonReentrant`（`src/common/access/ReentrancyGuard.sol`：`bool private transient locked`）
  - `TokenHelper._transferOut`（`src/common/token/TokenHelper.sol::_transferOut`）
  - `MemeverseLauncherUpgradeable` 继承 `TokenHelper`（`src/verse/MemeverseLauncherUpgradeable.sol`）
  - `POLendUpgradeable` 直接继承 `ReentrancyGuard`（`src/polend/POLendUpgradeable.sol`）
  - `POLSplitterUpgradeable` 直接继承 `ReentrancyGuard`（`src/polend/POLSplitterUpgradeable.sol`）
  - `MemeverseUniswapHookUpgradeable` 直接继承 `ReentrancyGuard`（`src/swap/MemeverseUniswapHookUpgradeable.sol`）
- 行业对齐：OpenZeppelin v5.5+ 的 `ReentrancyGuardTransient` 同样声明 "This variant only works on networks where EIP-1153 is available"，v6.0 将把 transient 实现作为唯一 `ReentrancyGuard` 实现。本项目的自研 `ReentrancyGuard` 与 OZ 方向一致。`[代码已证]`
- `[未知]` 不在此文档范围内的目标链 Cancun 支持状态，需由部署方在部署前确认。

## 7. 确定性边界

- `[未知]`：生产环境 keeper 调度频率、告警阈值、重试策略、密钥托管方案，不在仓库代码内。
