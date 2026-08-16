# MemeverseV2 集成边界：LayerZero OApp / OFT

## 1. 范围

本文描述 MemeverseV2 与 LayerZero v2 的边界，不复述 LayerZero 通用协议原理。  
标签：

- `[代码已证]`
- `[未知]`

## 2. 使用面总览（代码落点）

- OApp 路径：
 - `MemeverseRegistrationCenter`（中心链 fan-out）
 - `MemeverseRegistrarOmnichain`（异链向中心链注册）
 - `OutrunOApp*` 初始化基类（peer/delegate）
- OFT 路径：
 - `Memecoin`、`MemePol`（基于 `OutrunOFTInit`）
 - `MemeverseLauncherUpgradeable`（`IOFT.quoteSend/send` 分发 fee）
 - `MemeverseOmnichainInteroperation`（跨链 staking）
 - `YieldDispatcherUpgradeable`、`OmnichainMemecoinStaker`（compose 接收处理）

以上为 `[代码已证]`。

## 3. 边界与职责

### 3.1 peer / endpoint 映射边界

- `launcher.registerMemeverse` 时会对 memecoin/POL 执行 `IOAppCore.setPeer`。
- endpointId 通过 `LzEndpointRegistry.lzEndpointIdOfChain` 查询。
- 未配置 endpointId（返回 0）会回退注册。

`[代码已证]`

### 3.2 注册跨链消息边界

- `MemeverseRegistrationCenter` 负责中心链注册参数校验与多链 fan-out。
- 远端回调 `_lzReceive` 要求 `_origin.sender == MEMEVERSE_REGISTRAR`。
- `MemeverseRegistrarOmnichain` 负责异链到中心链注册发送，gas 预算由 `registrationGasLimit` 组合。

`[代码已证]`

### 3.2.1 COMMON-001 跨链通胀攻击面已消除

`Memecoin` 与 `MemePol` 均直接继承 `OutrunOFTInit`（`is OutrunOFTInit`），且二者均 **未 override** `_credit`/`_debit`/`send`/`_lzReceive`/`_update`（二者额外 override `mint`/`burn`，但均未 override 上述 OFT compose 路径函数）。合并后 `OutrunOFTInit` 已回归官方 LayerZero OFTCore 语义，token 层 UBO 机制（`withdrawIfNotExecuted`/`ComposeTxStatus`）已删除，本节说明该攻击面已被消除。

**COMMON-001（已消除）**：旧 UBO 机制下，源链持有 ≥1 个 `Memecoin`/`MemePol` 的攻击者调用公开 `send({to: bytes32(0), composeMsg: ...})`，源端 `_debit` burn 1X，目的端 `_lzReceive`→`_credit` 首次 mint 后，攻击者可再调 `withdrawIfNotExecuted` 触发 `_update` 二次 mint，净效果 burn 1X / mint 2X，绕过 token 层 launcher-only mint 约束造成跨链通胀。下述流程证明该二次 mint 入口已随 UBO 机制删除而不复存在：

- 源端 `send` 经 `_debit` 在源链 burn 1X（`OutrunOFTInit::_debit`）。
- 目的端 `_lzReceive` → `_credit(...)`，`OutrunOFTInit::_credit` 仅把 `_to == address(0x0)` 重映射到 `0xdead` 并**单次** mint 该数量，mint 即终态，无 `withdrawIfNotExecuted` 可被调用。
- 非零 `to` 时 compose 消息经 `endpoint.sendCompose` 交 composer（`YieldDispatcherUpgradeable`/`OmnichainMemecoinStaker`）处理，token 层无第二次增发；`to = address(0)` 时该路由与 `OFTReceived` 事件同样携带重映射前的 `address(0)`（接收方为 `address(0)`，无 composer 处理），余额落在 `0xdead` 哨兵（见 [docs/spec/events.md](../events.md)）。该 sendCompose 仍会写 endpoint `composeQueue[token][0][guid][0]` 槽且无收敛路径（`lzCompose` 对无代码目标 revert，监控按 `ComposeSent` 无 `ComposeDelivered` 识别），详见 events.md。
- 净效果：源端 burn 1X、目的端 mint 1X，跨链供给守恒，不绕过 token 层 launcher-only mint 约束（见 [docs/spec/invariants.md INV-09A](../invariants.md)）。

