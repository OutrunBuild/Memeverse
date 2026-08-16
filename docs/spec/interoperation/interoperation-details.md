# MemeverseV2 跨链互操作细化说明

## 1. 目标

本文解释治理收益跨链投递与 memecoin 跨链 staking 两条主路径的角色分工、消息方向和安全约束。

## 2. 主要模块

- `YieldDispatcherUpgradeable`
  - 处理治理收益路由
  - 接收 OFT（Omnichain Fungible Token，跨链同质化代币）`compose`（组合回调：OFT 在目标链完成 `lzReceive` 后，由 LayerZero endpoint 另行调用 `lzCompose` 处理附带 payload）或 launcher 通过 `distributeSameChain` 进入本地 fast path
- `MemeverseOmnichainInteroperation`
  - 用户侧 memecoin staking 入口
  - 根据治理链位置决定本链或异链路径
- `OmnichainMemecoinStaker`
  - 治理链侧接收跨链 staking compose
  - 把 memecoin 存入 yieldVault；异链 compose 时若目标 vault 不存在，走 `fallback`（回退路径），直接把到账 memecoin 转给 receiver

## 3. 治理收益分发路径

### 3.1 本链治理

当治理链就是当前链时：

- launcher 先把 token 转给 `YieldDispatcherUpgradeable`
- 再由 launcher 直接调用 `YieldDispatcherUpgradeable.distributeSameChain`

因此本链场景并不一定经过真正的跨链 message round-trip。

### 3.2 异链治理

当治理链在远端时：

- launcher 先构造 OFT send 参数
- token 通过 OFT 发送到治理链
- 治理链先在 `lzReceive` 阶段接收 OFT，再由 LayerZero endpoint 调用 `YieldDispatcherUpgradeable` 的 `lzCompose` compose 回调完成最终路由

### 3.3 两类 token 的终点

跨链 payload 中的 `amount` 使用 `asset-denominated`（资产计价）口径：数值表示该 token 自身的 OFT `amountLD`/underlying 数量，不转换成法币、另一种 token 或 share 数量。`amountLD` 是该 token 在该链本地 decimals 表示下的 raw amount（原始 token 数量），不是 share 数量，也不是跨 token unit。跨链传输和终点记账必须保持同一资产单位。

- `TokenType.MEMECOIN`
  - receiver 为合约时 -> `YieldVault.accumulateYields`
  - receiver 不是合约时 -> burn
- `TokenType.UASSET`
  - receiver 为合约时 -> `Governor.receiveTreasuryIncome`
  - receiver 不是合约时 -> `_transferOut` 到 `protocolTreasury`（路由协议金库，非 burn）

> no-code receiver 现按 `tokenType` 分流：MEMECOIN 走 `IBurnable(token).burn(amount)`（`isBurned = true`）；UASSET 走 `_transferOut(token, protocolTreasury, amount)`（`isBurned` 恒为 `false`——uAsset 是仓库外 OFT，无公开单参 `burn(uint256)`，原为 revert/滞留，现改为路由 `protocolTreasury`）。该 UASSET→`protocolTreasury` 路由仅经 permissionless 直接 OFT send 命名 EOA/无代码 receiver 时可达（协议发送端恒编码 `governor`/`yieldVault`），sender 自有 uAsset 等同捐赠给 `protocolTreasury`（原为 revert/滞留）。`protocolTreasury` 为协议级单一金库，经 `initialize` 传入、`onlyOwner` 的 `setProtocolTreasury` 可改（非零校验）。

因此 `YieldDispatcherUpgradeable` 不是只处理 memecoin yield，而是统一处理 yield / treasury 两类协议收入。

### 3.4 Compose 失败后的 retry

这里的 `retry`（重试）是重新执行尚未成功的目标链处理，不是重新发起一次源链 send。源链 OFT send 成功后，目标链的 `lzReceive` 或 `lzCompose` 失败不会回滚源链状态；LayerZero 可在目标链重新投递/执行消息。对于未执行的 memecoin yield compose，`MemecoinYieldVault.reAccumulateYields(address dispatcher, bytes32 guid, bytes calldata message)` 是 permissionless（无需权限、任何地址可调用）的恢复入口：

