# MemeverseV2 配置矩阵

## 1. 说明

标签说明：

- `[代码已证]`：当前代码可直接验证
- `[目标规范]`：目标产品规则（可能尚未在代码实现），全局约定见 [README.md](../README.md)
- `[未知]`：仓库内没有部署级最终值

## 2. 代码可配置面（当前真实生效）

| 模块 | 参数 | 写入方式 | 主要约束 | 作用范围 | 来源 |
| --- | --- | --- | --- | --- | --- |
| `MemeverseLauncherUpgradeable` | `memeverseSwapRouter` | `setMemeverseSwapRouter` | 非零；set-time 三重校验与 `Genesis -> Locked` launch-time preflight 见 [docs/spec/invariants.md](../invariants.md) INV-04 | 启动建池、公开 router、preorder 结算 hook 绑定 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `memeverseUniswapHook` | `setMemeverseUniswapHook` | 非零；write-once（首次设置后 `revert HookAlreadyConfigured()`），完整绑定约束见 [docs/spec/invariants.md](../invariants.md) INV-04 | preorder 显式结算 + post-unlock 保护写入绑定 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `lzEndpointRegistry` | `initialize(...)` | 非零；初始化后不可变更（无 setter） | 注册 peer 配置、跨链 endpoint 映射 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `memeverseRegistrar` | `setMemeverseRegistrar` | 非零 | 注册入口权限边界 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `memeverseProxyDeployer` | `setMemeverseProxyDeployer` | 非零 | per-verse token/vault/governor 部署 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `polend` | `initialize(...)` | 非零；当前代码没有 runtime setter | Launcher 保存 `POLendUpgradeable` 接线地址；注册同交易内调用 `POLendUpgradeable.registerLendMarket(verseId)`；`Genesis -> Locked` 时若有杠杆债务则调用 `finalizeLeveragedGenesis(verseId)`；`Locked -> Unlocked` 的 unlock settlement 中按需调用 `executeGlobalSettlement(verseId)`；同一地址还承担 `getTotalLeveragedDebt/Interest`、`preRedeemPTFee`、settlement dust reserve 等查询/执行依赖 | `[代码已证]`，其更细四池语义见 [docs/spec/polend/README.md](../polend/README.md) |
| `MemeverseLauncherUpgradeable` | `polSplitter` | `initialize(...)` | 非零；当前代码没有 runtime setter | Launcher 保存 `POLSplitterUpgradeable` 接线地址；`Genesis -> Locked` 时调用 `initializeVerse`、记录 PT backing ratio、执行 `split`；normal fee 与 governor PT fee 的 preview/redeem 都依赖该地址；`Locked -> Unlocked` 的 unlock settlement 中先调用 `settle(verseId)`，settled 后普通 PT fee 与 governor PT fee 都改走 `redeemPT -> uAsset` 口径 | `[代码已证]`，其更细四池语义见 [docs/spec/polend/README.md](../polend/README.md) |
| `MemeverseLauncherUpgradeable` | `yieldDispatcher` | `setYieldDispatcher` | 非零 | 本地费用分发落地 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `fundMetaDatas[uAsset] = {minTotalFund,fundBasedAmount}` | `setFundMetaData` | 两者非零；`fundBasedAmount <= MAX_FUND_BASED_AMOUNT`，其中 `MAX_FUND_BASED_AMOUNT = 2^64-1`；派生值 `minTotalFund × fundBasedAmount × 7 / 1000 > 0`（等价 `minTotalFund × fundBasedAmount >= 143`，否则治理链 deploy vault 时 `YieldVault.initialize` revert `ZeroVirtualAssets`）；两者均为 raw-unit 口径：`minTotalFund` 按该 uAsset 自身 `decimals()` 解释（见 `docs/spec/polend/genesis.md:113`），`fundBasedAmount` 为 memecoins per raw unit，6-dec 与 18-dec 资产同经济目标需差 1e12 校准；非 credit 路径支持任意 decimals，credit 路径仅 18（见本表 `supportedUAssets` 行与 `GenesisCreditFactory.sol:68-69`） | Genesis 达标判断、首发 memecoin 量与初始价格；该两字段同时作为 `MemecoinYieldVault` 虚拟资产缓冲（`virtualAssets`）推导输入（推导规则与 0.7% 系数见 §3）；全局活读配置（无 per-verse 快照、无版本化；注册时仅校验非零），owner 变更立即影响已注册未 `Locked`（Genesis 期）verse，为预期语义（详见本表下方「注」） | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `executorRewardRate` | `setExecutorRewardRate` | `< 10000` | fee 分账（执行者奖励） | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `preorderCapRatio`,`preorderVestingDuration` | `setPreorderConfig` | 非零；`capRatio <= 10000` | preorder 容量和线性释放 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | `oftReceiveGasLimit`,`yieldDispatcherGasLimit` | `setGasLimits` | 两者 `>0`；第一参（receive 面）误配后果同 `MemeverseOmnichainInteroperation` 行（无兜底、滞留至免许可重放投递，详见 operations.md §3.13.2） | 远端分发 OFT options | `[代码已证]` |
| `MemeverseRegistrationCenterUpgradeable` | `supportedUAssets` | `setSupportedUAsset` | uAsset 非零；uAsset 必须为无外部回调语义的 plain ERC20（`transfer` / `transferFrom` / `approve` / `mint` / `repay` 不得触发任意外部回调），违反者不属于协议支持范围，信任边界权威定义见 [docs/spec/polend/settlement-and-fees.md §9.1](../polend/settlement-and-fees.md)——回调型 uAsset 会使 swap 侧 `MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore` 的 LP per-share 会计重入窗口条件可达；普通 `genesis` / `leveragedGenesis` 支持任意 decimals 的 `uAsset`，但 GenesisCredit credit path（`POLendUpgradeable.sol::leveragedGenesisWithCredit` + `GenesisCreditFactory.sol::deployCredit`）只支持 `uAsset.decimals() == 18`，非 18-dec `uAsset` 不得部署 GenesisCredit `[代码已证]`（`InvalidUAssetDecimals` / `CreditDecimalsMismatch` 已在 `GenesisCreditFactory.sol::deployCredit` 与 `POLendUpgradeable.sol::leveragedGenesisWithCredit` 双处落地） | 注册可用募资币种白名单，仅做成员资格门控（`MemeverseRegistrationCenterUpgradeable.sol::_registrationParamValidation`），token-kind 前置由治理配置与部署流程共同保证（权威定义见 §9.1） | `[代码已证]`（credit path 18-dec 校验已在 `GenesisCreditFactory.sol` / `POLendUpgradeable.sol` 双处落地） |
| `MemeverseRegistrationCenterUpgradeable` | `min/maxDurationDays` | `setDurationDaysRange` | 非零，且 min < max | 注册 durationDays 校验 | `[代码已证]` |
| `MemeverseRegistrationCenterUpgradeable` | `registerGasLimit` | `setRegisterGasLimit` | `>0` 且 <= uint128 max（上界防 options 构造处 uint128 截断，超出 revert InvalidInput） | center 向远端 registrar fan-out 的 receive gas | `[代码已证]` |
| `MemeverseRegistrationCenterUpgradeable` | `memeverseRegistrar` | `setMemeverseRegistrar` | 非零 | 本链注册分发与 `_lzReceive` origin 校验指针；更换须与逐 eid `setPeer` 成对操作（见 operations.md §3.1.2） | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | `registrationCenter` | `setRegistrationCenter` | 非零 | 本地 registrar 信任中心地址 | `[代码已证]` |
| `MemeverseRegistrarOmnichain` | `registrationGasLimit`（base/local/omnichain） | `setRegistrationGasLimit` | owner-only（数值不做额外边界） | remote registrar -> center 的 quote/send gas 预算 | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `treasury` | `setTreasury` | 非零 | protocol fee 接收地址 | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `supportedProtocolFeeCurrencies[currency]` | `setProtocolFeeCurrency(Currency,bool)` | owner-only | 协议费代币注册表（控制收费腿、不门控是否收费；详见 uniswap-v4.md §3） | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `launcher` | `initialize`（一次性） | 非零；由 initialize 一次性固化（initializer write-once），不可 retarget，与 launcher 侧 `setMemeverseUniswapHook` write-once 对称 | preorder settlement 授权 + pair-based `setPublicSwapResumeTime` 写入权限绑定 | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `defaultLaunchFeeConfig={start,min,decaySeconds}` | `setDefaultLaunchFeeConfig` | 全部非零；`min<=start<=10000` | 启动窗口费率衰减 | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable`（Router 直接实现） | `referrerRebateBps` | `setReferrerRebateBps`（hook `onlyOwner` 直接写 hook storage `referrerRebateBps`） | `<= FeeMath.PROTOCOL_FEE_SHARE_BPS`（即 `<= 3500`），否则 revert `RebateExceedsProtocolShare` | 返佣率（占总 fee bps）；`initialize` 默认 `1000`（10%） | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `swapFacet` / `dynamicFeeFacet` / `settlementFacet` | `setFacet(bytes32 role, address facet)` | `onlyOwner`；`facet != address(0)`（`ZeroAddress`）；`facet` 有字节码（`FacetCodeNotReady`）；`facet` 的 immutable `poolManager` 与 hook 一致（`FacetPoolManagerMismatch`，getter 不可读时 `FacetPoolManagerUnreadable`，校验逻辑同 `_authorizeUpgrade`）；`role ∈ {SWAP_FACET_ROLE, DYNAMIC_FEE_FACET_ROLE, SETTLEMENT_FACET_ROLE}`，否则 revert `UnknownFacetRole`；非法 `role` 与 invalid facet 并存时，facet code/manager 错误优先于 `UnknownFacetRole` | 全局单例 pointer，替换后所有已建/新建池的对应 v4 回调立即走新 facet（与 `lpTokenImplementation` 只影响后续新池不同，见 [upgradeability.md](../upgradeability.md)）；emit `FacetUpdated(role, old, new)` | `[代码已证]` |
| `MemeverseOmnichainInteroperation` | `oftReceiveGasLimit`,`omnichainStakingGasLimit` | `setGasLimits` | 两者 `>0`（无最小执行预算下限）；误配后果：`oftReceiveGasLimit` 低于目标链实际执行预算 → 治理链 memecoin OFT `lzReceive`（mint）恒 OOG → 源链已 burn、目标链未 mint，`settlePendingCompose` 仅覆盖 compose 面、协议内无 settle 兜底，消息滞留 endpoint 队列；恢复 = 免许可手工重放投递（任何人可调 `EndpointV2.sol::lzReceive` 带足 gas 执行，同 operations.md §3.13 免许可 `lzCompose` 重驱动一类），资金不丢失但滞留至人工介入；`omnichainStakingGasLimit` 过低 → `lzCompose` 恒 OOG，受益人可经 `OmnichainMemecoinStakerUpgradeable.sol::settlePendingCompose` 取回裸币（不建仓，UX 降级、无资金损失） | memecoin 远端 staking OFT options | `[代码已证]` |
| `MemeverseProxyDeployer` | `quorumNumerator` | `setQuorumNumerator` | 非零 | 仅影响后续新部署 governor 初始化 | `[代码已证]` |
| `MemeverseProxyDeployer` | `minQuorumNumerator` | `setMinQuorumNumerator` / constructor | `> 0` 且 `<= 100` | `deployGovernorAndIncentivizer` 用 `totalSupply() * minQuorumNumerator / 100` 推导 governor `_minQuorum`（governor init 冻结、无 setter）；`> 100` 要求超过 100% 供给量使治理 quorum 永久不可达，且 governor 升级经 `_authorizeUpgrade(onlyGovernance)` 受瘫痪治理门控、不可恢复 | `[代码已证]` |
| `POLendUpgradeable` | `leveragedDebtFactor` | `initialize` / `setLeveragedDebtFactor` | 非零；`<= uint128.max * 1e18`；与当前利率满足最小杠杆乘积约束 | 未来 `None / Genesis` market 的 debt cap 与剩余杠杆容量预览 | `[代码已证]` |
| `POLendUpgradeable` | `protocolTreasury` | `initialize` / `setProtocolTreasury` | 非零；onlyOwner | 杠杆利息 treasury 落点：finalize 真付 `realInterest` 全额清扫 + Launcher over-capacity funding excess 接收地址；仅影响未来份额；实现 getter/storage 为 `treasury()`/`treasury`，产品术语 `protocolTreasury`（见 `docs/spec/polend/core.md`） | `[代码已证]` |
| `POLendUpgradeable` | `defaultInterestRate` | `initialize` / `setDefaultInterestRate` | `0 < rate <= 1e18`；onlyOwner；与当前 `leveragedDebtFactor` 满足最小杠杆乘积约束 | 后续注册 market 复制固化的默认利率；仅影响未来注册 market（已注册 market 利率不变） | `[代码已证]` |
| `POLendUpgradeable` | `creditFactory` | `initialize` / `setCreditFactory` | 非零；onlyOwner | `GenesisCreditFactory` 地址指针，影响后续 `leveragedGenesisWithCredit` 按 `uAsset` 查 GenesisCredit 路径；未部署对应 GenesisCredit 时该路径 revert `NoCreditForUAsset`，正常 `leveragedGenesis` 不受影响 | `[代码已证]` |
| `GovernanceCycleIncentivizerUpgradeable` | `rewardRatio` | `GovernanceCycleIncentivizerUpgradeable.sol::initialize`（`GovernanceCycleIncentivizerUpgradeable.sol::__GovernanceCycleIncentivizer_init` 硬编码 `2500`、deployer 不可传参）/ `GovernanceCycleIncentivizerUpgradeable.sol::updateRewardRatio` | `<=10000` | 周期结算时 treasury->reward 划拨比例；`initialize` 默认 `2500`（25%），修改仅治理提案（`onlyGovernance`） | `[代码已证]` |
| `YieldDispatcherUpgradeable` | `protocolTreasury` | `setProtocolTreasury` | 非零；onlyOwner | UASSET no-code receiver 资金落点：无 code 接收方时 UASSET 经 `YieldDispatcherUpgradeable.sol::_settle` 转入 `protocolTreasury`（跨链同址为部署约定、非不变量，见 `setProtocolTreasury` NatSpec） | `[代码已证]` |

注：`fundMetaDatas[uAsset]` 是 uAsset 级**全局活读配置**：无 per-verse 快照、无版本化、无冻结；`MemeverseLaunchImpl.sol::registerMemeverse` 仅校验当前值非零，不快照。四处决策点均读共享槽的当前值：① 启动门槛——`MemeverseLaunchImpl.sol::_handleGenesisStage` 在每次 `MemeverseLauncherUpgradeable.sol::changeStage` 执行时读 `minTotalFund`（Genesis→Locked vs Genesis→Refund 判定）；② 铸币比——`MemeverseLiquidityImpl.sol` 在 Locked 迁移时读 `fundBasedAmount`（主池 memecoin 预算 = 70% × genesis funds × `fundBasedAmount`）；③ V 缓冲——`MemeverseLaunchImpl.sol::_deployGovernanceComponents` 在 Locked 迁移（治理链）时读两字段推导 `virtualAssets`；④ POLendUpgradeable 杠杆上限——`MemeverseLauncherUpgradeable.sol::getDebtCapBaseByVerseId` 在 Genesis 期间按交易实时读 `minTotalFund`。后果：owner 在 verse 注册后、Genesis→Locked 判定前调用 `MemeverseLauncherUpgradeable.sol::setFundMetaData`，会静默改变 pending verse 启动所依赖的经济学（启动门槛、铸币比、V 缓冲、杠杆上限），这是**预期语义**（非 bug、非安全问题：无资金错配，退款路径归还存款，owner 信任域）。方向：调高 `minTotalFund` 收紧启动门槛（→ Refund）但**扩大** POLendUpgradeable 杠杆上限（`debtCapBase = max(totalNormalFunds, minTotalFund)`）；调低则放宽门槛。已 `Locked` verse 不受影响（V 已写入、池已部署）。参与者不得假定注册时值为冻结快照。

> **decimals 口径与运营清单：** `minTotalFund` 与 `fundBasedAmount` 均为 raw-unit 口径，无链上 `decimals()` 感知。`minTotalFund` 按该 verse `uAsset` 自身精度解释（`docs/spec/polend/genesis.md:113`），`fundBasedAmount = memecoins per raw unit` 静默包含 `decimals()` 尺度——同经济目标下 6-dec 需比 18-dec 大 1e12 倍以外的校准（例：18-dec 设 100 memecoin/raw 则 6-dec 需 100*1e12 才能等价整币价）。`InitialPriceCalculator` 亦为 pure 且假设 18-dec 等价 raw 量（见其 NatSpec），不做归一，故价格正确性同样依赖该校准。仅 GenesisCredit 路径强制 18-dec（`GenesisCreditFactory.sol:68-69` `InvalidUAssetDecimals` 与 `POLendUpgradeable.sol:297-301` `CreditDecimalsMismatch`）；普通 `genesis` / `leveragedGenesis` 有意支持任意 decimals，误校准不产生资金盗窃（预算在托管资金内执行，残差烧毁，`virtualAssets` 归零则 `YieldVault.initialize` revert `ZeroVirtualAssets` fail-closed），但会导致池偏小/偏大或部署阻塞。运营方接纳非 18-dec 资产前必须：离线读取 `IERC20Metadata(uAsset).decimals()` 并按整币目标换算 `fundBasedAmount`，校验 `minTotalFund * fundBasedAmount >= 143`（保证 `virtualAssetsBuffer>0`），并复核上述四处消费者与 `InitialPriceCalculator` 价格影响。

## 2.1 Launcher 初始化配置面

Launcher 当前为 UUPS proxy，下列 dependency 由 `initialize(...)` 一次性写入。

| 参数 | Source | Replacement | Required address kind |
| --- | --- | --- | --- |
| `localLzEndpoint` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade | canonical local LayerZero endpoint address |
| `memeverseRegistrar` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical registrar address |
| `memeverseProxyDeployer` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical proxy deployer address |
| `yieldDispatcher` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical yield dispatcher address |
| `lzEndpointRegistry` | `initialize(...)` | 无 runtime setter；初始化后不可变更——经 proxy upgrade 替换会与 interoperation/registrars 的 immutable registry 指针及 registration center `initialize` 写入、无 setter 的 storage 指针分裂（center 侧须连带 UUPS 升级），属禁止操作 | canonical endpoint registry address |
| `polend` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade 或 redeploy plan | canonical dependency proxy address |
| `polSplitter` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade 或 redeploy plan | canonical dependency proxy address |

canonical Launcher address 是 `IOutrunDeployer` CREATE3 部署的 ERC1967 proxy 地址。`polend` 与 `polSplitter` 必须写入 canonical proxy address；Launcher 不提供 runtime setter 或地址级 replacement semantics。

## 2.2 Launcher 运行期必填配置

以下配置不在 `initialize(...)` 中写入，但 Launcher 正常运作前必须由 owner 通过对应 setter 完成配置。

| 参数 | Source | Replacement | Required address kind |
| --- | --- | --- | --- |
| `fundMetaDatas[uAsset] = {minTotalFund,fundBasedAmount}` | `setFundMetaData` | readiness 必须覆盖目标 uAsset 的 fund metadata 已配置；`fundBasedAmount` 上限保持 `<= 2^64-1`（完整校验规则见 §1 同参数行） | canonical launch configuration |

## 3. 代码常量/不可变面（常被当作“默认配置”）

| 模块 | 参数 | 当前值 | 说明 | 来源 |
| --- | --- | --- | --- | --- |
| `MemeverseLauncherUpgradeable` | `BPS_BASE` | `10000` | 比率基数 | `[代码已证]` |
| `MemeverseRegistrationCenterUpgradeable` | `DAY` | `180` 秒（测试值） | 注册时间单位（中心链实际生效）；部署 readiness 断言 `DAY() == expectedRegistrationDay`（`MemeverseScript.s.sol::_requireRegistrationCenterReady` 读回校验，由 `::_openSupportedUAssetsAfterReadiness` / `::onboardUAsset` 调用，脚本存储变量经 `_loadReadinessEnv` 从 `EXPECTED_DAY` env 装载：testnet 在 `.env` 设 `EXPECTED_DAY=180` 保留快窗，未设默认生产值 `24*3600`；失配 `REGISTRATION_DAY_NOT_READY` 阻断 registration 打开） | `[代码已证]` |
| `MemeverseRegistrationCenterUpgradeable` | `FIXED_LOCKUP_DURATION` | `365 days` | 注册时固定锁定期；`unlockTime = endTime + 365 days`，不是注册参数或 owner 配置项 | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | `registrationCenter.DAY()` | 中心链配置值 | 本地报价读取 registration center 的时间单位 | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | unlock 辅助计算 | `365 days` | 本地报价辅助使用固定锁定期，与中心链最终写入语义一致 | `[代码已证]` |
| `FeeMath` | `PROTOCOL_FEE_SHARE_BPS` | `3500` | shared fee math 中 protocol/LP 按 35%/65% 拆分 `feeBps` | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable`（Router storage，返佣记账在 `SwapFacet`） | `referrerRebateBps` 初始值 | `1000` | hook proxy `initialize` 写入 hook storage；返佣率（占总 fee bps，有 referrer 时从 protocol share 切出）；上限 `<= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`）；owner 可经 `setReferrerRebateBps`（Router 直接实现）后续修改 | `[代码已证]` |
| `MemeversePoolKeyLib`（Hook/Router/SwapFacet 共享引用） | `DEFAULT_TICK_SPACING` | `200` | 池固定 tick spacing；Hook/Router 构造 PoolKey 与 `SwapFacet::beforeInitializeLogic` 校验共用此常量 | `[代码已证]` |
| `SettlementFacet` | `PREORDER_SETTLEMENT_FEE_BPS` | `100` | preorder 结算固定 1% | `[代码已证]` |
| `MemeverseUniswapHookUpgradeable` | `defaultLaunchFeeConfig` 初始值 | `start=5000,min=100,decay=900s` | proxy `initialize(initialOwner, treasury_, lpTokenImplementation_, swapFacet_, dynamicFeeFacet_, settlementFacet_, launcher_)` 初始化；同时建立默认启动费率配置、LP template、3 facet 指针与 launcher 绑定；owner 可通过 `setDefaultLaunchFeeConfig(...)` 后续修改 | `[代码已证]` |
| `MemeverseSwapRouter` | `hook`,`permit2` | 构造注入（immutable） | 外部依赖地址，部署后不可改 | `[代码已证]` |
| `DeployMemeverseHookProxy` | `DEPLOYMENT_NONCE` | 首次 `0`，每次新部署递增 | 嵌入 CREATE3 salt，决定 `lpTokenImplementation`、`SwapFacet`/`DynamicFeeFacet`/`SettlementFacet` 三 facet、hook implementation/proxy 等 deployment artifacts；同 nonce 同配置幂等，同 nonce 不同配置 revert；`deployHookProxy` 原子回滚或广播前仿真失败且未消耗 salt 时可用同 nonce 重试，仅部分广播已消耗 CREATE3 salt 时递增 nonce | `[代码已证]` |
| `MemeverseSettlementImpl` | `UNLOCK_PROTECTION_WINDOW` | `24 hours` 固定常量 | `UNLOCK_PROTECTION_WINDOW` 与 pool-level resume time 均无直接 owner setter；常量仅在正常 `Locked -> Unlocked` 中规定 `24 hours` 写入值。launcher 由 initialize 固化不可 retarget，resume time 写入仅正常 Locked→Unlocked 路径由真实 Launcher 执行（见本表 unlock 后公开 swap 保护 / INV-12） | `[代码已证]` |
| `MemeverseLauncherUpgradeable` / `POLendUpgradeable` | `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` | `type(uint128).max` | 普通创世与杠杆创世共享的聚合部署资金上限；preorder 不计入该口径 | `[代码已证]` |
| `GovernanceCycleIncentivizerUpgradeable` | `CYCLE_DURATION` | `90 days` | 治理周期长度 | `[代码已证]` |
| `MemecoinYieldVault` | `REDEEM_DELAY` | `1 days` | 赎回延迟 | `[代码已证]` |
| `MemecoinYieldVault` | `MAX_REDEEM_REQUESTS` | `5` | 每地址最大排队赎回数 | `[代码已证]` |
| `MemeverseLauncherUpgradeable` / `MemecoinYieldVault` | 虚拟资产缓冲（`virtualAssets`）推导 | `virtualAssets = minTotalFund × fundBasedAmount × 7 / 1000`（即 `0.7%`，等价最小主池 memecoin 的 1%，主池占创世资金 70%） | 由 Launcher 在治理链 deploy vault 时按 `FundMetaData(uAsset)` 的 `minTotalFund × fundBasedAmount` 一次性算出并传入 `vault.initialize(...)`；配置期必须校验派生值 `virtualAssets = minTotalFund × fundBasedAmount × 7 / 1000 > 0`（等价 `minTotalFund × fundBasedAmount >= 143`），否则 deploy vault 时 `YieldVault.initialize` 会 `ZeroVirtualAssets` revert；vault 写入 storage 后永久固定、不可改；不是 owner 可配项，也不新增 `FundMetaData` 字段；用于 share/asset 转换的虚拟缓冲，口径见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md) §4；源码锚点 `MemeverseLauncherLib.sol::virtualAssetsBuffer`（算 `virtualAssets` 的共享 pure 函数）、`MemeverseLauncherUpgradeable.sol::setFundMetaData`（配置期校验调用）、`MemeverseLaunchImpl.sol`（deploy vault 时计算调用）、`MemecoinYieldVault.sol::initialize`（revert），边界单测 `MemeverseLauncherConfig.t.sol::testSetFundMetaData_RevertsWhenVirtualAssetsRoundsToZero` | `[代码已证]` |
| `MemeverseLauncherUpgradeable` | 虚拟缓冲系数 | `7 / 1000`（`0.7%`）常量 | 算 `virtualAssets` 的固定系数，Launcher 端常量，非 owner 配置面；其语义为「主池占创世资金 70%」（主池预算 `MemeverseLiquidityImpl.sol::deployBootstrapLiquidity` `mulDiv(totalGenesisFunds, 7, 10)`）对应的等效最小主池 1% 口径；常量定义 `MemeverseLauncherLib.sol::YIELD_VAULT_VIRTUAL_ASSET_FACTOR`(=7)/`::YIELD_VAULT_VIRTUAL_ASSET_DIVISOR`(=1000)，由 facade 与 launch sibling 共享以免漂移 | `[代码已证]` |

