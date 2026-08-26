# MemeverseV2 状态机

## 1. 说明与来源边界

当前规则来源：
- 本文档与 `docs/spec/*.md` 共同构成当前规则真源。
- `src/**` 与 `test/**` 提供规则落地证据。

## 2. Launcher 生命周期状态机

主状态：
- `Genesis`
- `Refund`（终态）
- `Locked`
- `Unlocked`（终态；公开 swap 是否恢复由保护窗口另行判定）

### 2.1 状态迁移规则

| 当前状态 | 触发 | 条件 | 下一状态 | 关键副作用 | 规则状态 |
| --- | --- | --- | --- | --- | --- |
| `Genesis` | `changeStage` | `flashGenesis && (totalNormalFunds >= minTotalFund || totalLeveragedInterest >= minTotalFund)` | `Locked` | 部署治理组件 + `Launcher` 以 desired budgets 触发四池 bootstrap，Router 返回 actual spend，随后按实际执行结果建立 `memecoin/uAsset`、`POL/uAsset`、`PT/uAsset`、`PT/POL` + preorder 结算 | 当前规则（代码已证） |
| `Genesis` | `changeStage` | `currentTime > endTime && (totalNormalFunds >= minTotalFund || totalLeveragedInterest >= minTotalFund)` | `Locked` | 同上 | 当前规则（代码已证） |
| `Genesis` | `changeStage` | `currentTime > endTime && totalNormalFunds < minTotalFund && totalLeveragedInterest < minTotalFund` | `Refund` | 允许 `refund/refundPreorder` | 当前规则（代码已证） |
| `Genesis` | `changeStage` | 其他条件 | 回退 `StillInGenesisStage` | 无 | 当前规则（代码已证） |
| `Locked` | `changeStage` | `currentTime > unlockTime` | `Unlocked` | 开放赎回路径；并按该次交易时间 + `UNLOCK_PROTECTION_WINDOW`（数值见 config-matrix §3；不变量见 INV-07A / INV-12）为受保护池写入公开 swap 恢复时间 | 当前规则（代码已证） |
| `Locked` | `changeStage` | `currentTime <= unlockTime` | 保持 `Locked` | 不回退，仍发 `ChangeStage(Locked)` 事件 | 当前规则（代码已证） |
| `Refund`/`Unlocked` | `changeStage` | 任意 | 回退 `ReachedFinalStage` | 无 | 当前规则（代码已证） |

注：Genesis 行的 `minTotalFund` 取 `MemeverseLauncherUpgradeable.sol::changeStage` 执行时刻 `MemeverseLauncherUpgradeable.sol::fundMetaDatas` 的当前值（活读），非注册时值；owner 在 Genesis 期间变更 `MemeverseLauncherUpgradeable.sol::setFundMetaData` 会改变达标判断（Genesis→Locked / Genesis→Refund），为预期语义（详见 config-matrix.md §2 注）。

### 2.2 `flashGenesis` 子状态语义

- `flashGenesis=false`：必须等到 `endTime` 后再判断是否进入 `Locked/Refund`。
- `flashGenesis=true`：募资达到最小门槛可提前结束 Genesis 并进入 `Locked`。
- 提前进入 `Locked` 不改变 `unlockTime` 的绝对时间，只改变 Genesis 结束时刻。

### 2.3 Launcher 阶段内可执行动作边界

| 动作 | Genesis | Refund | Locked | Unlocked | 规则状态 |
| --- | --- | --- | --- | --- | --- |
| `genesis` | 允许 | 禁止 | 禁止 | 禁止 | 当前规则（代码已证） |
| `preorder` | 允许 | 禁止 | 禁止 | 禁止 | 当前规则（代码已证） |
| `genesisAndPreorder` | 允许 | 禁止 | 禁止 | 禁止 | 当前规则（代码已证） |
| `refund` / `refundPreorder` | 禁止 | 允许（每地址一次） | 禁止 | 禁止 | 当前规则（代码已证） |
| `claimNormalYT` | 禁止 | 禁止 | 允许 | 允许 | 当前规则（POLendUpgradeable 四池） |
| `claimNormalFees` | 禁止 | 禁止 | 允许 | 允许 | 当前规则（代码已证） |
| `mintPOLToken` | 禁止 | 禁止 | 允许 | 允许 | 当前规则（代码已证） |
| `redeemAndDistributeFees` | 禁止 | 禁止 | 允许 | 允许 | 当前规则（代码已证） |
| `redeemMemecoinLiquidity` / `redeemAuxiliaryLiquidity` | 禁止 | 禁止 | 禁止 | 允许 | 当前规则（POLendUpgradeable 四池） |
| `POLSplitterUpgradeable.redeemPT` / `POLSplitterUpgradeable.redeemYT` | 禁止 | 禁止 | 禁止 | 允许（settle 后） | 当前规则（POLendUpgradeable 四池） |
| `claimUnlockedPreorderMemecoin` | 禁止 | 禁止 | 允许（按线性解锁） | 允许 | 当前规则（代码已证） |

`genesis` 成功写入后受聚合上限约束（聚合上限见 [polend/genesis.md §3](../polend/genesis.md)）；实现上先更新普通创世账本再执行 uAsset 拉取，使 callback-capable token 重入 POLendUpgradeable 时读取到累计普通资金。