1. 委托 `IYieldDispatcher(dispatcher).settlePendingCompose(asset, guid, message)`；`settlePendingCompose` 内部完成全部结算——settle 在 approve 前先做 token↔vault 的 `asset()` 绑定校验（`TokenVaultMismatch`，本轮 code writer 同步落地），通过后 approve 本 vault 再调 `accumulateYields`，由 vault 的 `accumulateYields` 一步完成 pull + `totalAssets` 记账（空 vault 时按现有规则 burn；零金额 payload 在 settle 入口直接以 `ZeroInput` 拒绝、不改变状态、`(token, guid)` 槽位保持 `None`；零金额 lzCompose 对除自引用分支外的全部分支（vault / EOA / governor）均收敛（零金额自引用帧被 `lzCompose` 自引用守卫先于 `_settle` 拦截、emit `ComposeRejected(guid, token, 0)`，见 operations.md §3.13）——`_settle` 在 amount==0 时短路（不 burn、不记账），置 `Settled` + emit `OFTProcessed(amount=0, burnedAtDispatcher=false)`，endpoint 状态机收敛到 `ComposeDelivered`），vault 无独立本地记账步骤；`dispatcher` 由调用者按 compose 实际投递的 composer 提供（即 endpoint `ComposeSent` 事件的 `to` 字段，与 message 同源获取）；`verifySettle` 读 `composeQueue(token, dispatcher, guid, 0)` 在运行时校验该 dispatcher（错地址的失败形态取决于该地址：无代码地址 → 空数据 revert、无具名错误；有代码同接口 dispatcher → `NotDelivered`；误传 staker：真实 staking message → `NotComposeBeneficiary`（内层 receiver=staking 用户 ≠ vault，入口门先触发）、yield message → `NotDelivered`（staker 队列槽空）；`NotBeneficiary` 仅直连 `OmnichainMemecoinStaker.settlePendingCompose` 时出现（§3.13.1）（特例：内层 receiver 恰为 vault 的 staking 帧会经 staker settle 裸转至 vault——staker 的 msg.sender==receiver 被 vault 自洽满足，金额限发送者自身 amountLD、资金惰性滞留 vault，属自伤类）），vault 不存储 dispatcher（initialize 不接收 dispatcher 参数），恢复调用必须传 compose 实际投递的 dispatcher（launcher `setYieldDispatcher` 旋转后可能是历史 dispatcher）。入口自校验：`reAccumulateYields` 先校验 message 长度（<108 字节 revert `ComposeMessageTooShort`）、再校验 message 内层 receiver 为本 vault（否则 revert `NotComposeBeneficiary`）、再断言 settle 返回金额非零（否则 revert `ComposeSettlementFailed`）——零金额 × <108 字节帧在 vault 入口先 revert `ComposeMessageTooShort`（长度闸先于 `ZeroInput`）；错传 message 或返回零金额的壳/空实现 dispatcher 不再静默成功（返回非零金额的伪实现仍会静默成功、无入口信号，对账仍须以 `ComposeSettled`/`Released` 与资金核对为准）。receiver word 高位脏但低 160 位恰为本 vault 的自造帧会通过入口门、随后在 dispatcher 处 revert（≥140 字节帧：严格 `abi.decode` 空数据回退；108-139 字节带：具名 `MalformedComposeMsg` 长度守卫）——槽位保持 `None`、可重试，按错误名 grep 的监控对此类不应期待 `NotComposeBeneficiary`。`message` 从 endpoint `ComposeSent` 事件原样拷贝（按 `guid` 过滤、`to` 为本 dispatcher 的事件），重建步骤见 [layerzero-oapp-oft.md §4](layerzero-oapp-oft.md)。

该入口只处理仍未结算（sentinel 为 `ComposeState.None`）的 compose transfer；它是 destination accumulation 的 retry path，不会撤销已经成功完成的 source send。

## 4. 跨链 staking 路径

### 4.1 本链治理

若治理链在本链：

- 用户直接经 `MemeverseOmnichainInteroperation` 把 memecoin 存入 yieldVault
- `msg.value` 必须为 0
- 若 `yieldVault.code.length == 0`，交易直接回滚；本链 staking 不使用缺失 vault 的 fallback transfer
- vault 存在时，直接调用 vault `deposit(amount, receiver)`，不经过 LayerZero
- 本链分支对 verse vault 授无限额度（`MemeverseOmnichainInteroperation.sol::memecoinStaking` 本地分支 `_safeApproveInf(memecoin, yieldVault)`）——vault `deposit` 经 `transferFrom` 拉款的授权机制；与目标链 staker 的精确授权纪律相反（staker `lzCompose` 仅授精确 `amount`，不授无限额度，见 [layerzero-oapp-oft.md](layerzero-oapp-oft.md)）