`[代码已证]`

### 3.2.2 OApp owner == delegate 的 endpoint 配置权

- token 合约（`Memecoin`/`MemePol`）继承以下 5 个 `onlyOwner` endpoint 配置 setter，部署后由 owner 直接持有该配置权：
  - `setPeer`（`src/common/omnichain/oapp/OutrunOAppCoreInit.sol::setPeer` onlyOwner）
  - `setDelegate`（`OutrunOAppCoreInit.sol::setDelegate` onlyOwner）
  - `setMsgInspector`（`src/common/omnichain/oft/OutrunOFTCoreInit.sol::setMsgInspector` onlyOwner）
  - `setEnforcedOptions`（`src/common/omnichain/oapp/OutrunOAppOptionsType3Init.sol::setEnforcedOptions` onlyOwner）—— 当前未启用：全仓（src/ + script/）该 setter 仅有定义、零生产调用，初始化器 `__OutrunOAppOptionsType3_init()` 函数体为空从不写入映射，故 `enforcedOptions` 恒空；所有 OFT 发送路径经 `combineOptions`（`OutrunOAppOptionsType3Init.sol::combineOptions`）原样透传 caller `_extraOptions`，不施加接收端选项下限、不在发送路径做 type-3 类型校验。是否启用 enforced options 由产品侧在 verse/interoperation 发送路径另行评估（跨批）。
  - `setPreCrime`（`src/common/omnichain/oapp/OutrunOAppPreCrimeSimulatorInit.sol::setPreCrime` onlyOwner）
- `initialize` 时 owner 与 delegate 均设为 launcher（`Memecoin.sol::initialize` / `MemePol.sol::initialize`），故部署后 launcher 作为 owner == delegate 持有上述 endpoint 配置权。
- 与 §3.1（`launcher.registerMemeverse` 时调 `setPeer`）相区分：§3.1 是 launcher 注册流程的即时调用，本节是 token 自身 owner == delegate 的常态配置面。

`[代码已证]`

### 3.3 收益分发与 staking 边界

- Launcher fee 分发：
 - 本链治理：调用 `YieldDispatcherUpgradeable.distributeSameChain(...)` 本地直达
 - 异链治理：调用 `IOFT.send(...)` 远程发送，目标链由 LayerZero endpoint 调用 `YieldDispatcherUpgradeable.lzCompose(...)`
- Memecoin staking：
 - 本链治理：直接 deposit 到 yieldVault
 - 异链治理：OFT 发送到 `OmnichainMemecoinStaker`，compose 后 deposit/transfer

`[代码已证]`

## 4. 安全与执行约束

- compose 回调授权：
 - 见 [docs/spec/access-control.md §3](../access-control.md)（`YieldDispatcherUpgradeable.distributeSameChain` 仅 `memeverseLauncher`；远端 `YieldDispatcherUpgradeable.lzCompose` 由 LayerZero endpoint 调用且仅 `localEndpoint`；`OmnichainMemecoinStaker.lzCompose` 仅 `localEndpoint`）
