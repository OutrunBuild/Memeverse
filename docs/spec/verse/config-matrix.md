# MemeverseV2 配置矩阵

## 1. 说明

标签说明：

- `[代码已证]`：当前代码可直接验证
- `[未知]`：仓库内没有部署级最终值

## 2. 代码可配置面（当前真实生效）

| 模块 | 参数 | 写入方式 | 主要约束 | 作用范围 | 来源 |
| --- | --- | --- | --- | --- | --- |
| `MemeverseLauncher` | `memeverseSwapRouter` | `setMemeverseSwapRouter` | 非零；set-time 三重校验与 `Genesis -> Locked` launch-time preflight 见 [docs/spec/invariants.md](../invariants.md) INV-04 | 启动建池、公开 router、preorder 结算 hook 绑定 | `[代码已证]` |
| `MemeverseLauncher` | `memeverseUniswapHook` | `setMemeverseUniswapHook` | 非零；write-once（首次设置后 `revert HookAlreadyConfigured()`），完整绑定约束见 [docs/spec/invariants.md](../invariants.md) INV-04 | preorder 显式结算 + post-unlock 保护写入绑定 | `[代码已证]` |
| `MemeverseLauncher` | `lzEndpointRegistry` | `setLzEndpointRegistry` | 非零 | 注册 peer 配置、跨链 endpoint 映射 | `[代码已证]` |
| `MemeverseLauncher` | `memeverseRegistrar` | `setMemeverseRegistrar` | 非零 | 注册入口权限边界 | `[代码已证]` |
| `MemeverseLauncher` | `memeverseProxyDeployer` | `setMemeverseProxyDeployer` | 非零 | per-verse token/vault/governor 部署 | `[代码已证]` |
| `MemeverseLauncher` | `polend` | `initialize(...)` | 非零；当前代码没有 runtime setter | Launcher 保存 `POLend` 接线地址；注册同交易内调用 `POLend.registerLendMarket(verseId)`；`Genesis -> Locked` 时若有杠杆债务则调用 `finalizeLeveragedGenesis(verseId)`；`Locked -> Unlocked` 的 unlock settlement 中按需调用 `executeGlobalSettlement(verseId)`；同一地址还承担 `getTotalLeveragedDebt/Interest`、`preRedeemPTFee`、settlement dust reserve 等查询/执行依赖 | `[代码已证]`，其更细四池语义见 [docs/spec/polend/README.md](../polend/README.md) |
| `MemeverseLauncher` | `polSplitter` | `initialize(...)` | 非零；当前代码没有 runtime setter | Launcher 保存 `POLSplitter` 接线地址；`Genesis -> Locked` 时调用 `initializeVerse`、记录 PT backing ratio、执行 `split`；normal fee 与 governor PT fee 的 preview/redeem 都依赖该地址；`Locked -> Unlocked` 的 unlock settlement 中先调用 `settle(verseId)`，settled 后普通 PT fee 与 governor PT fee 都改走 `redeemPT -> uAsset` 口径 | `[代码已证]`，其更细四池语义见 [docs/spec/polend/README.md](../polend/README.md) |
| `MemeverseLauncher` | `yieldDispatcher` | `setYieldDispatcher` | 非零 | 本地费用分发落地 | `[代码已证]` |
| `MemeverseLauncher` | `fundMetaDatas[uAsset] = {minTotalFund,fundBasedAmount}` | `setFundMetaData` | 两者非零；`fundBasedAmount <= MAX_FUND_BASED_AMOUNT`，其中 `MAX_FUND_BASED_AMOUNT = 2^64-1` | Genesis 达标判断、首发 memecoin 量与初始价格；该两字段同时作为 `MemecoinYieldVault` 虚拟缓冲 V 推导输入（V 推导规则与 0.7% 系数见 §3） | `[代码已证]` |
| `MemeverseLauncher` | `executorRewardRate` | `setExecutorRewardRate` | `< 10000` | fee 分账（执行者奖励） | `[代码已证]` |
| `MemeverseLauncher` | `preorderCapRatio`,`preorderVestingDuration` | `setPreorderConfig` | 非零；`capRatio <= 10000` | preorder 容量和线性释放 | `[代码已证]` |
| `MemeverseLauncher` | `oftReceiveGasLimit`,`yieldDispatcherGasLimit` | `setGasLimits` | 两者 `>0` | 远端分发 OFT options | `[代码已证]` |
| `MemeverseRegistrationCenter` | `supportedUAssets` | `setSupportedUAsset` | uAsset 非零 | 注册可用募资币种白名单；普通 `genesis` / `leveragedGenesis` 支持任意 decimals 的 `uAsset`，但 GenesisCredit credit path（`leveragedGenesisWithCredit` + `GenesisCreditFactory.deployCredit`）只支持 `uAsset.decimals() == 18`，非 18-dec `uAsset` 不得部署 GenesisCredit `[目标规范]`（`InvalidUAssetDecimals` / `CreditDecimalsMismatch` 待 factory/POLend 校验落地） | `[代码已证]`（credit path 18-dec 强制为 `[目标规范]`） |
| `MemeverseRegistrationCenter` | `min/maxDurationDays` | `setDurationDaysRange` | 非零，且 min < max | 注册 durationDays 校验 | `[代码已证]` |
| `MemeverseRegistrationCenter` | `registerGasLimit` | `setRegisterGasLimit` | `>0` | center 向远端 registrar fan-out 的 receive gas | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | `registrationCenter` | `setRegistrationCenter` | 非零 | 本地 registrar 信任中心地址 | `[代码已证]` |
| `MemeverseRegistrarOmnichain` | `registrationGasLimit`（base/local/omnichain） | `setRegistrationGasLimit` | owner-only（数值不做额外边界） | remote registrar -> center 的 quote/send gas 预算 | `[代码已证]` |
| `MemeverseUniswapHook` | `treasury` | `setTreasury` | 非零 | protocol fee 接收地址 | `[代码已证]` |
| `MemeverseUniswapHook` | `supportedProtocolFeeCurrencies[currency]` | `setProtocolFeeCurrency` / `setProtocolFeeCurrencySupport` | owner-only | 协议费币种选择（输入侧优先） | `[代码已证]` |
| `MemeverseUniswapHook` | `launcher` | `setLauncher` | 非零；允许 owner 在部署后 retarget，属于同一 trust boundary 的接受语义 | preorder settlement 授权 + pair-based `setPublicSwapResumeTime` 写入权限绑定 | `[代码已证]` |
| `MemeverseUniswapHook` | `defaultLaunchFeeConfig={start,min,decaySeconds}` | `setDefaultLaunchFeeConfig` | 全部非零；`min<=start<=10000` | 启动窗口费率衰减 | `[代码已证]` |
| `MemeverseUniswapHook`（经 wrapper 转发到 `MemeverseDynamicFeeEngine`） | `referrerRebateBps` | `setReferrerRebateBps`（hook wrapper `onlyOwner` -> `engine.setReferrerRebateBps`，engine 的 `onlyOwner` 是 hook proxy） | `<= FeeMath.PROTOCOL_FEE_SHARE_BPS`（即 `<= 3500`），否则 engine revert `RebateExceedsProtocolShare` | 返佣率（占总 fee bps）；engine `initialize` 默认 `1000`（10%） | `[代码已证]` |
| `MemeverseOmnichainInteroperation` | `oftReceiveGasLimit`,`omnichainStakingGasLimit` | `setGasLimits` | 两者 `>0` | memecoin 远端 staking OFT options | `[代码已证]` |
| `MemeverseProxyDeployer` | `quorumNumerator` | `setQuorumNumerator` | 非零 | 仅影响后续新部署 governor 初始化 | `[代码已证]` |
| `POLend` | `leveragedDebtFactor` | `initialize` / `setLeveragedDebtFactor` | 非零；`<= uint128.max * 1e18`；与当前利率满足最小杠杆乘积约束 | 未来 `None / Genesis` market 的 debt cap 与剩余杠杆容量预览 | `[代码已证]` |
| `GovernanceCycleIncentivizerUpgradeable` | `rewardRatio` | `updateRewardRatio` | `<=10000` | 周期结算时 treasury->reward 划拨比例 | `[代码已证]` |

