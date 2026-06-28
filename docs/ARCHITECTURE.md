# MemeverseV2 架构总览

## 1. 模块地图

### 1.1 启动与生命周期核心

- `src/verse/MemeverseLauncher.sol`：facade，verse 生命周期状态机与资金主编排（Genesis/Refund/Locked/Unlocked）的唯一外部入口与 delegatecall 调度方。
- `src/verse/MemeverseLaunchImpl.sol`：delegatecall sibling，承载 launch 生命周期链（registerMemeverse / genesis / preorder / `changeStage` stage dispatcher / 治理组件部署编排）。与 facade 共享同一 ERC-7201 storage namespace `outrun.storage.MemeverseLauncher`，在 proxy 存储上下文执行；owner 经 `setLaunchImpl` 替换。`changeStage` 在 Genesis→Locked 成功路径内嵌套 delegatecall `MemeverseLiquidityImpl`，Locked→Unlocked 路径内嵌套 delegatecall `MemeverseSettlementImpl`。
- `src/verse/MemeverseSettlementImpl.sol`：delegatecall sibling，承载 settlement / claim / fee 链（refund / refundPreorder / claimNormalYT / claimNormalFees / claimUnlockedPreorderMemecoin / redeemAndDistributeFees / fee 捕获+collect+distribute，含 Locked→Unlocked 解算编排与 post-unlock 公开 swap 保护）。同 ERC-7201 namespace；owner 经 `setSettlementImpl` 替换。
- `src/verse/MemeverseLiquidityImpl.sol`：delegatecall sibling，承载 bootstrap 流动性 / POL mint / LP 赎回链（主池+三辅助池创建、preorder settlement 接线、residual 处置、mintPOLToken、redeemAuxiliaryLiquidity、settleLeveragedAuxiliaryLiquidity、redeemMemecoinLiquidity、LP helper）。同 ERC-7201 namespace；owner 经 `setLiquidityImpl` 替换。bootstrap 入口为 `deployBootstrapLiquidity`（原 `deployLiquidity`，selector 变）。
- `src/verse/MemeverseFeePreviewReader.sol`：独立 view 合约（非 sibling），不绑 ERC-7201、不收 delegatecall，经 immutable `PROXY` staticcall 读 proxy getter 预览 genesis maker fee 与 LayerZero 分发报价；EOA 直调为正常用法，owner 经 `setFeePreviewReader` 替换。
- 普通创世与 POLend 杠杆创世共享 `totalNormalFunds + totalLeveragedDebt <= type(uint128).max` 的聚合上限；`genesis` 先写入普通创世账本再拉取 uAsset，避免 callback-capable token 在转账中重入 POLend 时读到旧账本。

### 1.2 注册与跨链注册

- `src/verse/registration/MemeverseRegistrationCenter.sol`
- `src/verse/registration/MemeverseRegistrarAtLocal.sol`
- `src/verse/registration/MemeverseRegistrarOmnichain.sol`
- 负责参数校验、symbol 占用、local/remote fan-out，以及对 launcher 的落库调用。

### 1.3 交易与流动性

- `src/swap/MemeverseSwapRouter.sol`
- `src/swap/MemeverseUniswapHook.sol`
- `src/swap/libraries/MemeverseHookLib.sol`
- 负责 swap、加减流动性、LP fee claim、启动期费用语义与 preorder settlement 通道。
- `MemeverseHookLib` 是从 Hook 合约提取的 internal library，承载动态费率报价、swap 后状态更新、LP/协议费收取与资产结算逻辑，以降低 Hook 合约字节码体积。

#### MemeverseHookLib 导出函数

**费率报价**