- compose 回调授权精确额度（无无限授权）：
 - `OmnichainMemecoinStaker.lzCompose` deposit 分支对 message 解码出的 `yieldVault` 仅授予精确 `amount` 的 memecoin 授权（`_safeApprove(memecoin, yieldVault, amount)`），不授无限额度——与 `YieldDispatcherUpgradeable._settleToContract` 的精确授权模式一致（其 MEMECOIN 分支本轮同步落地同款绑定，见下条，与 staker 防御栈同构）；精确授权封顶仅对真实桥接帧有语义——伪造帧（`sendCompose` 按 msg.sender 键控）的 amountLD 由攻击者自选、可至 `type(uint256).max`（`approve(max)` 无限授权），但伪造帧 token 键恒为攻击者自有地址、无限授权只覆盖其自有资产，无第三方暴露；fallback（vault 无 code 直接 transfer）与 `settlePendingCompose`（push 给 receiver）路径不涉及 vault 授权。
 - 防御对象：compose message 由免许可 OFT send 构造，`yieldVault` 地址虽经下述 token-vault 绑定校验（`asset() == memecoin`），但恶意合约可谎报 `asset()` 绕过该校验，故 vault 地址仍不可信；无限授权会把 staker 托管余额（含他人滞留资金）暴露给任意 message 指定地址，精确额度把损失封顶为本次 `amount`——与绑定校验构成两层防御（绑定拦截配对错误，精确授权封顶谎报资产的恶意 vault）。
 - 锚点：`src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`、`src/common/token/TokenHelper.sol::_safeApprove`、`src/verse/YieldDispatcherUpgradeable.sol::_settleToContract`。
 - `[代码已证]`
- deposit 分支 token↔vault 绑定（新增）：
 - `OmnichainMemecoinStaker.lzCompose` deposit 分支在授权/存款前校验 `require(IMemecoinYieldVault(yieldVault).asset() == memecoin, TokenVaultMismatch())`——投递 token 必须等于 vault 自身资产，伪造 (token, vault) 配对（如伪造 token + 真实 vault）在资金移动前 revert，伪造 token 无法驱动真实 vault 从 staker 拉取真实资产。
 - 防御对象：compose 消息可被免许可构造、`_from`/`yieldVault` 由消息全权决定；绑定把“消息命名什么”与“vault 实际拉取什么”强制一致，与精确授权（封顶单次 pull）构成两层防护。
  - dispatcher 同款：`YieldDispatcherUpgradeable._settleToContract` MEMECOIN 分支在 approve 前同样校验 `require(IMemecoinYieldVault(receiver).asset() == token, TokenVaultMismatch())`（同 selector）——与 staker 构成同构两层防御（绑定 + 精确授权），本轮防御栈分化已消除（dispatcher 侧不再依赖“预存授权”不变量，伪造 (fakeToken, realVault) 帧在资金移动前具名 revert）。
 - 锚点：`src/interoperation/OmnichainMemecoinStaker.sol::lzCompose`、`src/verse/YieldDispatcherUpgradeable.sol::_settleToContract`、`src/yield/interfaces/IMemecoinYieldVault.sol::asset`、`src/interoperation/interfaces/IOmnichainMemecoinStaker.sol` 与 `src/verse/interfaces/IYieldDispatcher.sol`（均 `TokenVaultMismatch`）。
 - `[代码已证]`（本轮 code writer 同步落地）
