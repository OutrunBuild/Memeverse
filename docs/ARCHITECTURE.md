# MemeverseV2 架构总览

## 1. 模块地图

### 1.1 启动与生命周期核心

- `src/verse/MemeverseLauncher.sol`：facade，verse 生命周期状态机与资金主编排（Genesis/Refund/Locked/Unlocked）的唯一外部入口与 delegatecall 调度方。
- `src/verse/MemeverseLaunchImpl.sol`：delegatecall sibling，承载 launch 生命周期链（registerMemeverse / genesis / preorder / genesisAndPreorder / `changeStage` stage dispatcher / 治理组件部署编排）。与 facade 共享同一 ERC-7201 storage namespace `outrun.storage.MemeverseLauncher`，在 proxy 存储上下文执行；owner 经 `setLaunchImpl` 替换。`changeStage` 在 Genesis→Locked 成功路径内嵌套 delegatecall `MemeverseLiquidityImpl`，Locked→Unlocked 路径内嵌套 delegatecall `MemeverseSettlementImpl`。
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
- `src/swap/MemeverseUniswapHook.sol`（diamond Router）
- `src/swap/SwapFacet.sol` / `src/swap/DynamicFeeFacet.sol` / `src/swap/SettlementFacet.sol`（共享 hook storage 的 DELEGATECALL facet）
- 负责 swap、加减流动性、LP fee claim、启动期费用语义与 preorder settlement 通道。
- **Diamond / 多 facet 架构**：`MemeverseUniswapHook` 是 Router（UUPS implementation，`ERC1967Proxy` + `UUPSUpgradeable`），保留 admin/view/liquidity 直接实现 + 全部 modifier + 统一 storage struct，callback/fee/settlement entry 经 delegatecall 分发到 3 个 facet（1:1 签名细入口用 `_forwardCalldata` 做 selector 置换 + calldata 转发，非 1:1 签名入口如 `quoteSwapFeeWithContext` 仍用 `_facetDelegatecall` + `abi.encodeCall`）——`SwapFacet`（callback 主体 + fee 分账 + LP per-share accounting + 返佣记账 `_settleProtocolFee` 内联写 `pendingRebate`，`_collectProtocolFee` 调用）、`DynamicFeeFacet`（`DynamicFeeState` 读写 + `quote`）、`SettlementFacet`（preorder swap/settle/take + typed settlement callback，`[代码已证]`）。所有 facet 共享 Router 的 ERC7201 storage（`outrun.storage.MemeverseUniswapHook`），经 DELEGATECALL 在 hook proxy storage 上下文执行；facet 间用 internal delegatecall 链协作（如 `SwapFacet` delegatecall `DynamicFeeFacet.prepareSwapFee`）。外部观测所有 entry 都在 hook 地址（统一 ABI）。
- **Typed unlock callback 路由**：共享 Hook 接口定义 `UnlockCallbackKind { ModifyLiquidity, Settlement }`；每个 unlock 发起方直接编码 `abi.encode(kind, typedStruct)`。Router 先把首个 ABI word 读为 `uint256`，只接受当前明确支持的两个 raw 值，其他值统一回退 `InvalidUnlockCallbackKind(rawKind)`。Settlement 的 callback 入参与返回结构定义在 `ISettlementFacet`；因 `SettlementCallbackData` 当前全静态，Router 在 kind 校验后用 `bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])` 前缀转发到 SettlementFacet（跳过 memory decode + 二次 encode；与 `abi.encodeCall` 字节等价），并把 facet 的原始 ABI returndata 直接交还 PoolManager，外层 settlement logic 只解码一次。若 `SettlementCallbackData` 未来引入动态字段，须回到 `abi.encodeCall`。外部 v4 `unlockCallback(bytes)` ABI 保持不变。该路由已实现。`[代码已证]`

#### Facet / Router 关键函数

**费率报价**