| 函数 | 作用 |
|---|---|
| `quoteSwap` | 完整报价：先通过 `_quoteDynamicFee` 计算动态费率，取动态费率与 launch fee 的较大值作为 effective fee，再拆分为 LP fee 与 protocol fee，按 exact-input / exact-output 两种方向估算用户实际输入输出。 |
| `quoteSwapQuickReturn` | 轻量报价（流动性为零时快速返回）：仅使用 launch fee 或 base fee，不做动态费率计算，也不估算 output 金额。exact-output 方向直接 revert。 |
| `quoteSwapBaseFee` | 仅基于 launch fee 或 base fee 的报价（跳过动态费率）：估算 swap 流向并拆分 LP / protocol fee，用于不启用动态费率的场景。 |
| `quoteLaunchFeeBps` | 根据指数衰减公式计算当前 launch fee bps：从 `startFeeBps` 按经过时间衰减到 `minFeeBps`，衰减形状由 `LAUNCH_FEE_EXP_SHAPE_WAD` 控制。 |

**动态费率与状态更新**

| 函数 | 作用 |
|---|---|
| `updateDynamicStateAfterSwap` | swap 后更新 per-pool EWVWAP 状态与 per-address batch 累积：维护指数加权成交量 `weightedVolume0`、加权价格成交量 `weightedPriceVolume0`、EWVWAP `ewVWAPX18`，同时衰减并累加短期冲击 `shortImpactPpm`、更新波动率偏差累加器 `volDeviationAccumulator`、以及更新 per-address 的 `batchAccumPpm`（3 秒窗口内的累积 PIF，用于 adverse 防拆单）。 |
| `refreshVolatilityAnchorAndCarry` | swap 前刷新波动率锚定价格与携带量：当距上次锚定移动超过 `VOL_FILTER_PERIOD_SEC` 时，将当前价格设为新锚定价格，并对 `volDeviationAccumulator` 按衰减因子折算为 `volCarryAccumulator`；超过 `VOL_DECAY_PERIOD_SEC` 则清零。 |

**Preorder settlement**

| 函数 | 作用 |
|---|---|
| `executePreorderSettlement` | Launcher 入口：计算 fixed 1% preorder fee，先收 input 侧 fee，再把净 input 转给 preorder settlement executor 继续执行池内 swap。 |
| `MemeversePreorderSettlementExecutor.execute` | 统一封装 PoolManager unlock / swap / take 逻辑，并在 `protocolFeeOnInput == false` 时从 output 侧扣除 protocol fee，返回调整后 delta。 |
| `_collectPreorderSettlementInputFees` | 从 payer 拉取 input 侧的 LP fee 和 protocol fee：LP fee 通过 `creditLpFee` 记入 per-share 累计，protocol fee 直接转给 treasury。 |

**LP 费收取与 claim**

| 函数 | 作用 |
|---|---|
| `creditLpFee` | 将一笔 LP fee 按 `totalSupply` 换算为 per-share 增量，累加到 `pool.fee0PerShare` 或 `pool.fee1PerShare`，并触发 `LPFeeCollected` 事件。 |
| `collectLpFee` | 从 PoolManager take 出 LP fee 金额到 Hook 合约，再调用 `creditLpFee` 入账。 |
| `updateUserSnapshot` | 根据 LP token 余额和 per-share 累计值，将用户自上次快照以来的可 claim fee 累加到 `pendingFee0` / `pendingFee1`，并更新 offset。 |
| `claimableFeesView` | view 函数：返回用户当前可 claim 的 fee0 / fee1，包含已记录 pending 和尚未 snapshot 的增量。 |
| `claimFeesImpl` | 执行 LP fee claim：先 `updateUserSnapshot`，再将 pending fee 通过 `transferCurrency` 发送给 recipient，清零 pending 并触发 `FeesClaimed` 事件。 |

**协议费收取**