- 已投递未执行 compose 的兜底结算（token 层不再托管 compose 状态，兜底结算由 composer 自托管）：
 - OFT 合约 `_lzReceive` 回归官方 LayerZero OFTCore 语义：mint 即终态 + `endpoint.sendCompose`，不存 UBO/ComposeTxStatus，无 `withdrawIfNotExecuted`。
 - 每个 composer（`YieldDispatcherUpgradeable` / `OmnichainMemecoinStaker`）维护 `ComposeState{None,Settled,Released}` 互斥状态 + `settlePendingCompose(token, guid, message)` 入口，权限分列：`YieldDispatcherUpgradeable.settlePendingCompose` permissionless（接收方从 `message` 解码、不可篡改）；`OmnichainMemecoinStaker.settlePendingCompose` 仅接收人可调（`msg.sender == receiver`，receiver 从 hash 绑定的 `message` 解码），防第三方在 `lzCompose` 前 front-run 抢占导致用户 stake 无法入 vault 的 DoS。
 - `settlePendingCompose` 用 endpoint 公开 `composeQueue` 证明投递真实性（非零 = 已投递，`!= RECEIVED_MESSAGE_HASH` = lzCompose 未执行）+ `keccak256(message) == queueHash` 证明 message 真实性；接收方从 message 显式解码，调用者不可篡改。
 - `settlePendingCompose` / `MemecoinYieldVault.reAccumulateYields` 的 `message` 参数与目标链 composer 的 `ComposeSent` 事件 `message` 字段逐字节一致（由 `OutrunOFTCoreInit::_lzReceive` 经 `endpoint.sendCompose` 触发，即 `OFTComposeMsgCodec::encode` 的完整字节，布局 `[nonce(8)][srcEid(4)][amountLD(32)][composeFrom(32)][composeMsg]`）；恢复操作按 `guid` 过滤 `ComposeSent` 事件（`to` = 对应 composer、`from` = asset OFT、`index` = 0），原样拷贝 `message` 字段传入即可（注意：`ComposeSent` 字段均非 indexed，raw RPC 无法按 guid/to/from 做 topic 过滤，检索细节见 [docs/operations.md §3.13 步骤 1](../../operations.md)）；`ComposeSent` 的 `to` 即 compose 实际投递的 dispatcher（`reAccumulateYields` 的 `dispatcher` 参数取该值；vault 不存储 dispatcher，launcher `setYieldDispatcher` 旋转后须传 compose 实际所在的历史/当前 dispatcher），无需逐字段手工重组。
 - `YieldDispatcherUpgradeable.settlePendingCompose` 结算直接复用正向 `_settle`（单一事实源）：非合约 receiver 按 tokenType 分流（MEMECOIN → burn、UASSET → `protocolTreasury`）、越界 TokenType 在 `abi.decode` 解码边界即被拒绝（空数据回退，先于 `_settle`）；`_settle` 内的 `InvalidTokenType` 分支为当前不可达防御性 backstop——三个入口均前置过滤（`lzCompose` 经 `_parseCompose` 以 `ComposeRejected` 消费、`distributeSameChain` 经外部 calldata 解码、`settlePendingCompose` 经 `abi.decode`）；合约 receiver 按 tokenType 走 approve+pull（UASSET→governor `receiveTreasuryIncome`（pull + `treasuryBalances` 记账）、MEMECOIN→yieldVault `accumulateYields`（pull + `totalAssets` 记账））；`OmnichainMemecoinStaker.settlePendingCompose` 原币直接 push 给 receiver（`_transferOut`）。
 - `lzCompose` 与 `settlePendingCompose` 经 `composeStates`（按 (token, guid) 键控）单向迁移互斥（None→Settled 或 None→Released，不可逆）；键控绑定真实桥接 token，防止攻击者用伪造 token 地址写自己的 `composeQueue` 槽后烧毁真实 guid 的互斥锁；endpoint 的 `RECEIVED_MESSAGE_HASH` 作纵深防御（`AlreadyExecuted` 分支在正常路径下不可达——`composeStates` 先于它拦截，仅理论窗口覆盖）；`composeStates` 置位先于外部调用（CEI）；`composeStates == Released` 后 `lzCompose` 幂等放行（no-op），使 endpoint 状态机收敛到 `ComposeDelivered` 终态。
- replay 防护：
 - composer `composeStates` 互斥（权威）+ endpoint 原生 `lzCompose` 的 `LZ_ComposeNotFound` 防重放（token 层 `getComposeTxExecutedStatus`/`notifyComposeExecuted` 已随 UBO 机制删除）。
- 费用约束：
 - 多条远端路径要求 `msg.value` 与 quote 精确相等（不是“大于等于”）

以上均为 `[代码已证]`。

## 5. 与本仓库外系统的边界

- DVN、消息库、endpoint 级配置由链外部署与 LayerZero 基础设施决定。`[未知]`
- 各链实际 endpoint 地址、EID 与 peer 配置最终值不在仓库内固定。`[未知]`

## 6. 注册时间单位语义

- 注册“天数”换算：`RegistrarAtLocal.quoteRegister` 读取 `RegistrationCenter.DAY`；最终写入以中心链为准，中心写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`（时间权威不变量见 [docs/spec/invariants.md](../invariants.md) INV-11；DAY / FIXED_LOCKUP_DURATION 数值见 [docs/spec/verse/config-matrix.md §3](../verse/config-matrix.md)）。`[代码已证]`