| 函数 | 源 | 作用 |
|---|---|---|
| `quoteSwap` | `MemeverseSwapRouter::quoteSwap` / `MemeverseUniswapHookLens::quoteSwap`（`view` facade；Lens 对 non-view `hook.quoteSwapFeeWithContext` 发起 `STATICCALL`），Hook bridge 再经 `DELEGATECALL` 路由到 `DynamicFeeFacet::quote` | 完整报价：先通过 `DynamicFeeMath.estimateDynamicFeeQuote` 计算动态费率，取动态费率与 launch fee 的较大值作为 effective fee，再拆分为 LP fee 与 protocol fee，按 exact-input / exact-output 两种方向估算用户实际输入输出。 |
| `quoteLaunchFeeBps` | `DynamicFeeMath::quoteLaunchFeeBps` | 根据指数衰减公式计算当前 launch fee bps：从 `startFeeBps` 按经过时间衰减到 `minFeeBps`，衰减形状由 `LAUNCH_FEE_EXP_SHAPE_WAD` 控制。 |

**动态费率与状态更新**

| 函数 | 源 | 作用 |
|---|---|---|
| `updateAfterSwap` | `DynamicFeeFacet::updateAfterSwap` | swap 后更新 per-pool EWVWAP 状态与 per-address batch 累积：维护指数加权成交量 `weightedVolume0`、加权价格成交量 `weightedPriceVolume0`、EWVWAP `ewVWAPX18`，同时衰减并累加短期冲击 `shortImpactPpm`、更新波动率偏差累加器 `volDeviationAccumulator`、以及更新 per-address 的 `batchAccumPpm`（3 秒窗口内的累积 PIF，用于 adverse 防拆单）。 |
| `refreshVolatilityAnchorAndCarry` | `DynamicFeeMath::refreshVolatilityAnchorAndCarry` | 刷新波动率锚定价格与携带量（由 `DynamicFeeFacet` 的公开 swap 路径与 `SettlementFacet` 的 preorder settlement 路径共享调用）：当距上次锚定移动超过 `VOL_FILTER_PERIOD_SEC` 时，将当前价格设为新锚定价格，并对 `volDeviationAccumulator` 按衰减因子折算为 `volCarryAccumulator`；超过 `VOL_DECAY_PERIOD_SEC` 则清零。 |

**Preorder settlement**

| 函数 | 源 | 作用 |
|---|---|---|
| `executePreorderSettlement` | `MemeverseUniswapHook::executePreorderSettlement`（Router，经 delegatecall `SettlementFacet::executeSettlementLogic`） | Launcher 入口：计算 fixed 1% preorder fee，先收 input 侧 fee，netInput 留在 hook proxy，由 hook 发起 unlock/swap/settle/take。 |
| `executeSettlementLogic` | `SettlementFacet::executeSettlementLogic` | 执行 PoolManager unlock / swap / take；以 `abi.encode(UnlockCallbackKind.Settlement, SettlementCallbackData)` 发起 unlock，接收并一次解码 typed `SettlementResult`，并在 `protocolFeeOnInput == false` 时从 output 侧扣除 protocol fee。`[代码已证]` |
| `_collectPreorderSettlementInputFees` | `SettlementFacet::_collectPreorderSettlementInputFees` | LP fee 经 `_accrueLpFee` 记入 per-share 累计（纯记账，token 拉款不在本函数），protocol fee 经 `transferFrom` 直接转给 treasury；LP fee token 由 `executeSettlementLogic` 与 netInput 合并一次 `transferFrom` 拉到 hook proxy（同源同收款人，省一次 transferFrom）。 |

**LP 费收取与 claim**

| 函数 | 源 | 作用 |
|---|---|---|
| `_accrueLpFee` | `MemeverseSwapFeeBase::_accrueLpFee`（`SwapFacet`/`SettlementFacet` 经继承共享，避免 facet 间逐字重复） | 将一笔 LP fee 按 `totalSupply` 换算为 per-share 增量，累加到 `pool.fee0PerShare` 或 `pool.fee1PerShare`，并触发 `LPFeeCollected` 事件。不执行任何代币转账。 |
| `_collectLpFee` | `SwapFacet::_collectLpFee` | 先调用 `_accrueLpFee` 入账（per-share 累计），再从 PoolManager `take` 出 LP fee 到 Hook 合约；遵循 CEI（effect → interaction）。 |
| `updateUserSnapshotLogic` | `SwapFacet::updateUserSnapshotLogic` | 根据 LP token 余额和 per-share 累计值，将用户自上次快照以来的可 claim fee 累加到 `pendingFee0` / `pendingFee1`，并更新 offset。 |
| `claimableFees` | `MemeverseUniswapHookLens::claimableFees` | view 函数：返回用户当前可 claim 的 fee0 / fee1，包含已记录 pending 和尚未 snapshot 的增量。 |
| `_claimFees` | `MemeverseUniswapHook::_claimFees`（Router 直接实现；仅 snapshot 子步经 delegatecall `SwapFacet::updateUserSnapshotLogic`） | 执行 LP fee claim：先 `updateUserSnapshotLogic` 取快照；清零 pending（effect）后经 `CurrencySettler.transferWithGuard` 转给 recipient（interaction），完成后触发 `FeesClaimed`；遵循 CEI。`transferWithGuard` 见下表（`[文档已对齐实现]`）。 |

