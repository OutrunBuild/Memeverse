# OFT Compose 退款机制重构设计

## 背景

### 当前问题

MemeverseV2 的跨链 compose（send-and-call）流程存在两类严重缺陷，根源相同：UBO（Ultimate Beneficiary Owner）机制把"受益方地址"取错了来源。

**COMMON-001（已裁决 TRUE PROBLEM / high）**：`OutrunOFTInit.withdrawIfNotExecuted` 在 OFT 接收方 `toAddress == address(0)` 时，因 `txStatus.composer` 存重映射前的 `address(0)` 而 `_credit` 已 mint 到 `0xdead`，导致退款路径 `_update(composer=0, receiver, amount)` 走 mint 分支二次铸造，造成跨链无限通胀。

**系统性失效（本设计重点）**：UBO 字段从 `_lzReceive:313` 的 `abi.decode(composeMsg, (address))` 取值，经字节级验证等价于 `send` 的 `msg.sender`（`OFTMsgCodec.encode:26` 自动塞入）。在 Outrun 真实 compose 路径里，`send` 由协议合约（Launcher / interoperation）在 delegatecall 或外部调用上下文发起，对 OFT 的 `msg.sender` = 源链发起合约，而退款的语义需要的是目的链上的资产受益方（vault / governor / receiver）。两者是不同合约、不同链，系统性对不上：

| compose 路径 | send 调用点 | UBO（当前） | 该收退款的（目的链） |
|---|---|---|---|
| gov fee 分发 | `MemeverseSettlementImpl:446` | Launcher（源链）| governor（目的链）|
| memecoin fee 分发 | `MemeverseSettlementImpl:450` | Launcher（源链）| yieldVault（目的链）|
| 全链质押 staking | `MemeverseOmnichainInteroperation:128` | interoperation（源链）| receiver（目的链）|

后果：
- `MemecoinYieldVault.reAccumulateYields` 调 `withdrawIfNotExecuted` 要求 `msg.sender == UBO`，但 vault ≠ Launcher，真实路径下必然 revert（现有测试用 `setQueuedAmount` mock storage 绕过此问题，是测试缺口）。
- `OmnichainMemecoinStaker` 无任何退款入口，staking compose 失败时资金永久卡死。
- review 文档 `docs/review/2026-08-03-codebase-multiround-review.md:701` 的"UBO==vault"判断错误，需纠正。

### 设计目标

1. 消除 COMMON-001 攻击面（to=0 二次 mint 通胀）。
2. 修复三路径 compose 失败退款系统性失效。
3. 回归 LayerZero 官方 OFTCore 范式：token 合约 mint 即终态，退款复杂度住在业务 composer 合约。
4. 受益方地址显式写进 composeMsg，不依赖 send 的 msg.sender。

### 约束

- 合约为 pre-deployment artifacts，可自由重构，无需兼容已部署合约、无需链上迁移脚本。
- `GenesisCredit` 继承官方 OFT（非 OutrunOFTInit），不受本改动影响。

---

## 架构总览

### 核心原则

1. **token 合约（OFT）回归最小职责** —— mint 即终态，删除第二资金路由（`withdrawIfNotExecuted`）。
2. **退款复杂度住在 composer 合约**（YieldDispatcher / Staker），用 LayerZero endpoint 公开状态做证明。
3. **受益方地址显式传递** —— 复用 composeMsg 已有的 receiver 字段，不靠 codec 自动塞的 msg.sender。

### 资金流（修复后，以 fee 分发 compose 失败为例）

```
源链: user 调 redeemAndDistributeFees
  → Launcher send({to: YieldDispatcher, composeMsg: abi.encode(vault, tokenType)})

目的链 _lzReceive（回归官方 OFTCore）:
  → mint amount 给 YieldDispatcher
  → sendCompose(YieldDispatcher, guid, 0, composeMsg)
  （不再存 UBO/composer/amount 状态）

[compose 失败：executor 没跑 lzCompose，或 lzCompose revert]

任何人调 YieldDispatcher.claimRefund(token, guid, message):
  → endpoint.composeQueue(token, YieldDispatcher, guid, 0) == keccak256(message)?  验证真实性
  → 该 slot != RECEIVED_MESSAGE_HASH（证明 lzCompose 没被执行过）
  → 解码 message 取受益方 = vault
  → composeState[guid] = Refunded（CEI 先置位）
  → _transferOut(token, vault, amount)

vault.reAccumulateYields 触发上述 claimRefund 后本地 _accumulateYield 入账
```