### 4.2 异链治理

若治理链在远端：

- 用户先 quote
- `msg.value` 必须精确匹配报价
- memecoin 通过 OFT 发到治理链
- `OmnichainMemecoinStaker` 在 compose 中完成最终 deposit / fallback transfer：vault 有 code 时调用 `deposit(amount, receiver)`，vault 无 code 时直接把到账数量转给 receiver
- 非整数倍金额（`amount % decimalConversionRate != 0`）：OFT `send` 只烧掉截断后的 `amountSentLD`，同一交易内把未烧余数（`amount - amountSentLD`）经 `_transferOut` 退回 `msg.sender`（源链），无滞留；退款量以 `amountSentLD`（实际烧毁量，守恒推导）为准而非 `amountReceivedLD`——默认 memecoin OFT 两者相等（`OutrunOFTCoreInit.sol::_debitView`），未来 fee-taking OFT 使其相异时需重审
- 亚尘金额（`amount < decimalConversionRate`，OFT 截断到零）在 `_transferIn` 之前即被 `_requireNonZeroRemoteDelivery` 以 `DustAmount()` 拒绝——被拒金额零资金移动、零跨链费损失

### 4.3 本链/异链失败矩阵

| 路径/阶段 | 条件 | 结果 |
| --- | --- | --- |
| 本链 staking | `msg.value != 0` | 以 `InvalidLzFee(0, msg.value)` 回滚源交易，不执行 deposit。 |
| 本链 staking | vault 无 code | 以 `EmptyYieldVault()` 回滚源交易，不转给 receiver。 |
| 异链 staking 源链 | `msg.value` 不等于精确报价，或 OFT `send` 失败 | 源交易回滚；同一交易内的 token pull/状态变化不保留。 |
| 异链 destination | 源链 send 已成功，但 destination `lzReceive` 失败 | 不回滚源链状态；LayerZero 重新尝试目标消息。 |
| 异链 destination compose | `lzReceive` 已成功，但 `lzCompose` 失败 | 不回滚源链状态；compose 通过 LayerZero 重试，未执行的 yield compose 可经 `MemecoinYieldVault.reAccumulateYields(dispatcher, guid, message)` 恢复（`dispatcher`/`message` 取自 endpoint `ComposeSent` 事件，见 §3.4；分步操作见 operations.md §3.13）。 |
| 异链 staking compose | vault 有 code | `lzCompose` 置 Settled（CEI）后完成 deposit；失败整体回滚，guid 保持 None 可重试。 |
| 异链 staking compose | vault 有 code 但 `amount` 映射 0 份额 | `deposit` revert `ZeroSharesDeposit()`；资金由 staker（composer）托管、compose 消息滞留 endpoint 队列，`settlePendingCompose(token, guid, message)` 兜底结算，释放滞留资金给 message 编码的接收方。receiver==staker 帧除外：settle 因 `NotBeneficiary` 恒不可达（`msg.sender` 永不为 staker 合约自身），归自伤边界（见 operations.md §3.13.1「自伤自负」bullet）。staker 侧另对非零金额 deposit 返回值做非零校验（amount 门控、豁免零金额），vault 变体「返回 0 不 revert」同样在 staker 侧 revert ZeroSharesDeposit 并走同一兜底路径。(receiver==staker 帧仍归上句自伤边界、不适用兜底路径) |
| 异链 staking compose | vault 无 code | 走 fallback，置 Settled（CEI）后直接转给 receiver；失败整体回滚，guid 保持 None 可重试。 |
| 异链 staking 源链 | 亚尘金额（`amount < decimalConversionRate`，OFT 截断到零） | 前置 `DustAmount()` 回滚，先于 `_transferIn`，调用方代币零移动。 |

### 4.4 阶段与 vault 部署状态