**协议费收取**

| 函数 | 源 | 作用 |
|---|---|---|
| `_collectProtocolFee` | `SwapFacet::_collectProtocolFee` | 按 referrer 切 protocol fee rebate：`toTreasury = protocolFee - rebate`。`_settleProtocolFee` 先内联累加 hook storage `pendingRebate`（`pendingRebate[referrer][currency] += rebate`）并 emit `ReferralRebateAccrued`（effect），再经 `_takeToTreasury` 调用 `PoolManager.take` 把 `toTreasury` 转给 treasury（interaction），最后 emit `ProtocolFeeCollected`；记账本身是纯 storage effect，无 facet→facet delegatecall 或 PoolManager 调用。该 helper 现为严格 CEI（effect → interaction → event）：treasury take 不触发 v4 hook callback，但 ERC20 currency 会执行外部 `transfer` token 代码；记账先于 treasury take 与调用方执行的 rebate take。`_collectProtocolFee` = `_computeRebate` + `_settleProtocolFee` + 独立 `take(rebate)`，用于 afterSwap 3 点 + beforeSwap 边界（lpFee==0、protocolFee==0、或 effectiveSupply==0（drained pool））；beforeSwap 主路径（`lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0`）改走 `_computeRebate` + `_settleProtocolFee` + 合并 `take(currencyIn, address(this), lpFeeInputAmount + rebate)`。当前顺序的安全边界是 owner 只批准标准 fee currency、treasury 是被动收款方，且任一外部调用失败会回滚整笔 swap。进入非零 protocol fee 路径后始终触发 `ProtocolFeeCollected`（`amount` 是 treasury 实收 `toTreasury`；仅当 `rebate > 0` 时 `toTreasury < 完整 protocolFee`，`rebate == 0` 时 `toTreasury` 等于完整 protocolFee）；`protocolFeeAmount == 0` 时函数早返不 emit，`rebate > 0` 时额外触发 hook 的 `ReferralRebateAccrued`。无 referrer（`_decodeReferrer` 返回零）、`referrerRebateBps == 0`、或 `mulDiv` 向下取整使 `rebate == 0` 时不切正数返佣。 |

**返佣（Referral Rebate）**

普通 swap 当前按 `LP 65 / protocol 35` 拆分 fee，`FeeMath.PROTOCOL_FEE_SHARE_BPS = 3500`；有 referrer 时，rebate 从 protocol share 中切分：

| 场景 | LP | protocol base（treasury 实收） | rebate |
|---|---|---|---|
| 无 referrer | 65% | 35% | 0% |
| 有 referrer（默认 `referrerRebateBps = 1000`） | 65% | 25% | 10% |