## 4. 当前实现提醒

| 主题 | 说明 | 当前实现事实 | 结论 |
| --- | --- | --- | --- |
| swap 启动保护 | 启动期保护机制 | 当前主路径为 execute-or-revert + launch fee 衰减 + 显式 `Launcher -> Hook.executePreorderSettlement(...)` | 以当前实现为准 |
| unlock 后公开 swap 保护 | 公开交易恢复时机 | 公开 swap 恢复时间由 pool-level `publicSwapResumeTime` 控制；固定 24 小时窗口是正常 `Locked -> Unlocked` 时的同交易写入语义。launcher 由 initialize 固化，binding 运行时不可偏离真实 Launcher proxy（详见 INV-12 / operations §3.8） | 以当前实现为准 |
| unlock settlement 执行顺序 | 解锁结算与公开 swap 保护 | 同交易 settlement 顺序与保护窗口写入的不变量口径见 [docs/spec/invariants.md](../invariants.md) INV-07A / INV-12 | 以当前实现为准 |
| launch fee 时间单位 | launch fee 的时间语义 | 代码使用 `decayDurationSeconds`（秒） | 以秒语义解读 |
| 注册天数语义 | 注册时长的时间语义 | 中心链写入与本地 quote 均使用 registration center 的 `DAY` | 当前链上语义由 center 配置决定 |
| 注册 fee / dust 判定 | 注册链路 native fee 支付约束 | source registrar 要求 `msg.value >= source lzFee`；local registrar 要求 `msg.value == value`；center fan-out 要求 `msg.value >= totalFee`；hub fan-out 残余或 refund 是 center-owned gas dust，可由 owner sweep | 以代码为准 |

## 5. 确定性边界

- `[未知]`：每条链的真实部署地址、真实 owner/delegate、是否已改过上述配置，仓库内未提供最终清单。
- 本文中的“当前值”仅指仓库实现默认/构造参数语义，不等同于生产环境实时值。