## 2.1 Launcher 初始化配置面

Launcher 当前为 UUPS proxy，下列 dependency 由 `initialize(...)` 一次性写入。

| 参数 | Source | Replacement | Required address kind |
| --- | --- | --- | --- |
| `localLzEndpoint` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade | canonical local LayerZero endpoint address |
| `memeverseRegistrar` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical registrar address |
| `memeverseProxyDeployer` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical proxy deployer address |
| `yieldDispatcher` | `initialize(...)` | 初始值由 initializer 写入；后续运行期配置以本表对应 setter 行为准 | canonical yield dispatcher address |
| `lzEndpointRegistry` | `initialize(...)` | 可通过 `setLzEndpointRegistry` 后续配置 | canonical endpoint registry address |
| `polend` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade 或 redeploy plan | canonical dependency proxy address |
| `polSplitter` | `initialize(...)` | 无 runtime setter；替换需要 proxy upgrade 或 redeploy plan | canonical dependency proxy address |

canonical Launcher address 是 `IOutrunDeployer` CREATE3 部署的 ERC1967 proxy 地址。`polend` 与 `polSplitter` 必须写入 canonical proxy address；Launcher 不提供 runtime setter 或地址级 replacement semantics。

## 2.2 Launcher 运行期必填配置