rebate 公式：`rebate = protocolFee × referrerRebateBps / PROTOCOL_FEE_SHARE_BPS`（提取为 `SwapFacet::_computeRebate`，两级向下取整语义见 [docs/spec/invariants.md INV-20](spec/invariants.md)）。rebate custody 在 `MemeverseUniswapHook`(Router，hook proxy 地址)；`SwapFacet::_settleProtocolFee`（`_collectProtocolFee` 调用；beforeSwap 主路径直接调）先内联写 hook storage `pendingRebate[referrer][currency] += rebate` 并 emit `ReferralRebateAccrued`（rebate>0 时；effect；记账部分是纯 storage 写，无 facet→facet delegatecall、无额外 PoolManager 调用），再做 treasury take（`_takeToTreasury`：`toTreasury = protocolFee - rebate` 经 `poolManager.take(feeCurrency, treasury, toTreasury)` 到 treasury；interaction），最后 emit `ProtocolFeeCollected`。rebate take 由调用方执行（afterSwap / beforeSwap 边界经 `_collectProtocolFee` 内独立 `poolManager.take(feeCurrency, address(this), rebate)`；beforeSwap 主路径与 LP fee 合并 take）。因此 ledger effect 先于 treasury take 与 caller-side rebate take，`_settleProtocolFee` 现为严格 CEI：treasury take 不触发 v4 hook callback，ERC20 currency 仍会执行外部 `transfer` token 代码。该顺序依赖 owner 只批准标准 fee currency、treasury 保持被动收款，以及 swap 事务的整体回滚保证。referrer 经 `MemeverseUniswapHook::claimRebate`（Router 直接实现，不经 facet；CEI 清零后 transfer）pull 领取。take 与记账都经 hook（v4 `PoolManager.take` 的 delta 记在 take 的 caller 上——take 是经 DELEGATECALL 从 `address(this)`（=hook proxy）发起的外部 CALL，故 PoolManager 所见 `msg.sender` 为 hook，只有 hook 的 specifiedDelta credit 能抵消；注意 facet 帧内自身的 `msg.sender` 是 callback 下的 PoolManager（delegatecall 保留外层 msg.sender），而非 hook），custody / 记账 / claim 都在 hook。

hook 侧返佣路径锚点：

- `_decodeReferrer`：从 `hookData` 前 20 字节 packed 解码 referrer（caller 用 `abi.encodePacked`；`abi.encode` 左 padding 会误读，禁用）；长度 < 20 或前 20 字节全零视为无 referrer。在 `SwapFacet::beforeSwapLogic` 与 `::afterSwapLogic` 各解码一次。
- `_collectProtocolFee`：用于 beforeSwap 边界（lpFee==0、protocolFee==0、或 effectiveSupply==0（drained pool））+ afterSwap 3 点（exact-input output 侧、exact-output input 侧、exact-output output 侧），均传入 referrer（位于 `SwapFacet`）；beforeSwap 主路径（`lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0`）不走 `_collectProtocolFee`，改走 `_computeRebate` + `_settleProtocolFee` + 合并 take。
- `返佣记账`：`SwapFacet::_settleProtocolFee`（`_collectProtocolFee` 与 beforeSwap 主路径均调）内联写 hook storage `pendingRebate` 并 emit `ReferralRebateAccrued`；该职责与 DynamicFeeFacet 隔离。
- `claimRebate` / `pendingRebateOf`：Router 直接实现（非 facet），从 hook custody 转 token，CEI 清零后 transfer。
- `setReferrerRebateBps`：hook `onlyOwner` 直接实现（Router，写 hook storage `referrerRebateBps`）。

preorder settlement 路径（`executePreorderSettlement`）不携带 referrer，不参与返佣。

**资产结算与转账**

| 函数 | 源 | 作用 |
|---|---|---|
| `_settleDeltas` | `MemeverseUniswapHook::_settleDeltas` | 向 PoolManager settle 负 delta（用户欠池子的资金）。在 swap 栈语义下仅处理 ERC20/ERC20 pair；任一侧为 `address(0)` 直接 `revert NativeCurrencyUnsupported`。 |
| `_takeDeltas` | `MemeverseUniswapHook::_takeDeltas` | 从 PoolManager take 正 delta（池子欠用户的资金）到 recipient。 |
| `transferWithGuard` | `CurrencySettler::transferWithGuard`（Hook 与 Router 共用，两侧均已 `using CurrencySettler for Currency;`） | ERC20 转账 helper，已由 Hook/Router 各自的私有 `_transferCurrency` 副本迁移到 `CurrencySettler` 共享库以消除逐字重复。guards（`amount == 0` 早退、`to == address(0)` revert）+ `OutrunSafeERC20.safeTransfer` 处理非合规 ERC20 返回值（返回 `false` 或非 bool 数据）。失败抛 `OutrunSafeERC20.SafeERC20FailedOperation(address token)`。注：`CurrencySettler` 库的 `settle`/`take` 可处理 native 与 ERC20，但 `transferWithGuard` 自身仅 ERC20（swap 栈文义上也只允许 ERC20 结算）。`[文档已对齐实现]` |

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

