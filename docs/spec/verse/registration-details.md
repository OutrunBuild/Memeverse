# MemeverseV2 注册链路细化说明

## 1. 目标

本文细化 V2 的注册链路，解释注册中心、local registrar、omnichain registrar 与 launcher 之间的职责分工、时间权威与副作用顺序。

## 2. 角色分工

- `MemeverseRegistrationCenter`
  - 注册参数校验
  - symbol 占用管理
  - `uniqueId/endTime/unlockTime` 生成
  - 本链/异链 fan-out
- `MemeverseRegistrarAtLocal`
  - 本链报价与本链注册入口
  - 接收 center 的本地注册调用
- `MemeverseRegistrarOmnichain`
  - 异链向中心链发起注册
  - 负责跨链 quote/send
- `MemeverseLauncherUpgradeable`
  - 接收最终注册结果
  - 记录 verse 主状态与资产地址

## 3. 注册参数校验顺序

center 当前负责检查：

- `durationDays` 是否落在允许区间
- `name/symbol/uri/desc` 长度是否合法
- `uAsset` 是否在支持列表内
- `omnichainIds` 长度是否合法
- `omnichainIds` 去重后再继续分发

因此注册中心不是简单转发器，而是时间与参数的权威入口。

## 4. Symbol 生命周期

一个 symbol 在中心链上的语义状态（`Available` / `Active` / `Historical`）、迁移条件与归档规则以 [docs/spec/verse/state-machines.md §3.1](state-machines.md) 迁移表为 canonical 真源；registration 流程下如何触发这些迁移见本文档 §7 / §8。

## 5. uniqueId 与 nonce

当前实现会使用 symbol 的历史 nonce 与当前参数生成新的 `uniqueId`。

关键含义：

- symbol 可被重复使用，但每次成功注册都是新的 verse 实例
- `uniqueId` 不是单纯的 symbol hash，而是带有注册序列含义

## 6. 时间权威来源

注册链路最容易误解的部分是时间语义。

当前 V2 的权威时间来源是注册中心写入值（`endTime` / `unlockTime`）：

- center 不重算，以 registrar 传入值为准；本地报价读取中心 `DAY`，中心写入为最终来源，并写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`。权威语义完整约束见 [docs/spec/invariants.md](../invariants.md) INV-11；`DAY` / `FIXED_LOCKUP_DURATION` 数值与配置面见 [docs/spec/verse/config-matrix.md §3](config-matrix.md)。

## 7. 本链注册路径

本链路径的核心步骤是：

1. 用户或上层入口先做 quote
2. 调用 center 的 `registration`
3. center 生成 `uniqueId/endTime/unlockTime`
4. center 直接调用 `MemeverseRegistrarAtLocal.localRegistration`
5. local registrar 调用 launcher：
   - `registerMemeverse`
   - `setExternalInfo`

这个路径中，center 是时间和 symbol 状态的唯一权威。

## 8. 异链注册路径

异链路径的核心步骤是：

1. 用户在异链调用 omnichain registrar 相关入口
2. omnichain registrar 向中心链发送注册请求
3. center 完成校验与时间生成
4. center 对目标链执行 fan-out
5. 目标链 registrar 最终把结果落库到 launcher

这里的关键边界是：

- 中心链负责决定 symbol 是否可注册
- 中心链负责决定 `unlockTime`
- 异链 registrar 不拥有最终时间解释权

## 9. fan-out 与 fee

`MemeverseRegistrationCenter.quoteSend` 负责累计所有目标链 fan-out 的 native fee。

规则要点：

- 本链目标 fee 为 0
- 异链目标按 LayerZero quote 累加
- 任一目标链没有 endpoint 映射会直接回退

因此一次注册成功，不只是参数合法，还要求所有目标链的 fan-out 前提成立。

### Registration gas dust semantics

`quoteRegister` / `quoteSend` 返回的是最低或预估 native fee 需求，不是所有路径都必须精确支付的统一规则。

路径差异：

- spoke/source omnichain registrar -> hub：source 链 LayerZero send 使用 `refundAddress = user/caller`，source 侧超额 native fee 可退回 caller。
- local registrar -> center：`msg.value` 必须等于转发给 center 的 `value` 参数；该转发预算可以高于 center quote。
- hub/center -> other spokes fan-out：center 要求 `msg.value >= totalFee`；每个 outbound send 使用对应目标链的 `fee`；LayerZero `refundAddress` 是 center 自身；剩余或退回 native 作为 center gas dust 留在 center。

center gas dust 不可由用户认领，只能由 owner 通过 `removeGasDust(receiver)` 清理。

前端默认应使用 quote 的精确值；只有明确需要 hub gas buffer 时才额外加 buffer，且 hub 残余不保证退回原用户。

## 10. launcher 侧执行顺序

注册成功后，launcher 侧目标产品执行顺序应是：

1. 校验 `registrar` 权限，且 `polend` 与 `polSplitter` 已配置
2. 通过 deployer 部署并初始化 memecoin / POL
3. 按 `omnichainIds` 配置 peer
4. 写入 verse 基础信息与反向索引
5. 在同一笔 `registerMemeverse(...)` 交易内调用 `POLendUpgradeable.registerLendMarket(verseId)`，注册 lend market，并记录 / 复制该 verse 的 `uAsset`、利率和初始状态
6. 发出 `RegisterMemeverse`
7. registrar 后续再调用 `setExternalInfo` 写入 `uri/desc/communities`

这样设计意味着：

- 注册并不是“只写一个数据库记录”
- 它会同时完成 memecoin / POL 部署初始化和 lend market 注册
- `polend` / `polSplitter` 是注册前必备前置配置
- `POLSplitterUpgradeable.initializeVerse(...)` 不在注册时执行，而是在 `Genesis -> Locked` 流程中由 launcher 调用
- `external info` 不在 `registerMemeverse(...)` 同一次函数体内写入，而是由 registrar 在后续调用中补写

## 11. POLendUpgradeable 注册 ABI 与初始化边界

POLendUpgradeable 目标产品规范以 [docs/spec/polend/README.md](../polend/README.md) 为准：

- `Launcher.registerMemeverse(...)` 同交易内只调用 `POLendUpgradeable.registerLendMarket(verseId)`
- `registerLendMarket` 从 launcher 读取 verse 的 `uAsset` 并复制当前 `defaultInterestRate`
- 注册阶段不初始化 `PT / YT`
- `POLSplitterUpgradeable.initializeVerse(...)` 只在 `Genesis -> Locked` 的四池部署流程中执行

## 12. 当前实现提醒

- 时间权威语义见 §6（已收口到 INV-11）
- Agent 在分析注册和解锁行为时，必须优先相信 center 写入值

## 13. 相关真源与证据

- [docs/spec/verse/state-machines.md](state-machines.md)
- [docs/spec/protocol.md](../protocol.md)
- [docs/spec/verse/deployment.md](deployment.md)
- [docs/spec/invariants.md](../invariants.md)
- [docs/TRACEABILITY.md](../../TRACEABILITY.md)