跨链 staking 无 verse 阶段门控：`MemeverseOmnichainInteroperation.sol::memecoinStaking` 与 `::quoteMemecoinStaking` 的异链/远端分支均不检查 verse 阶段或 gov 链 vault 部署状态（本链分支的 vault-code 检查见 §4.1 与 §4.3）。compose 消息编码的 vault word 取源链本地 `verse.yieldVault`（`MemeverseOmnichainInteroperation.sol::_buildStakingSendParam` 编码 composeMsg；该字段的唯一赋值点 `MemeverseLaunchImpl.sol::_deployAndSetupMemeverse` 内 `verse.yieldVault = yieldVault` 仅在源链完成 Genesis→Locked 后执行）。`MemeverseLauncherUpgradeable.sol::changeStage` 为 per-chain、permissionless 的本地执行（无跨链同步），故 vault-absent fallback 的触发面包含两种情形：① 源链未完成 Genesis→Locked——compose 的 vault word 取源链本地 `verse.yieldVault`，此时为零地址，即使 gov 链 vault 已部署（部署顺序完全正确），远端 staking 仍静默降级；② gov 链未进入 Locked——gov 链仍在 Genesis 或进入 Refund 终态（Refund 后 vault 永不部署）时，其 yieldVault 未部署。两种情形下远端 staking 的 compose 均在 `OmnichainMemecoinStaker.sol::lzCompose` 命中 vault-absent fallback（含脏/零 vault word 处理），到账 memecoin 直接转给 receiver——非质押、无 vault 份额/投票权。`quoteMemecoinStaking` 仅返回 LZ fee，不反映目标链 vault 部署状态，调用方无法在发送前得知该降级。多链 verse 应确保 gov 链与所有可能发起 staking 的源链均先完成 Genesis→Locked，避免静默降级。

### 4.5 金额截断、余量退款与源链事件语义

异链 staking 的 OFT 发送把 `amountLD` 截断为 `decimalConversionRate` 的整数倍：源链实际烧毁额 = `amountSentLD`，目的链到账/质押额 = `amountReceivedLD`（默认实现两者相等，fee-taking OFT 例外及退款机制见 §4.2）。

`OmnichainMemecoinStaking` 事件仅在异链分支 emit，字段语义：`amount` 为用户原始输入额；`amountSentLD` 为源链实际烧毁/质押额（截断后）；`remainder` 为同交易退款额。索引器/对账方核对「质押 + 退款」完整性直接使用 `amountSentLD + remainder == amount`，无需再依赖 OFT 的 `OFTSent` 事件或自行复算 rate。本链分支（§4.1）不 emit 本事件、不发生截断/退款。

## 5. 为什么要求 exact fee

规则本体（`msg.value` 严格等于 quote，远端分发与远端 staking 都不是”至少足额”）见 [docs/spec/invariants.md INV-06](../invariants.md)。

这条规则的作用是：

- 让脚本与调用方先 quote 再执行
- 降低跨链费用处理中的不确定性
- 避免把 fee 误差变成隐含状态

## 6. compose 回调与 replay 防护

`YieldDispatcherUpgradeable` 和 `OmnichainMemecoinStaker` 都依赖 compose 回调处理跨链到账。

replay 防护规则本体（endpoint 路径检查 `guid` 未执行、置 Settled（CEI）后结算，`Released` 态幂等放行）见 [docs/spec/invariants.md INV-10](../invariants.md) 与 [docs/spec/interoperation/layerzero-oapp-oft.md §4](layerzero-oapp-oft.md)。

这样做的目的，是避免重复到账、重复记账或重复 staking。

## 7. fallback 语义

在治理收益或异链 staking 到达治理链时，如果目标 receiver / yieldVault 不存在：

- 不会默默保留悬空余额
- 治理收益的非合约 receiver 按 tokenType 分流：MEMECOIN → burn；UASSET → `_transferOut` 到 `protocolTreasury`（UASSET no-code 的 `isBurned` 恒为 `false`，自伤捐赠语义见 §3.3）
- 异链 staking 的缺失 yieldVault 直接 fallback transfer 给 receiver

本链 staking 的缺失 yieldVault 是显式回滚条件，不属于 fallback。

因此跨链互操作不是“最佳努力存放”，而是有明确失败出口的。

## 8. 当前实现提醒

- 本链 fast path 和异链 compose path 共享同一个高层收益路由语义
- `YieldDispatcherUpgradeable` 是当前业务语义名称，应作为跨链收益路由模块的正式称呼
- 互操作路径里的安全关键点不是 UI 或脚本，而是链上 exact fee 与 replay 防护

## 9. 相关真源与证据

- [docs/spec/interoperation/layerzero-oapp-oft.md](layerzero-oapp-oft.md)
- [docs/spec/verse/accounting.md](../verse/accounting.md)
- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/invariants.md](../invariants.md)
- [docs/spec/verse/deployment.md](../verse/deployment.md)