- `src/verse/YieldDispatcher.sol`
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
冲突处理顺序：

- 当前规则判断以 Product Truth 层为准，并用 Implementation Evidence 层核验。
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

Uniswap V4 的 hook 回调将一次 swap 拆分为 `beforeSwap` 和 `afterSwap` 两个独立的外部调用帧。两者之间无法通过内存（memory）或调用栈传递状态。传统方案是将中间状态写入持久化 storage，但这会带来不必要的 SSTORE 开销（即使后续立即覆盖）。

EIP-1153 引入的 transient storage 通过 `TSTORE`（写入）和 `TLOAD`（读取）opcode 解决了这一问题：写入的数据在当前交易结束时自动清除，不产生持久化 storage 开销，且 gas 成本远低于 SSTORE。

### 4.2 封装层：MemeverseTransientState

`src/swap/libraries/MemeverseTransientState.sol` 将底层 `tstore`/`tload` 操作封装为类型安全的 library 函数，与 hook 业务逻辑解耦。

**存储槽位设计**：槽位通过 `keccak256(<preimage>) - 1` 推导，避免与持久化 storage 布局冲突，同时保持确定性寻址。swap callback 的当前调用栈 depth 存在一个不带 `poolId` 的独立 transient 槽位；每层 context payload 再按 `(SWAP_CONTEXT_TAG, poolId, depth)` keccak 出 base，以 `base + offset` 定位 fee、price、protocolFee（fee=0、price=1、protocolFee=2），避免每个字段各自重复哈希。

**导出函数**：

| 函数 | 方向 | 作用 |
|---|---|---|
| `pushSwapContext(PoolId, feeBps, preSqrtPriceX96)` | 写入 | 将 swap 上下文（fee + 价格）推入 transient 栈，返回 `base`，透传给 `storeExactOutputProtocolFee` 避免重算 keccak |
| `consumeCurrentSwapContext(PoolId)` | 读取+弹出 depth | 弹出当前深度的 swap 上下文（feeBps, preSqrtPriceX96, base），并将 LIFO depth 计数器 -1；`base` 透传给 `consumeExactOutputProtocolFee` 避免重算 keccak。fee/price 槽（offset 0,1）**不主动清零**，安全性来自两点：(1) v4 将每个 `beforeSwap`(push) 与其 `afterSwap`(consume) 配对，故本次读取的必是本 swap 自己 push 刚写入的槽；(2) `depth` 是全局 per-tx 计数器（非 per-pool），同一 `(poolId, depth)` 槽只有在完全相同的元组重现时才复用，此时 `pushSwapContext` 的无条件覆盖会替换任何先前值。offset 2（protocol fee）归 `MemeverseTransientState::consumeExactOutputProtocolFee` 独占清零；本函数返回 `base` 供后续按需读取，故此处不得触碰 |
| `storeExactOutputProtocolFee(base, amount)` | 写入 | 使用 `pushSwapContext` 返回并透传的 `base`，存储 exact-output 场景下预留的 output 侧 protocol fee |
| `consumeExactOutputProtocolFee(base)` | 读取+清除 | 使用 `consumeCurrentSwapContext` 返回并透传的 `base`，读取并清除 exact-output 预留的 protocol fee |

### 4.3 传递的数据

Transient storage 在 `beforeSwap` 与 `afterSwap` 之间传递两项关键数据：

- **`feeBps`**：`beforeSwap` 中通过动态费率报价（或 launch fee / base fee 降级路径）计算得到的 effective fee bps。`afterSwap` 读取此值以拆分 LP fee 和 protocol fee，确保两个回调使用完全一致的费率。
- **`preSqrtPriceX96`**：`beforeSwap` 开始时从 `PoolManager.getSlot0` 读取的 swap 前价格。`afterSwap` 中通过 `consumeCurrentSwapContext` 读取此值，经 SwapFacet internal delegatecall `DynamicFeeFacet.updateAfterSwap(...)`（与 §1.3 一致）传入此值与 swap 后价格对比计算价格冲击（PIF），用于更新 EWVWAP、波动率偏差累加器、短期冲击状态和 per-address batch 累积。



