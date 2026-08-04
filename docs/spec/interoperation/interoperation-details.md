# MemeverseV2 跨链互操作细化说明

## 1. 目标

本文解释治理收益跨链投递与 memecoin 跨链 staking 两条主路径的角色分工、消息方向和安全约束。

## 2. 主要模块

- `YieldDispatcher`
  - 处理治理收益路由
  - 接收 OFT `compose`（组合回调：OFT 在目标链完成 `lzReceive` 后，由 LayerZero 另行调用 `lzCompose` 处理附带 payload）或 launcher 本地 fast path
- `MemeverseOmnichainInteroperation`
  - 用户侧 memecoin staking 入口
  - 根据治理链位置决定本链或异链路径
- `OmnichainMemecoinStaker`
  - 治理链侧接收跨链 staking compose
  - 把 memecoin 存入 yieldVault；异链 compose 时若目标 vault 不存在，走 `fallback`（回退路径），直接把到账 memecoin 转给 receiver

## 3. 治理收益分发路径

### 3.1 本链治理

当治理链就是当前链时：

- launcher 先把 token 转给 `YieldDispatcher`
- 再由 launcher 直接调用 `YieldDispatcher.distributeSameChain`

因此本链场景并不一定经过真正的跨链 message round-trip。

### 3.2 异链治理

当治理链在远端时：

- launcher 先构造 OFT send 参数
- token 通过 OFT 发送到治理链
- 治理链先在 `lzReceive` 阶段接收 OFT，再由 `YieldDispatcher` 的 `lzCompose` compose 回调完成最终路由

### 3.3 两类 token 的终点

跨链 payload 中的 `amount` 使用 `asset-denominated`（资产计价）口径：数值表示该 token 自身的 OFT `amountLD`/underlying 数量，不转换成法币、另一种 token 或 share 数量。跨链传输和终点记账必须保持同一资产单位。

- `TokenType.MEMECOIN`
  - receiver 为合约时 -> `YieldVault.accumulateYields`
  - receiver 不是合约时 -> burn
- `TokenType.UASSET`
  - receiver 为合约时 -> `Governor.receiveTreasuryIncome`
  - receiver 不是合约时 -> burn

因此 `YieldDispatcher` 不是只处理 memecoin yield，而是统一处理 yield / treasury 两类协议收入。

### 3.4 Compose 失败后的 retry

这里的 `retry`（重试）是重新执行尚未成功的目标链处理，不是重新发起一次源链 send。源链 OFT send 成功后，目标链的 `lzReceive` 或 `lzCompose` 失败不会回滚源链状态；LayerZero 可在目标链重新投递/执行消息。对于未执行的 memecoin yield compose，`MemecoinYieldVault.reAccumulateYields(bytes32 lzGuid)` 是 permissionless（无需权限、任何地址可调用）的恢复入口：

1. 调用 `withdrawIfNotExecuted(lzGuid, address(this))`，把该 guid 对应且尚未执行的 compose transfer 提取到 YieldVault；
2. 把提取到的数量交给与本地 `accumulateYields` 相同的 accumulation path；有 share 时增加 `totalAssets` 并写 checkpoint，空 vault 时按现有规则 burn，零数量则不改变状态。

该入口只处理仍未标记为 executed 的 compose transfer；它是 destination accumulation 的 retry path，不会撤销已经成功完成的 source send。

## 4. 跨链 staking 路径

### 4.1 本链治理

若治理链在本链：

- 用户直接经 `MemeverseOmnichainInteroperation` 把 memecoin 存入 yieldVault
- `msg.value` 必须为 0
- 若 `yieldVault.code.length == 0`，交易直接回滚；本链 staking 不使用缺失 vault 的 fallback transfer
- vault 存在时，直接调用 vault `deposit(amount, receiver)`，不经过 LayerZero

### 4.2 异链治理

若治理链在远端：

- 用户先 quote
- `msg.value` 必须精确匹配报价
- memecoin 通过 OFT 发到治理链
- `OmnichainMemecoinStaker` 在 compose 中完成最终 deposit / fallback transfer：vault 有 code 时调用 `deposit(amount, receiver)`，vault 无 code 时直接把到账数量转给 receiver

### 4.3 本链/异链失败矩阵

| 路径/阶段 | 条件 | 结果 |
| --- | --- | --- |
| 本链 staking | `msg.value != 0` | 以 `InvalidLzFee(0, msg.value)` 回滚源交易，不执行 deposit。 |
| 本链 staking | vault 无 code | 以 `EmptyYieldVault()` 回滚源交易，不转给 receiver。 |
| 异链 staking 源链 | `msg.value` 不等于精确报价，或 OFT `send` 失败 | 源交易回滚；同一交易内的 token pull/状态变化不保留。 |
| 异链 destination | 源链 send 已成功，但 destination `lzReceive` 失败 | 不回滚源链状态；LayerZero 重新尝试目标消息。 |
| 异链 destination compose | `lzReceive` 已成功，但 `lzCompose` 失败 | 不回滚源链状态；compose 通过 LayerZero 重试，未执行的 yield compose 也可转入 `reAccumulateYields` 恢复路径。 |
| 异链 staking compose | vault 有 code | `lzCompose` 完成 deposit；成功后才标记该 guid 已执行。 |
| 异链 staking compose | vault 无 code | 走 fallback，直接转给 receiver；转账成功后才标记该 guid 已执行。 |

## 5. 为什么要求 exact fee

规则本体（`msg.value` 严格等于 quote，远端分发与远端 staking 都不是”至少足额”）见 [docs/spec/invariants.md INV-06](../invariants.md)。

这条规则的作用是：

- 让脚本与调用方先 quote 再执行
- 降低跨链费用处理中的不确定性
- 避免把 fee 误差变成隐含状态

## 6. compose 回调与 replay 防护

`YieldDispatcher` 和 `OmnichainMemecoinStaker` 都依赖 compose 回调处理跨链到账。

replay 防护规则本体（endpoint 路径检查 `guid` 未执行、成功后标记已执行）见 [docs/spec/invariants.md INV-10](../invariants.md) 与 [docs/spec/interoperation/layerzero-oapp-oft.md §4](layerzero-oapp-oft.md)。

这样做的目的，是避免重复到账、重复记账或重复 staking。

## 7. fallback 语义

在治理收益或异链 staking 到达治理链时，如果目标 receiver / yieldVault 不存在：

- 不会默默保留悬空余额
- 治理收益的非合约 receiver 按当前规则 burn
- 异链 staking 的缺失 yieldVault 直接 fallback transfer 给 receiver

本链 staking 的缺失 yieldVault 是显式回滚条件，不属于 fallback。

因此跨链互操作不是“最佳努力存放”，而是有明确失败出口的。

## 8. 当前实现提醒

- 本链 fast path 和异链 compose path 共享同一个高层收益路由语义
- `YieldDispatcher` 是当前业务语义名称，应作为跨链收益路由模块的正式称呼
- 互操作路径里的安全关键点不是 UI 或脚本，而是链上 exact fee 与 replay 防护

## 9. 相关真源与证据

- [docs/spec/interoperation/layerzero-oapp-oft.md](layerzero-oapp-oft.md)
- [docs/spec/verse/accounting.md](../verse/accounting.md)
- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/invariants.md](../invariants.md)
- [docs/spec/verse/deployment.md](../verse/deployment.md)
