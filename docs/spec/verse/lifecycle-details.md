# MemeverseV2 生命周期细化说明

## 1. 目标

本文用用户视角、资金流视角和模块协作视角，把 MemeverseV2 的完整生命周期串起来。

本文补充：

- [docs/spec/protocol.md](../protocol.md)
- [docs/spec/verse/state-machines.md](state-machines.md)
- [docs/spec/verse/accounting.md](accounting.md)
- [docs/spec/invariants.md](../invariants.md)

本文不替代上述真源；若与实现冲突，以真源和源码锚点为准。

## 2. 生命周期总览

MemeverseV2 的主路径可以概括为：

1. 注册
2. `Genesis`
3. 成功进入 `Locked`，或失败进入 `Refund`
4. `unlockTime` 到达
5. 在 `unlockTime` 之后实际执行 `changeStage()` 时进入 `Unlocked`，并为受保护池写入恢复公开 swap 的时间
6. 保护窗口结束后才恢复无限制公开 swap

其中：

- 启动期保护针对 pool bootstrap / preorder settlement
- 解锁后保护针对 POL 公平退出与全局结算

这两类保护不是同一个机制，不能互相替代。

## 3. 注册阶段

注册阶段由 `MemeverseRegistrationCenter` 统一生成并写入以下关键时间与标识：

- `uniqueId`
- `endTime`
- `unlockTime`

注册链路负责：

- 校验参数是否合法
- 检查 symbol 是否仍在占用窗口内
- 生成本次 verse 的唯一身份与时间边界
- 把结果 fan-out 到本链或异链 registrar
- 由 registrar 最终落库到 launcher

这一阶段决定了后续募资何时结束，以及最早可进入解锁迁移的时间边界；退出保护窗口的实际起点仍以后续 `changeStage()` 交易时间为准。

## 4. Genesis 募资阶段

### 4.1 用户动作

用户在 `Genesis` 期可以执行：

- `genesis`
- `preorder`

### 4.2 资金模型

普通 Genesis 入金按 POLend 聚合账本累计：

- `totalNormalFunds`
- `userGenesisFund`

杠杆 Genesis 入金先支付利息，再派生 `totalLeveragedDebt`。募资成功部署时使用：