Preorder settlement 的当前实现不使用 transient state 路由。`SettlementFacet::executeSettlementLogic` 通过显式 `Settlement` discriminator 发起 unlock；Router 根据 payload 选择 typed settlement callback。settlement swap 由 hook proxy 自己调用 PoolManager，真实 v4 在 `msg.sender == address(key.hooks)` 时同时跳过 `beforeSwap` 与 `afterSwap`，固定 1% fee 与其记账全部由 settlement 路径处理。回调型 token 发起的外部重入 swap 不是 hook self-call，仍执行普通 callbacks、使用 swap-context transient 栈并走公开费率路径。`[代码已证]` 详见 [docs/spec/invariants.md INV-04A](spec/invariants.md)。

### 4.4 完整流程

1. **`beforeSwap` 阶段**：
   - 从 `PoolManager.getSlot0` 获取 `preSqrtPriceX96`。
   - 经 SwapFacet internal delegatecall `DynamicFeeFacet::prepareSwapFee` 计算动态费率（与 §1.3 一致；内部处理波动率锚定刷新）。执行热路径只返回结算必需的 `(feeBps, estimatedGrossOutputAmount)`，不回完整 `PreparedSwapFee`（完整结构仅 `DynamicFeeFacet::quote` / Lens 路径）。`PrepareSwapFeeParams` 仅携带结算输入；`DynamicFeeFacet` 从共享 ERC7201 storage 读取 `defaultLaunchFeeConfig` 与 `poolLaunchTimestamp[poolId]`，`SwapFacet` / `quoteSwapFeeWithContext` 调用方不传 launch 配置。
   - 调用 `MemeverseTransientState.pushSwapContext(poolId, feeBps, preSqrtPriceX96)`，将 feeBps 和 preSqrtPriceX96 推入 transient 栈，返回 `base`，透传给 `storeExactOutputProtocolFee` 写入 exact-output 预留的 output 侧 protocol fee。
   - 对 exact-input 方向立即收取 input 侧费用（LP fee 和 protocol fee）。

2. **PoolManager 执行 swap**：核心 AMM 逻辑运行，价格移动。

3. **`afterSwap` 阶段**：
   - 通过 `MemeverseTransientState.consumeCurrentSwapContext(poolId)` 弹出 transient 栈，获取 feeBps、preSqrtPriceX96 与 `base`（`base` 透传给 `consumeExactOutputProtocolFee` 读取 exact-output 预留的 output 侧 protocol fee）。
   - 经 SwapFacet internal delegatecall `DynamicFeeFacet.updateAfterSwap(...)`（与 §1.3 一致），传入 preSqrtPriceX96 与 post-swap 价格对比，更新 EWVWAP 和冲击状态。
   - 将 feeBps 拆分为 LP fee bps 和 protocol fee bps。
   - 对 exact-output 方向，基于实际成交金额收取 input 侧 LP fee 和 protocol fee；对 exact-input + output 侧 protocol fee 的场景，从实际 output 中扣除 protocol fee。
   - 当前实现中，Preorder settlement 的 hook self-call 不进入上述 `beforeSwap` / `afterSwap` 流程；其 callback 类型由 unlock payload 显式选择，费用与动态状态更新由 `SettlementFacet` 自己完成。非 self-call 的重入 swap 仍完整执行本流程。`[代码已证]`

### 4.5 安全属性

- Transient storage 的作用域为单笔交易，交易结束自动清除，无跨交易残留风险。
- 每次写入覆盖前值，同一交易内不存在数据竞争。
- Slot 均由 keccak256 派生（独立常量槽取 `keccak256 - 1`；swap-context 字段取 `keccak256 - 1` 为 base 再 `+ offset`），位于持久化 storage 布局之外，不会与常规 storage mapping 冲突。

## 5. 当前已知边界提醒

- swap 当前规则主路径为 launch fee 衰减加显式 `Launcher -> Hook` preorder settlement。
- unlock 后的保护窗口是独立安全要求，不由 launch fee 或 preorder settlement 替代。
- 受保护公开 swap 的恢复时刻锚定实际 `Locked -> Unlocked` 迁移调用时间，再加上固定 `24 hours` 的 `UNLOCK_PROTECTION_WINDOW`。
- 注册中心当前把 `durationDays` 按 180 秒测试日换算；`unlockTime` 固定按 `endTime + 365 days` 派生。