---

## 详细设计

### 第 1 层：token 合约改动（回归官方 OFTCore）

#### `src/common/omnichain/oft/OutrunOFTCoreInit.sol`

`_lzReceive` 回归官方 LayerZero OFTCore 语义（对照 `lib/LayerZero-v2/.../oapp/contracts/oft/OFTCore.sol:240-271`）：

```solidity
function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
    internal virtual override
{
    address toAddress = _message.sendTo().bytes32ToAddress();
    uint256 amountReceivedLD = _credit(toAddress, _toLD(_message.amountSD()), _origin.srcEid);

    if (_message.isComposed()) {
        bytes memory composeMsg = OFTComposeMsgCodec.encode(
            _origin.nonce, _origin.srcEid, amountReceivedLD, _message.composeMsg()
        );
        endpoint.sendCompose(toAddress, _guid, 0, composeMsg);
    }
    emit OFTReceived(_guid, _origin.srcEid, toAddress, amountReceivedLD);
}
```

**删除项**：
- `OFTCoreStorage.composeTxs` mapping（保留 `msgInspector`）。
- `getComposeTxExecutedStatus`。
- `notifyComposeExecuted`。
- `_lzReceive` 中写 `txStatus.composer/amount/UBO` 的逻辑。
- `is IOFTCompose` 继承声明。

#### `src/common/omnichain/oft/OutrunOFTInit.sol`

删除 `withdrawIfNotExecuted` override。`_credit` 的 `0→0xdead` remap 保留（官方 OFT 的 `_mint` 同样不收 address(0)，是必要防御）。

#### `src/common/omnichain/oft/IOFTCompose.sol`

整个文件删除。`ComposeTxStatus` / `notifyComposeExecuted` / `withdrawIfNotExecuted` / `AlreadyExecuted` / `PermissionDenied` 随 token 层机制消失。

### 第 2 层：composer 合约自托管退款

#### 状态模型（YieldDispatcher 与 Staker 共用模式）

每个 composer 新增互斥状态，解决 lzCompose 与 claimRefund 的竞争条件：

```solidity
enum ComposeState { None, Settled, Refunded }
mapping(bytes32 guid => ComposeState) public composeState;
```

- `lzCompose` 开头：`require(composeState[guid] == ComposeState.None, ...); composeState[guid] = ComposeState.Settled;`（CEI，先置位再 settle）。
- `claimRefund` 开头：`require(composeState[guid] == ComposeState.None, ...); composeState[guid] = ComposeState.Refunded;`。

双层防护：endpoint 的 `RECEIVED_MESSAGE_HASH`（防 lzCompose 自身重放）+ composer 的 `composeState`（防 lzCompose / claimRefund 跨路径竞争）。

#### `src/verse/YieldDispatcher.sol`

新增 `claimRefund`，composeMsg 格式为 `abi.encode(receiver, tokenType)`（`MemeverseSettlementImpl:160`），receiver = governor 或 yieldVault：

```solidity
function claimRefund(address token, bytes32 guid, bytes calldata message) external returns (uint256 amount) {
    require(composeState[guid] == ComposeState.None, AlreadyResolved());

    bytes32 queueHash = IMessagingComposer(localEndpoint).composeQueue(token, address(this), guid, 0);
    require(queueHash != bytes32(0), NotDelivered());
    require(queueHash != RECEIVED_MESSAGE_HASH, AlreadyExecuted());
    require(keccak256(message) == queueHash, InvalidProof());

    amount = OFTComposeMsgCodec.amountLD(message);
    (address receiver, TokenType tokenType) =
        abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, TokenType));

    composeState[guid] = ComposeState.Refunded;
    _transferOut(token, receiver, amount);
    emit RefundClaimed(guid, token, receiver, amount);
}
```

`lzCompose` 改动：删 `getComposeTxExecutedStatus` 检查与 `notifyComposeExecuted` 调用；开头加 `composeState[guid] == None` 检查与 `Settled` 置位（CEI 先于 `_settle`）。

#### `src/interoperation/OmnichainMemecoinStaker.sol`