| 函数 | 作用 |
|---|---|
| `collectProtocolFee` | 从 PoolManager take 出 protocol fee，按 referrer 切 rebate：`toTreasury = protocolFee - rebate` 经 `_takeToTreasury` 到 treasury，`rebate` 由 hook `poolManager.take(feeCurrency, address(engine), rebate)` 拉到 engine 地址（v4 `PoolManager.take` delta 记调用者 hook，被 beforeSwap specifiedDelta credit 抵消，token 进 engine custody），再调 `MemeverseDynamicFeeEngine::accrueRebate` 纯记账累加 `pendingRebate`（无 PoolManager 调用）。进入非零 protocol fee 路径后始终触发 `ProtocolFeeCollected`（`amount` 是 treasury 实收 `toTreasury`，带 referrer 时 < 完整 protocolFee）；`protocolFeeAmount == 0` 时函数早返不 emit，有 rebate 时额外触发 engine 的 `ReferralRebateAccrued`。无 referrer（`_decodeReferrer` 返回零）或 `referrerRebateBps == 0` 时 rebate = 0，等价旧语义。 |

**返佣（Referral Rebate）**

普通 swap 的 protocol fee 拆分从 `LP 70 / protocol 30` 调整为 `LP 65 / protocol 35`（`FeeMath.PROTOCOL_FEE_SHARE_BPS` 从 `3000` 改为 `3500`），并在有 referrer 时从 protocol share 切 rebate：

| 场景 | LP | protocol base（treasury 实收） | rebate |
|---|---|---|---|
| 无 referrer | 65% | 35% | 0% |
| 有 referrer（默认 `referrerRebateBps = 1000`） | 65% | 25% | 10% |