以下配置不在 `initialize(...)` 中写入，但 Launcher 正常运作前必须由 owner 通过对应 setter 完成配置。

| 参数 | Source | Replacement | Required address kind |
| --- | --- | --- | --- |
| `fundMetaDatas[uAsset] = {minTotalFund,fundBasedAmount}` | `setFundMetaData` | 迁移后 readiness 必须覆盖目标 uAsset 的 fund metadata 已配置；`fundBasedAmount` 目标上限保持 `<= 2^64-1` | canonical launch configuration |

## 3. 代码常量/不可变面（常被当作“默认配置”）

| 模块 | 参数 | 当前值 | 说明 | 来源 |
| --- | --- | --- | --- | --- |
| `MemeverseLauncher` | `RATIO` | `10000` | 比率基数 | `[代码已证]` |
| `MemeverseRegistrationCenter` | `DAY` | `180` 秒（测试值） | 注册时间单位（中心链实际生效） | `[代码已证]` |
| `MemeverseRegistrationCenter` | `FIXED_LOCKUP_DURATION` | `365 days` | 注册时固定锁定期；`unlockTime = endTime + 365 days`，不是注册参数或 owner 配置项 | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | `registrationCenter.DAY()` | 中心链配置值 | 本地报价读取 registration center 的时间单位 | `[代码已证]` |
| `MemeverseRegistrarAtLocal` | unlock 辅助计算 | `365 days` | 本地报价辅助使用固定锁定期，与中心链最终写入语义一致 | `[代码已证]` |
| `FeeMath` | `PROTOCOL_FEE_SHARE_BPS` | `3500` | shared fee math 中 protocol/LP 按 35%/65% 拆分 `feeBps` | `[代码已证]` |
| `MemeverseDynamicFeeEngine` | `referrerRebateBps` 初始值 | `1000` | engine `initialize` 写入；返佣率（占总 fee bps，有 referrer 时从 protocol share 切出）；上限 `<= FeeMath.PROTOCOL_FEE_SHARE_BPS`（`3500`）；owner 可经 hook wrapper `setReferrerRebateBps` 后续修改 | `[代码已证]` |
| `MemeverseUniswapHook` | `TICK_SPACING` | `200` | 只接受该 tick spacing | `[代码已证]` |
| `MemeverseUniswapHook` | `PREORDER_SETTLEMENT_FEE_BPS` | `100` | preorder 结算固定 1% | `[代码已证]` |
| `MemeverseUniswapHook` | `defaultLaunchFeeConfig` 初始值 | `start=5000,min=100,decay=900s` | proxy `initialize(initialOwner, treasury_, dynamicFeeEngine_, lpTokenImplementation_, preorderSettlementExecutor_)` 初始化；同时建立默认启动费率配置、engine / LP template / preorder executor 绑定；owner 可通过 `setDefaultLaunchFeeConfig(...)` 后续修改 | `[代码已证]` |
| `MemeverseSwapRouter` | `hook`,`permit2` | 构造注入（immutable） | 外部依赖地址，部署后不可改 | `[代码已证]` |
| `DeployMemeverseHookProxy` | `DEPLOYMENT_NONCE` | 首次 `0`，每次新部署递增 | 嵌入 CREATE3 salt，决定 `lpTokenImplementation`、`preorderSettlementExecutor`、engine implementation/proxy、hook implementation/proxy 六份 deployment artifacts；同 nonce 同配置幂等，同 nonce 不同配置 revert，失败后递增 nonce 重试 | `[代码已证]` |
| `MemeverseSettlementImpl` | `UNLOCK_PROTECTION_WINDOW` | `24 hours` 固定常量 | 不再暴露 owner 配置面；用于 `Locked -> Unlocked` 后受保护公开 swap 的固定恢复窗口 | `[代码已证]` |
| `MemeverseLauncher` / `POLend` | `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` | `type(uint128).max` | 普通创世与杠杆创世共享的聚合部署资金上限；preorder 不计入该口径 | `[代码已证]` |
| `GovernanceCycleIncentivizerUpgradeable` | `CYCLE_DURATION` | `90 days` | 治理周期长度 | `[代码已证]` |
| `MemecoinYieldVault` | `REDEEM_DELAY` | `1 days` | 赎回延迟 | `[代码已证]` |
| `MemecoinYieldVault` | `MAX_REDEEM_REQUESTS` | `5` | 每地址最大排队赎回数 | `[代码已证]` |
| `MemeverseLauncher` / `MemecoinYieldVault` | 虚拟缓冲 V 推导 | `V = minTotalFund × fundBasedAmount × 7 / 1000`（即 `0.7%`，等价最小主池 memecoin 的 1%，主池占创世资金 70%） | 由 Launcher 在治理链 deploy vault 时按 `FundMetaData(uAsset)` 的 `minTotalFund × fundBasedAmount` 一次性算出并传入 `vault.initialize(...)`；vault 写入 storage 后永久固定、不可改；不是 owner 可配项，也不新增 `FundMetaData` 字段；用于 share/asset 转换的虚拟缓冲，口径见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md) §4 | `[目标规范]` |
| `MemeverseLauncher` | 虚拟缓冲系数 | `7 / 1000`（`0.7%`）常量 | 算 V 的固定系数，Launcher 端常量，非 owner 配置面；其语义为「主池占创世资金 70%」对应的等效最小主池 1% 口径 | `[目标规范]` |