同模式新增 `claimRefund`，composeMsg 格式为 `abi.encode(receiver, yieldVault)`（`MemeverseOmnichainInteroperation:119`）：

```solidity
function claimRefund(address memecoin, bytes32 guid, bytes calldata message) external returns (uint256 amount) {
    require(composeState[guid] == ComposeState.None, AlreadyResolved());

    bytes32 queueHash = IMessagingComposer(localEndpoint).composeQueue(memecoin, address(this), guid, 0);
    require(queueHash != bytes32(0), NotDelivered());
    require(queueHash != RECEIVED_MESSAGE_HASH, AlreadyExecuted());
    require(keccak256(message) == queueHash, InvalidProof());

    amount = OFTComposeMsgCodec.amountLD(message);
    (address receiver,) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, address));

    composeState[guid] = ComposeState.Refunded;
    _transferOut(memecoin, receiver, amount);
    emit RefundClaimed(guid, memecoin, receiver, amount);
}
```

`lzCompose` 改动：删 `getComposeTxExecutedStatus` 检查与 `notifyComposeExecuted` 调用；加 `composeState` CEI 置位。

### 第 3 层：vault 适配

#### `src/yield/MemecoinYieldVault.sol`

`reAccumulateYields` 改为调 `YieldDispatcher.claimRefund`（claimRefund 已将 token 转给本 vault），本地再 `_accumulateYield`。签名加 `message` 参数：

```solidity
function reAccumulateYields(bytes32 lzGuid, bytes calldata message) external override {
    uint256 yield = IYieldDispatcher(yieldDispatcher).claimRefund(asset, lzGuid, message);
    _accumulateYield(yieldDispatcher, yield);
}
```

接口 `IMemecoinYieldVault.reAccumulateYields` 签名同步。

### 关键依赖

- **`IMessagingComposer.composeQueue`**：`lib/LayerZero-v2/.../protocol/contracts/MessagingComposer.sol:13`，public mapping，LayerZero v2 稳定接口。用接口隔离，不直接依赖具体实现。
- **`RECEIVED_MESSAGE_HASH`**：`MessagingComposer.sol:11` = `bytes32(uint256(1))`。从 LayerZero lib import 常量，不本地硬编码。
- **`ComposeSent` 事件**：`MessagingComposer.sol:27`，链上 log，调用者据此拼装 `message` 传入 `claimRefund`。
- **`OFTComposeMsgCodec`**：`amountLD` / `composeMsg` 解码方法，LayerZero OFT 标准库，不变。

---

## 改动清单

### src/ 生产代码

| 文件 | 改动 | 性质 |
|---|---|---|
| `src/common/omnichain/oft/OutrunOFTCoreInit.sol` | 删 `composeTxs` mapping、`getComposeTxExecutedStatus`、`notifyComposeExecuted`；`_lzReceive` 回归官方；删 `is IOFTCompose` 继承 | 删除 |
| `src/common/omnichain/oft/OutrunOFTInit.sol` | 删 `withdrawIfNotExecuted` override | 删除 |
| `src/common/omnichain/oft/IOFTCompose.sol` | 整文件删除 | 删除 |
| `src/verse/YieldDispatcher.sol` | 加 `ComposeState` enum + `composeState` mapping + `claimRefund`；`lzCompose` 删旧检查/调用，加 CEI 置位 | 新增+修改 |
| `src/interoperation/OmnichainMemecoinStaker.sol` | 同 YieldDispatcher 模式 | 新增+修改 |
| `src/yield/MemecoinYieldVault.sol` | `reAccumulateYields` 改调 `claimRefund`，签名加 `message` | 修改 |
| `src/yield/interfaces/IMemecoinYieldVault.sol` | 接口签名同步 | 修改 |

### test/ 测试

| 文件 | 改动 |
|---|---|
| `test/mocks/infrastructure/OFTHarness.sol` | 删 `ComposeTxStatus` 相关（随生产代码瘦） |
| `test/common/omnichain/oft/OutrunOFTInit.t.sol` | 删 `withdrawIfNotExecuted`/`notifyComposeExecuted` 测试；加 `_lzReceive` 不再存 compose 状态断言 |
| `test/verse/YieldDispatcher.t.sol` | 加 `claimRefund` 正向 + 反向（已 settle/已 refund/未投递/哈希不符→revert）+ 竞争（claimRefund 后 lzCompose revert） |
| `test/interoperation/OmnichainMemecoinStaker.t.sol` | 同 YieldDispatcher 模式 |
| `test/yield/MemecoinYieldVault.t.sol` | `testReAccumulateYields*` 改真实 `_lzReceive → claimRefund` 端到端（不再 `setQueuedAmount` mock storage） |