bootstrap auxiliary pool creation 的 auxiliary underspend 处置（actual spend 记账、不施加独立 bootstrap backing / equality guard、不依赖独立 rounding-envelope 规则）见 [docs/spec/invariants.md](../invariants.md) INV-04。

### 2.4 `Unlocked` 后的流动性保护窗口

- 安全要求：当 verse 从 `Locked` 进入解锁阶段后，不得立即开放“公开 swap + LP 赎回”并存的状态。
- 必须存在一个 `post-unlock liquidity protection period`，用于保护 POL / genesis liquidity 的赎回公平性，并为依赖全局结算窗口的上层模块（如 POL Lend / PT-YT 语义）提供稳定结算基准。
- 在该保护窗口内：
  - 应允许：`redeemMemecoinLiquidity`、普通辅助池 LP 领取、PT/YT 兑付
  - 可按产品定义允许：与保护机制兼容的补池/加池行为
  - 必须禁止：普通公开 swap
  - 必须禁止：绕过公开入口的等价 swap 路径
- `Locked -> Unlocked` 同交易 settlement 顺序与公开 swap 恢复时间写入的约束见 [docs/spec/invariants.md](../invariants.md) INV-07A（窗口存在性论证见 INV-12；数值见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)）
- bootstrap residual `POL/PT` 的 normal share 在 `redeemAuxiliaryLiquidity` 路径发放；leveraged share 在 leveraged auxiliary settlement 路径发放。只有最终按用户比例 floor 后的尾差 dust 允许残留。
- 当前实现状态：
  - verse 在 `currentTime > unlockTime` 后，需通过实际 `changeStage()` 调用进入 `Unlocked`
  - launcher 在 settlement 调用完成后，按 `block.timestamp + UNLOCK_PROTECTION_WINDOW` 为受保护池写入 `publicSwapResumeTime`（窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)；不变量见 [docs/spec/invariants.md](../invariants.md) INV-07A / INV-12）
  - hook 在 `beforeSwap` 中读取该时间；未到期前，受保护 pair 的公开 swap 继续被拒绝
  - 因此当前实现采用“无额外阶段、但公开 swap 恢复时间锚定实际迁移调用”的落地方式

## 3. 注册与跨链状态边界

### 3.1 Symbol 注册状态（RegistrationCenter）

| 状态 | 描述 | 迁移条件 | 规则状态 |
| --- | --- | --- | --- |
| `Available` | symbol 无活跃注册，或已过 `endTime` | `registration` 提交并通过校验 | 当前规则（代码已证） |
| `Active` | symbol 处于占用窗口 | `block.timestamp > endTime` 进入可再次注册 | 当前规则（代码已证） |
| `Historical` | 历史记录归档到 `symbolHistory` | 每次新注册前若旧记录存在则归档 | 当前规则（代码已证） |

### 3.2 注册分发边界

- RegistrationCenter 负责 `uniqueId/endTime/unlockTime` 生成与 fan-out。
- 本链目标：直接调用 `MemeverseRegistrarAtLocal.localRegistration`。
- 异链目标：通过 LayerZero `lzSend` 下发消息到 `MemeverseRegistrarOmnichain`。
- Registrar 只做转发注册：`registerMemeverse` + `setExternalInfo`。
- 当前中心链时间换算单位来自 `RegistrationCenter.DAY`；本地 registrar 的 `quoteRegister` 读取中心 `DAY`，最终时间以中心写入为准，且锁仓固定为 `FIXED_LOCKUP_DURATION`（数值与配置面见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)；时间权威不变量见 [docs/spec/invariants.md](../invariants.md) INV-11）。

### 3.3 Launcher 跨链配置边界

- 注册时 launcher 对 `omnichainIds` 中的非本链 id 执行 `_lzConfigure`。
- 任一远端链在 endpoint registry 中无映射会回退注册。
- `omnichainIds[0]` 被解释为治理链。

## 4. 启动窗口状态行为

### 4.1 当前代码状态机（实际执行）

当前 `src/swap/**` 实现为：

| 状态 | 判定依据 | 行为 | 规则状态 |
| --- | --- | --- | --- |
| `LaunchFeeWindowActive` | `block.timestamp - poolLaunchTimestamp < decayDurationSeconds` | 动态费结果受 launch fee floor 约束（默认 5000 bps 向 100 bps 衰减） | 当前规则（代码已证） |
| `LaunchFeeWindowMatured` | 超过衰减窗口 | 保留动态费/最小费逻辑 | 当前规则（代码已证） |
| `PreorderSettlementPath` | Launcher 显式调用 `hook.executePreorderSettlement(...)` | 固定总费（数值见 [config-matrix.md §3](config-matrix.md)；记账见 [accounting.md §7.4](accounting.md)），仅已绑定 launcher 可触发；不依赖 `hookData` marker | 当前规则（代码已证） |

### 4.2 结论

- 启动期保护在实现层体现为“launch fee 衰减窗口 + 显式 settlement 通道”。
- unlock 后的公平赎回与全局结算风险窗口，则由解锁迁移时写入的 `publicSwapResumeTime`、`hook.beforeSwap` 与固定保护窗口（`UNLOCK_PROTECTION_WINDOW`，数值见 config-matrix §3；不变量见 INV-07A / INV-12）共同约束。