## 4. 当前实现提醒

| 主题 | 说明 | 当前实现事实 | 结论 |
| --- | --- | --- | --- |
| swap 启动保护 | 启动期保护机制 | 当前主路径为 execute-or-revert + launch fee 衰减 + 显式 `Launcher -> Hook.executePreorderSettlement(...)` | 以当前实现为准 |
| unlock 后公开 swap 保护 | 公开交易恢复时机 | 公开 swap 恢复时间由 `Locked -> Unlocked` 迁移同交易写入的 pool-level `publicSwapResumeTime` 控制；窗口为固定产品常量，不再有 owner 配置面 | 以当前实现为准 |
| unlock settlement 执行顺序 | 解锁结算与公开 swap 保护 | 同交易 settlement 顺序与保护窗口写入的不变量口径见 [docs/spec/invariants.md](../invariants.md) INV-07A / INV-12 | 以当前实现为准 |
| launch fee 时间单位 | launch fee 的时间语义 | 代码使用 `decayDurationSeconds`（秒） | 以秒语义解读 |
| 注册天数语义 | 注册时长的时间语义 | 中心链写入与本地 quote 均使用 registration center 的 `DAY` | 当前链上语义由 center 配置决定 |
| 注册 fee / dust 判定 | 注册链路 native fee 支付约束 | source registrar 要求 `msg.value >= source lzFee`；local registrar 要求 `msg.value == value`；center fan-out 要求 `msg.value >= totalFee`；hub fan-out 残余或 refund 是 center-owned gas dust，可由 owner sweep | 以代码为准 |

## 5. 确定性边界

- `[未知]`：每条链的真实部署地址、真实 owner/delegate、是否已改过上述配置，仓库内未提供最终清单。
- 本文中的“当前值”仅指仓库实现默认/构造参数语义，不等同于生产环境实时值。