### docs/ 文档

| 文件 | 改动 |
|---|---|
| `docs/spec/interoperation/layerzero-oapp-oft.md` §3/§4 | 删 UBO/ComposeTxStatus/withdrawIfNotExecuted；加 composer 自托管退款 + endpoint composeQueue 证明范式 |
| `docs/spec/invariants.md` | 加 INV：退款安全依赖 (a) endpoint composeQueue 哈希不可伪造 (b) composer composeState 互斥 (c) 受益方在 message 固化 |
| `docs/review/2026-08-03-codebase-multiround-review.md` | 纠正 `:701` "UBO==vault"；标注 COMMON-001 治本方案 |

---

## 测试策略

### 必加端到端测试（验证标准）

1. **fee 分发 compose 失败 → claimRefund → vault 入账**（正向）
   `_lzReceive` mint 给 YieldDispatcher → 不跑 lzCompose → `claimRefund` → token 到 vault → vault accumulate。
2. **staking compose 失败 → claimRefund → receiver 收到**（正向）
3. **竞争：claimRefund 先 → lzCompose 后 → revert**（`composeState` 互斥）
4. **竞争：lzCompose 先 → claimRefund 后 → revert**
5. **COMMON-001 回归**：`send({to: bytes32(0), composeMsg: 非空})` → 目的链 mint 到 `0xdead` → 无 claimRefund 入口可二次 mint（`0xdead` 非 composer，composeQueue 查不到 → claimRefund revert NotDelivered）。

### 反向测试（边界）

- `claimRefund` 对未投递的 guid（composeQueue slot == bytes32(0)）→ revert NotDelivered。
- `claimRefund` 对已执行 lzCompose 的 guid（slot == RECEIVED_MESSAGE_HASH）→ revert AlreadyExecuted。
- `claimRefund` message 哈希不符 → revert InvalidProof。
- `claimRefund` 同 guid 二次调用 → revert AlreadyResolved。
- `lzCompose` 在已 Refunded 的 guid 上调用 → revert AlreadyResolved。

---

## 风险评估

| 风险 | 等级 | 缓解 |
|---|---|---|
| `composeQueue` 读取依赖 LayerZero endpoint 接口稳定性 | 中 | `composeQueue` 是 public mapping，LayerZero v2 稳定接口；用 `IMessagingComposer` 接口隔离 |
| `RECEIVED_MESSAGE_HASH` 常量硬编码风险 | 低 | 从 LayerZero lib import，不本地硬编码 |
| 删 `notifyComposeExecuted` 后 lzCompose 重放防护迁移 | 中 | endpoint 原生 `lzCompose` 的 `LZ_ComposeNotFound` 防重放 + composer `composeState` 双层 |
| claimRefund 任何人可调，可能在 lzCompose 即将执行时抢先退款 | 低 | 退款地址在 message 固化，调用者无法获利。抢先退款是设计意图：compose 失败的判定即 lzCompose 未及时执行，退款优先于滞后的 lzCompose 由 `composeState` 互斥保证。受益方若希望 lzCompose 优先，应在 compose 失败判定窗口内不调 claimRefund |
| `reAccumulateYields` 签名变更破坏调用者 | 低 | 生产无调用者（manual retry），仅接口 + 测试同步 |

---

## 迁移路径

pre-deployment，无链上迁移。合约未部署，直接重构 + 全量测试。

改动顺序（降低中间态编译失败）：
1. composer 改动（YieldDispatcher + Staker 加 `claimRefund` + `composeState`；`lzCompose` 暂保留旧调用但加注释标记待删）→ 编译通过
2. vault 改动（`reAccumulateYields`）→ 编译通过
3. token 层删除（`IOFTCompose` + `OutrunOFTCoreInit` + `OutrunOFTInit`）→ 删 composer 内 `notifyComposeExecuted` 调用 → 编译通过
4. 测试改动 → 全绿
5. spec 文档改动