- `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt`
- owner 后续调整 `leveragedDebtFactor` 时，只影响仍处于 `None / Genesis` 且 Launcher verse 仍在 `Genesis` 的 market 后续可新增杠杆容量；不会回写已进入 `Locked / Settled / Refund` 的市场利率、已 mint 债务、退款、结算或 claim 结果。
- 成功路径只按 `totalGenesisFunds = totalNormalFunds + totalLeveragedDebt` 计创世部署资金，preorder 不计入该口径，且必须满足 `totalGenesisFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，其中 `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max`。
- Genesis 期新增杠杆前，必须按累计 `nextTotalLeveragedInterest = totalLeveragedInterest + interestAmount` 推导 `previewDebt = nextTotalLeveragedInterest * 1e18 / market.interestRate`，并同时满足 `previewDebt <= debtCap` 与 `totalNormalFunds + previewDebt <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS`，不能只看当前调用 delta。

随后按 POLend 四池模型执行 `70/30` 规则，进入 `memecoin/uAsset` 主池与 `POL/uAsset`、`PT/uAsset`、`PT/POL` 三个辅助池路径。

POL raw、PT raw、YT raw 与主池 LP raw 保持 1:1 raw-unit identity；PT 兑付 `uAsset` 使用 `Locked` / 四池初始化时记录的固定 backing ratio，不使用 `1 raw PT = 1 raw uAsset`。

### 4.3 preorder 语义

`preorder` 使用独立资金账本：

- 只在 `Genesis` 期开放
- 单独以 `uAsset` 记账
- 进入 `Locked` 时通过 preorder settlement 统一结算成 memecoin
- 后续按线性解锁领取

因此 preorder 不是普通 Genesis LP 份额，也不是立即可交易资产。

## 5. Genesis 结束后的两条分叉

### 5.1 募资失败 -> `Refund`

当 `endTime` 到达且募资未达最小门槛时，verse 进入 `Refund`：

- Genesis 参与者可退款
- preorder 参与者可退款
- 不进入后续流动性部署与 fee 分发路径

### 5.2 募资成功 -> `Locked`

当达到最小募资要求时，verse 进入 `Locked`，并发生一组强副作用：

- 部署 memecoin / POL
- 按治理链位置决定是否部署或预测 `yieldVault / governor / incentivizer`
- 按 POLend 四池模型创建 `memecoin/uAsset` 主池与 `POL/uAsset`、`PT/uAsset`、`PT/POL` 三个辅助池
- 若存在 preorder，则执行 preorder settlement
- 上述四池创建采用“Launcher 给出 desired budgets，Router 返回 actual execution”模型。创建是否成功以实际 spend / actual mint 为准，不以 preview/equality 为准。
- `memecoin/uAsset` 主池只记录实际执行后真正进入主池的资金与实际 mint 出的 `POL`；该结果同时决定 PT backing ratio 的记录口径。
- 辅助池 bootstrap 的 auxiliary underspend 处置（actual spend 记账、不施加独立 bootstrap backing / equality guard、不依赖独立 rounding-envelope 规则）见 [docs/spec/invariants.md](../invariants.md) INV-04。

这一时刻是“资产、池子、治理与收益组件同时就位”的分水岭。

## 6. Locked 运行期

`Locked` 是协议的主要运行阶段。

### 6.1 用户动作

用户可以：

- 通过 `claimNormalYT` 领取普通创世初始 YT
- 通过 POLend `claimLeveragedYT` 领取杠杆创世初始 YT
- 用 `uAsset + memecoin` 加池 mint 新 POL
- 领取线性解锁的 preorder memecoin

### 6.2 协议动作

协议可以：

- 从 `memecoin/uAsset` 主池与三个辅助池捕获 fee
- 主池 `memecoin/uAsset` fee 按 Memeverse 规则分流：`memecoin` fee 进入 yield 路径，`uAsset` fee 拆成 `executorReward + govFee` 后进入执行者奖励与 governor treasury 路径
- 辅助池 `POL/uAsset`、`PT/uAsset`、`PT/POL` fee 按 POLend 四池规则拆分：POL fee burn，普通侧 fee 进入普通领取账本，杠杆侧 `uAsset` fee 分发到 governor treasury 路径，杠杆侧 `PT` fee 在 settle 前走 `preRedeemPTFee`，settle 后走 `redeemPT`
- 普通用户领取历史辅助池 normal fee 时，`claimNormalFees` 使用 full-precision `mulDiv` 计算 entitlement，避免 `accUAssetFee` 或 `accPTFee` 较大时因中间乘法溢出导致可表示账本无法领取。
- 普通 PT fee 在 `settled=false` 时直接按份额转出 `PT`；在 `settled=true` 时改为按 `previewPTToUAsset` 确认 backing 后走 `redeemPT -> uAsset`。若该 backing 为零，则本次不标记为已领，留待后续重试。

`Locked` 后 `mintPOLToken` 使用 exact-liquidity minting，启动时记录的固定 PT backing ratio 是 PT/YT 经济真源；若报价后的实际执行无法 mint 出请求的 LP/POL 数量，则 mint 失败并整体回退。额外 backing 不得改写该经济关系。

### 6.3 启动期保护

V2 当前已实现的启动保护是：

- `launch fee window`
- `preorder settlement`

它们的作用是保护：

- 初始建池
- preorder settlement

它们不负责保护 `unlockTime` 之后的退出公平性。

## 7. unlockTime 到达后的保护窗口

这是 V2 生命周期里最关键的安全要求之一。

### 7.1 为什么必须存在

当 `unlockTime` 到达后，如果协议立刻允许：

- POL / genesis liquidity 赎回
- 普通公开 swap

那么先行动者可以：

1. 先赎回 LP 权益
2. 立即在公开市场卖出底层资产
3. 让后续赎回者面对更差的剩余池子状态

这会破坏：

- POL 公平退出
- Genesis 退出价值的一致性
- POL Lend / PT-YT 类模块所依赖的全局结算窗口

因此 `post-unlock liquidity protection period` 不是外围增强，而是安全前提。

### 7.2 保护窗口内应允许什么

- `redeemMemecoinLiquidity(verseId, amountInPOL)` / `redeemMemecoinLiquidity(verseId, amountInPOL, unwrap)`：burn `amountInPOL` 后令 `amountInLP = amountInPOL`；烧毁由 launcher 代理凭 allowance 代执行，调用前须先把 launcher 代理 approve 为 POL spender（额度 ≥ `amountInPOL`），否则回退 `ERC20InsufficientAllowance`；`unwrap=false` 转出 `memecoin/uAsset` LP token，`unwrap=true` 移除 LP 并发送底层 `memecoin` 与 `uAsset`
- `redeemAuxiliaryLiquidity`
- `POLSplitter.redeemPT / redeemYT`
- POLend leveraged residual claims
- 按产品定义允许的兼容性补池行为

当前实现的解锁迁移同交易 settlement 顺序与公开 swap 恢复时间写入约束见 [docs/spec/invariants.md](../invariants.md) INV-07A（窗口存在性论证见 INV-12；数值见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)）。迁移步骤为：`POLSplitter.settle(...)`、可选 `POLend.executeGlobalSettlement(...)`、hook 的 `publicSwapResumeTime` 写入；hook-side public swap protection 在该写入后生效；不声明 settlement callback window 由 launcher-side transient gate 或已生效的公开 swap block 保护。

- 进入 `Unlocked` 后，普通赎回可用性由阶段与各函数自身条件决定；公开 swap 仍由 hook 的保护时间单独阻断。
- bootstrap residual 的 normal share 通过 `redeemAuxiliaryLiquidity` 发放；leveraged share 通过 POLend 的 leveraged auxiliary settlement 输出发放。协议不保留一个永久 launcher bucket 来长期托管这类 residual。

### 7.3 保护窗口内必须禁止什么

- 普通公开 swap
- 绕过公开入口的等价 swap 路径
- 任何会改变后续赎回价值基准的公开市场行为

### 7.4 公开 swap 保护状态

- verse 需先到达 `unlockTime`，然后在实际 `changeStage()` 调用里进入 `Unlocked`
- launcher 在 settlement 调用完成后，按 `block.timestamp + UNLOCK_PROTECTION_WINDOW` 为受保护池写入 `publicSwapResumeTime`（窗口数值与配置面见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)；结算顺序与保护窗口的不变量见 [docs/spec/invariants.md](../invariants.md) INV-07A 与 INV-12）
- hook 在 `beforeSwap` 中读取该 pool-level 时间；未到期时继续拒绝受保护 pair 的公开 swap
- `UNLOCK_PROTECTION_WINDOW` 是正常 `Locked -> Unlocked` 且 `launcher` binding 指向真实 Launcher proxy 时写入的固定 24 小时窗口；Hook owner 无直接 resume-time setter，但可 retarget `launcher` 至受控地址间接覆写，非无权限外部调用者能力。binding 偏离真实 Launcher proxy 会使正常迁移回滚，调用 `changeStage` 前须恢复真实 binding；详见 INV-12 / operations §3.8。

公开 swap 恢复时间锚定实际 `Locked -> Unlocked` 迁移调用，赎回开放与公开 swap 恢复分别由 stage 和 pool-level 时间控制。

## 8. 真正完全解锁的市场状态

只有在 `post-unlock liquidity protection period` 结束后，协议才应恢复：

- 无限制公开 swap
- 退出与公开市场行为同时存在的自由状态

因此，“`unlockTime` 到达”“实际进入 `Unlocked`”和“市场完全开放”在产品语义上不是同一时刻。

## 9. 生命周期中的三类保护

### 9.1 启动保护

- `launch fee window`
- `preorder settlement`

保护目标：启动建池与 preorder settlement。

### 9.2 阶段保护

- `Genesis`
- `Refund`
- `Locked`
- `Unlocked`

保护目标：确保流程顺序与账本动作不越阶段执行。

### 9.3 解锁后保护

- `post-unlock liquidity protection period`

保护目标：保证公平退出与统一结算窗口。

## 10. 生命周期中的关键资金流

- Genesis 入金按 POLend 四池规则进入主池与辅助池路径。
- preorder 单独积累，直到进入 `Locked` 时统一换成 memecoin。
- `Locked` 期主池与辅助池 fee 会按 POLend 四池规则拆成 burn、执行者奖励、governor treasury 收入、普通 fee 与 yield 收入。
- 实际 `Locked -> Unlocked` 迁移完成后，协议应优先保障 POL 与 Genesis LP 的退出，而不是立即恢复公开市场竞争。

## 11. 当前生命周期规则

生命周期包含：

- 注册 -> `Genesis` -> `Locked/Refund` 的主流程
- preorder
- launch 保护
- `Locked` / `Unlocked` 的赎回路径

- 保护窗口由 stage、解锁迁移交易时间与 swap 行为联合表达；运维与索引器按这三个信号解释保护状态

## 12. 相关真源与证据

- [docs/spec/protocol.md](../protocol.md)
- [docs/spec/verse/state-machines.md](state-machines.md)
- [docs/spec/verse/accounting.md](accounting.md)
- [docs/spec/invariants.md](../invariants.md)
- [docs/TRACEABILITY.md](../../TRACEABILITY.md)
- [docs/spec/swap/swap-flow.md](../swap/swap-flow.md)