rebate 公式：`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（等价 `totalFee × referrerRebateBps / BPS_BASE`）。rebate custody 在 `MemeverseDynamicFeeEngine`（与 LP fee 在 hook 隔离）；hook 在 `_collectProtocolFee` 内 `poolManager.take(feeCurrency, address(engine), rebate)` 把 token 拉到 engine 地址（v4 `PoolManager.take` delta 记调用者 hook，被 beforeSwap specifiedDelta credit 抵消），再调 `engine.accrueRebate` 纯记账 `pendingRebate[referrer][currency] += rebate`（无 PoolManager 调用、无外部调用）。referrer 经 `claimRebate` pull 领取（engine 独立可调，不经 hook；CEI 清零后 transfer）。take 在 hook（v4 `PoolManager.take` delta 记 `msg.sender`，只有 hook 的 specifiedDelta credit 能抵消；engine 自己 take 会留 engine 地址的未结算 delta → unlock 结束 NonzeroDeltaCount != 0 → CurrencyNotSettled），记账 / custody / claim 留在 engine（hook runtime 接近 24KB bytecode 上限，无法容纳完整返佣状态）。

hook 侧返佣路径锚点：

- `_decodeReferrer`：从 `hookData` 前 20 字节 packed 解码 referrer（caller 用 `abi.encodePacked`；`abi.encode` 左 padding 会误读，禁用）；长度 < 20 或前 20 字节全零视为无 referrer。在 `_beforeSwap` 与 `_afterSwap` 各解码一次。
- `_collectProtocolFee`：4 个调用点（exact-input `beforeSwap` input 侧、exact-input `afterSwap` output 侧、exact-output `afterSwap` input 侧、exact-output `afterSwap` output 侧）均传入 referrer。
- `setReferrerRebateBps` wrapper：hook `onlyOwner` 转发到 `engine.setReferrerRebateBps`（engine 的 `onlyOwner` 是 hook proxy）。

preorder settlement 路径（`executePreorderSettlement`）不携带 referrer，不参与返佣。

**资产结算与转账**

| 函数 | 作用 |
|---|---|
| `settleDeltas` | 向 PoolManager settle 负 delta（用户欠池子的资金）。在 swap 栈语义下仅处理 ERC20/ERC20 pair；任一侧为 `address(0)` 直接 `revert NativeCurrencyUnsupported`。 |
| `takeDeltas` | 从 PoolManager take 正 delta（池子欠用户的资金）到 recipient。 |
| `transferCurrency` | 通用转账 helper。common 层可处理 native 与 ERC20，但 swap 栈文义上只允许 ERC20 结算。 |

### 1.4 资产层

- `src/token/Memecoin.sol`
- `src/token/MemePol.sol`
- 负责 memecoin 与 POL 的铸造/销毁权限边界。

### 1.5 收益与治理

- `src/yield/MemecoinYieldVault.sol`
- `src/governance/MemecoinDaoGovernorUpgradeable.sol`
- `src/governance/GovernanceCycleIncentivizerUpgradeable.sol`
- 负责收益份额、国库接收、投票周期奖励。

### 1.6 跨链互操作

- `src/verse/Yield_Dispatcher.sol`
- `src/interoperation/MemeverseOmnichainInteroperation.sol`
- `src/interoperation/OmnichainMemecoinStaker.sol`
- 负责治理收益跨链投递与 memecoin 跨链 staking。

### 1.7 GenesisCredit 冷启动层

- `src/credit/GenesisCredit.sol` + `src/credit/GenesisCreditFactory.sol`
- 负责 GenesisCredit（per-uAsset ERC20+OFT 凭证）的部署、跨链 merkle claim 与自烧路径，支撑 `POLend.leveragedGenesisWithCredit` 的冷启动抵扣。GenesisCredit 是 plain contract，直接继承 LayerZero 官方 `OFT`（非 minimal-proxy / clone），由 `GenesisCreditFactory.deployCredit` CREATE3 直接部署完整合约。
- per-uAsset 本链确定性地址：`GenesisCreditFactory.deployCredit(uAsset, ...)` 以 `CREATE3 salt = keccak256(abi.encode(uAsset))` 部署，`creditOf / predictCredit` 可在本链确定性地解析/预测地址，不依赖运行期可变指针（CREATE3 地址与构造参数无关，故各链 `lzEndpoint` 不同也不影响地址）。跨链同址不是合约保证：仅当 `factory` 与 `uAsset` 均跨链同址时才成立，而 `uAsset`（Outrun UniversalAssets）是外部资产，其跨链同址性是部署前提、非本代码所校验。`setPeer` 必须逐链查询各链实际 `creditOf(localUAsset)`，不得复用 home 链地址。
- 跨链拓扑：home 链（Ethereum 主网）写入 merkle root 单点写入 → 用户在 home 链 `claim(...)`（permissionless merkle 校验，单次防重领）→ GenesisCredit 作为 OFT 经 LayerZero 桥到目标链 → 目标链上 GenesisCredit 持有人用 `burn` 或 `leveragedGenesisWithCredit` 抵扣。
- `POLend.finalizeLeveragedGenesis` 成功路径按该 verse `market.totalCreditInterest` 调 `GenesisCredit.burn` 烧掉 POLend 托管的 GenesisCredit；`Refund` 终态经 `claimRefund` 把 GenesisCredit token 退回给 credit 用户。会计约束见 [docs/spec/invariants.md INV-21](spec/invariants.md)，定义见 [docs/GLOSSARY.md](GLOSSARY.md) `GenesisCredit`。

## 2. 文档分层

1. Harness Contract 层
   - [AGENTS.md](../AGENTS.md)
   - [CLAUDE.md](../CLAUDE.md)
   - `.harness/policy.json`
   - `script/harness/gate.sh`
   - [README.md](../README.md)
   - `.github/workflows/test.yml`
   - `.githooks/*`
   - `.claude/settings.json`
2. Product Truth 层（当前规则真源）
   - [docs/spec/protocol.md](spec/protocol.md)
   - [docs/spec/verse/state-machines.md](spec/verse/state-machines.md)
   - [docs/spec/verse/accounting.md](spec/verse/accounting.md)
   - [docs/spec/access-control.md](spec/access-control.md)
   - [docs/spec/upgradeability.md](spec/upgradeability.md)
   - [docs/spec/verse/lifecycle-details.md](spec/verse/lifecycle-details.md)
   - [docs/spec/verse/registration-details.md](spec/verse/registration-details.md)
   - [docs/spec/governance/governance-yield-details.md](spec/governance/governance-yield-details.md)
   - [docs/spec/interoperation/interoperation-details.md](spec/interoperation/interoperation-details.md)
   - [docs/spec/common/common-foundations.md](spec/common/common-foundations.md)
   - [docs/spec/swap/swap-flow.md](spec/swap/swap-flow.md)
   - [docs/spec/swap/swap-integration.md](spec/swap/swap-integration.md)
   - [docs/spec/swap/uniswap-v4.md](spec/swap/uniswap-v4.md)
   - [docs/spec/swap/permit2.md](spec/swap/permit2.md)
   - [docs/implementation-map.md](implementation-map.md)
   - [docs/ARCHITECTURE.md](ARCHITECTURE.md)
   - [docs/GLOSSARY.md](GLOSSARY.md)
   - [docs/TRACEABILITY.md](TRACEABILITY.md)
   - [docs/VERIFICATION.md](VERIFICATION.md)
   - [docs/SECURITY_AND_APPROVALS.md](SECURITY_AND_APPROVALS.md)
3. Implementation Evidence 层（规则落地证据）
   - `src/**`
   - `test/**`
4. Topic Guides 层（设计稿与专题补充，不是当前规则真源）
   - `docs/superpowers/specs/*`
   - `docs/superpowers/plans/*`

冲突处理顺序：

- 当前规则判断以 Product Truth 层为准，并用 Implementation Evidence 层核验。
- Topic Guides 层用于补充模块说明，不单独定义当前规则。
- 若 `docs/spec/*.md` 与 `src/**` 冲突，以 `src/**` 为准。

## 3. 推荐阅读顺序

1. [CLAUDE.md](../CLAUDE.md)
2. [docs/ARCHITECTURE.md](ARCHITECTURE.md)
3. [docs/GLOSSARY.md](GLOSSARY.md)
4. [docs/spec/protocol.md](spec/protocol.md)
5. [docs/spec/verse/state-machines.md](spec/verse/state-machines.md)
6. [docs/spec/verse/accounting.md](spec/verse/accounting.md)
7. [docs/spec/access-control.md](spec/access-control.md)
8. [docs/spec/upgradeability.md](spec/upgradeability.md)
9. [docs/TRACEABILITY.md](TRACEABILITY.md) + [docs/VERIFICATION.md](VERIFICATION.md)

## 4. Transient Storage (EIP-1153) 在 Hook Swap 流程中的使用

### 4.1 问题背景

Uniswap V4 的 hook 回调将一次 swap 拆分为 `_beforeSwap` 和 `_afterSwap` 两个独立的外部调用帧。两者之间无法通过内存（memory）或调用栈传递状态。传统方案是将中间状态写入持久化 storage，但这会带来不必要的 SSTORE 开销（即使后续立即覆盖）。

EIP-1153 引入的 transient storage 通过 `TSTORE`（写入）和 `TLOAD`（读取）opcode 解决了这一问题：写入的数据在当前交易结束时自动清除，不产生持久化 storage 开销，且 gas 成本远低于 SSTORE。

### 4.2 封装层：MemeverseTransientState

`src/swap/libraries/MemeverseTransientState.sol` 将底层 `tstore`/`tload` 操作封装为类型安全的 library 函数，与 hook 业务逻辑解耦。

**存储槽位设计**：每个槽位通过 `keccak256("memeverse.transient.<key>") - 1` 推导，避免与持久化 storage 布局冲突，同时保持确定性寻址。

**导出函数**：

| 函数 | 方向 | 作用 |
|---|---|---|
| `pushSwapContext(PoolId, feeBps, preSqrtPriceX96)` | 写入 | 将 swap 上下文（fee + 价格）推入 transient 栈，返回深度 |
| `consumeCurrentSwapContext(PoolId)` | 读取+清除 | 弹出当前深度的 swap 上下文（feeBps, preSqrtPriceX96, depth） |
| `storeExactOutputProtocolFee(PoolId, depth, amount)` | 写入 | 存储 exact-output 场景下预留的 output 侧 protocol fee |
| `consumeExactOutputProtocolFee(PoolId, depth)` | 读取+清除 | 读取并清除 exact-output 预留的 protocol fee |
| `setPreorderSettlementExecutor(address)` | 写入 | 标记当前 preorder settlement 的 executor 地址 |
| `isExpectedPreorderSettlementExecutor(address)` | 读取 | 检查 sender 是否为当前标记的 executor |

### 4.3 传递的数据

Transient storage 在 `beforeSwap` 与 `afterSwap` 之间传递两项关键数据：

- **`feeBps`**：`_beforeSwap` 中通过动态费率报价（或 launch fee / base fee 降级路径）计算得到的 effective fee bps。`_afterSwap` 读取此值以拆分 LP fee 和 protocol fee，确保两个回调使用完全一致的费率。
- **`preSqrtPriceX96`**：`_beforeSwap` 开始时从 `PoolManager.getSlot0` 读取的 swap 前价格。`_afterSwap` 中通过 `consumeCurrentSwapContext` 读取此值，传给 `_dynamicFeeEngine().updateAfterSwap(...)` 与 swap 后价格对比计算价格冲击（PIF），用于更新 EWVWAP、波动率偏差累加器、短期冲击状态和 per-address batch 累积。

此外，`setPreorderSettlementExecutor` / `isExpectedPreorderSettlementExecutor` 在 preorder settlement 路径中用于标记当前执行者地址，使 `_beforeSwap` / `_afterSwap` 能识别内部 settlement 调用并跳过公共 swap 的费率计算逻辑。

### 4.4 完整流程

1. **`_beforeSwap` 阶段**：
   - 从 `PoolManager.getSlot0` 获取 `preSqrtPriceX96`。
   - 通过 `_dynamicFeeEngine().prepareSwapFee(...)` 计算动态费率（内部处理波动率锚定刷新），得到 `dynamicFeeBps`。
   - 调用 `MemeverseTransientState.pushSwapContext(poolId, dynamicFeeBps, preSqrtPriceX96)`，将 feeBps 和 preSqrtPriceX96 推入 transient 栈。
   - 对 exact-input 方向立即收取 input 侧费用（LP fee 和 protocol fee）。

2. **PoolManager 执行 swap**：核心 AMM 逻辑运行，价格移动。

3. **`_afterSwap` 阶段**：
   - 通过 `MemeverseTransientState.consumeCurrentSwapContext(poolId)` 弹出 transient 栈，获取 feeBps 和 preSqrtPriceX96。
   - 调用 `_dynamicFeeEngine().updateAfterSwap(...)`，传入 preSqrtPriceX96 与 post-swap 价格对比，更新 EWVWAP 和冲击状态。
   - 将 feeBps 拆分为 LP fee bps 和 protocol fee bps。
   - 对 exact-output 方向，基于实际成交金额收取 input 侧 LP fee 和 protocol fee；对 exact-input + output 侧 protocol fee 的场景，从实际 output 中扣除 protocol fee。
   - Preorder settlement 路径（`executePreorderSettlement`）使用 transient storage 记录期望的 executor 地址，settlement 完成后清零该预期地址，避免 bypass 状态泄漏到后续调用。

### 4.5 安全属性

- Transient storage 的作用域为单笔交易，交易结束自动清除，无跨交易残留风险。
- 每次写入覆盖前值，同一交易内不存在数据竞争。
- Slot 通过 `keccak256 - 1` 推导，位于持久化 storage 布局之外，不会与常规 storage mapping 冲突。

## 5. 当前已知边界提醒

- swap 当前规则主路径为 launch fee 衰减加显式 `Launcher -> Hook` preorder settlement。
- unlock 后的保护窗口是独立安全要求，不由 launch fee 或 preorder settlement 替代。
- 受保护公开 swap 的恢复时刻锚定实际 `Locked -> Unlocked` 迁移调用时间，再加上固定 `24 hours` 的 `UNLOCK_PROTECTION_WINDOW`。
- 注册中心当前把 `durationDays` 按 180 秒测试日换算；`unlockTime` 固定按 `endTime + 365 days` 派生。
