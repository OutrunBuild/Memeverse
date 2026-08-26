# MemeverseV2 集成边界：LayerZero OApp / OFT

## 1. 范围

本文描述 MemeverseV2 与 LayerZero v2 的边界，不复述 LayerZero 通用协议原理。  
标签：

- `[代码已证]`
- `[未知]`

## 2. 使用面总览（代码落点）

- OApp 路径：
 - `MemeverseRegistrationCenterUpgradeable`（中心链 fan-out；基于 LayerZero upgradeable OApp 基座 `OAppUpgradeable`——经 remapping `@layerzerolabs/oapp-evm-upgradeable/=lib/devtools/packages/oapp-evm-upgradeable/` 引入，仅导入其 `contracts/`——`lzEndpoint` 以 immutable 烧入 implementation 构造器，升级侧由 `MemeverseRegistrationCenterUpgradeable.sol::_authorizeUpgrade` 的 endpoint 一致性守卫（`UpgradeEndpointMismatch`）保护）
 - `MemeverseRegistrarOmnichain`（异链向中心链注册）
 - `OutrunOApp*` 初始化基类（peer/delegate）
- OFT 路径：
 - `Memecoin`、`MemePol`（基于 `OutrunOFTInit`）
 - `MemeverseLauncherUpgradeable`（`IOFT.quoteSend/send` 分发 fee）
 - `MemeverseOmnichainInteroperation`（跨链 staking）
 - `YieldDispatcherUpgradeable`、`OmnichainMemecoinStakerUpgradeable`（compose 接收处理；staker 为 plain composer——不基于任何 OApp 基座，仅实现 compose 接收）

以上为 `[代码已证]`。

## 3. 边界与职责

### 3.1 peer / endpoint 映射边界

- `launcher.registerMemeverse` 时会对 memecoin/POL 执行 `IOAppCore.setPeer`。
- endpointId 通过 `LzEndpointRegistry.lzEndpointIdOfChain` 查询。
- 未配置 endpointId（返回 0）会回退注册。

`[代码已证]`

### 3.2 注册跨链消息边界

- `MemeverseRegistrationCenterUpgradeable` 负责中心链注册参数校验与多链 fan-out。
- 远端回调 `_lzReceive` 要求 `_origin.sender ==` 当前配置的 registrar 指针（owner 可经 `MemeverseRegistrationCenterUpgradeable.sol::setMemeverseRegistrar` 变更的 storage 指针；OApp 基座另在进入 `_lzReceive` 前强制 `peers[srcEid] == origin.sender`，更换 registrar 须与 `setPeer` 成对执行，见 [docs/operations.md §3.1.2](../../operations.md)）。
- `MemeverseRegistrarOmnichain` 负责异链到中心链注册发送，gas 预算由 `registrationGasLimit` 组合。

`[代码已证]`

### 3.2.1 跨链 send 守恒（无二次 mint）

OFT 遵循官方 LayerZero OFTCore 语义：`_lzReceive` mint 即终态 + `endpoint.sendCompose`，token 层不托管 compose 状态。公开 `send` 源端 burn 1X、目的端单次 mint 1X（`to = address(0)` 仅重映射到 `0xdead`），无跨链通胀路径；守恒不变量见 [docs/spec/invariants.md INV-09A](../invariants.md)。

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
 - 异链治理：OFT 发送到 `OmnichainMemecoinStakerUpgradeable`，compose 后 deposit/transfer

`[代码已证]`

### 3.4 OFT 精度与 dust 边界（通用，含第三方直接 `IOFT::send`）

- `OutrunOFTCoreInit.sol::sharedDecimals` 固定 6；18 位 `Memecoin`/`MemePol` 的 `OutrunOFTCoreInit.sol::decimalConversionRate = 10**(18-6) = 1e12`（见 `OutrunOFTCoreInit.sol::decimalConversionRate`）。
- `OutrunOFTCoreInit.sol::_removeDust` 按 `(_amountLD / rate) * rate` 截断，`OutrunOFTCoreInit.sol::_toSD` 在 `amountSD > type(uint64).max` 时 revert `AmountSDOverflowed`。`OutrunOFTCoreInit.sol::quoteOFT`/`OutrunOFTCoreInit.sol::quoteSend`/`OutrunOFTCoreInit.sol::send` 均经 `OutrunOFTCoreInit.sol::_debitView` 复用该截断。
- 亚尘 `<rate` 在 OFT 层截断为 0：直接 `IOFT::send` 会以 `amountSentLD=0`/`amountSD=0` 上链，目标链零 mint、费不退；`MemeverseOmnichainInteroperation.sol::memecoinStaking` 与 `MemeverseSettlementImpl.sol::_sendRedeemedFeesCrossChain` 已分别用 `MemeverseOmnichainInteroperation.sol::_requireNonZeroRemoteDelivery`/`ICrossChainSendErrors::DustAmount` 在源链前置拒绝，第三方直接 `send` 需自检 `amountLD >= rate`（`OutrunOFTCoreInit.sol::quoteOFT` 返回 `amountReceivedLD == 0` 即零截断，可作判定）。
- 非整数倍余数尘位在直接 `send` 中永久丢失；托管 staking 路径同 tx 退回该余数（见 `docs/spec/interoperation/interoperation-details.md:4.5-4.6`），通用 OFT 路径无此退款。
- `to == address(0)` 的 `OutrunOFTInit.sol::_credit` → `address(0xdead)` 重定向为 LayerZero 官方行为（`lib/devtools/packages/oft-evm/contracts/OFT.sol::_credit` 同款），跨链目标为零的资金入死址可视为销毁，见 `docs/spec/events.md`。

`[代码已证]`

## 4. 安全与执行约束

- compose 回调授权：
 - 见 [docs/spec/access-control.md §3](../access-control.md)（`YieldDispatcherUpgradeable.distributeSameChain` 仅 `memeverseLauncher`；远端 `YieldDispatcherUpgradeable.lzCompose` 由 LayerZero endpoint 调用且仅 `localEndpoint`；`OmnichainMemecoinStakerUpgradeable.lzCompose` 仅 `localEndpoint`）
- compose 回调授权精确额度（无无限授权）：
 - `OmnichainMemecoinStakerUpgradeable.lzCompose` deposit 分支对 message 解码出的 `yieldVault` 仅授予精确 `amount` 的 memecoin 授权（`_safeApprove(memecoin, yieldVault, amount)`），不授无限额度——与 `YieldDispatcherUpgradeable._settleToContract` 的精确授权模式一致（其 MEMECOIN 分支与 staker 防御栈同构，见下条）；精确授权封顶仅对真实桥接帧有语义——伪造帧（`sendCompose` 按 msg.sender 键控）的 amountLD 由攻击者自选、可至 `type(uint256).max`（`approve(max)` 无限授权），但伪造帧 token 键恒为攻击者自有地址、无限授权只覆盖其自有资产，无第三方暴露；fallback（vault 无 code 直接 transfer）与 `settlePendingCompose`（push 给 receiver）路径不涉及 vault 授权。
 - 防御对象：compose message 由免许可 OFT send 构造，`yieldVault` 地址虽经下述 token-vault 绑定校验（`asset() == memecoin`），但恶意合约可谎报 `asset()` 绕过该校验，故 vault 地址仍不可信；无限授权会把 staker 托管余额（含他人滞留资金）暴露给任意 message 指定地址，精确额度把损失封顶为本次 `amount`——与绑定校验构成两层防御（绑定拦截配对错误，精确授权封顶谎报资产的恶意 vault）。
 - 锚点：`src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::lzCompose`、`src/common/token/TokenHelper.sol::_safeApprove`、`src/verse/YieldDispatcherUpgradeable.sol::_settleToContract`。
 - `[代码已证]`
- deposit 分支 token↔vault 绑定（新增）：
 - `OmnichainMemecoinStakerUpgradeable.lzCompose` deposit 分支在授权/存款前校验 `require(IMemecoinYieldVault(yieldVault).asset() == memecoin, TokenVaultMismatch())`——投递 token 必须等于 vault 自身资产，伪造 (token, vault) 配对（如伪造 token + 真实 vault）在资金移动前 revert，伪造 token 无法驱动真实 vault 从 staker 拉取真实资产。
 - 防御对象：compose 消息可被免许可构造、`_from`/`yieldVault` 由消息全权决定；绑定把“消息命名什么”与“vault 实际拉取什么”强制一致，与精确授权（封顶单次 pull）构成两层防护。
  - dispatcher 同款：`YieldDispatcherUpgradeable._settleToContract` MEMECOIN 分支在 approve 前同样校验 `require(IMemecoinYieldVault(receiver).asset() == token, TokenVaultMismatch())`（同 selector）——与 staker 构成同构两层防御（绑定 + 精确授权），防御栈分化已消除（dispatcher 侧不再依赖“预存授权”不变量，伪造 (fakeToken, realVault) 帧在资金移动前具名 revert）。
 - 锚点：`src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::lzCompose`、`src/verse/YieldDispatcherUpgradeable.sol::_settleToContract`、`src/yield/interfaces/IMemecoinYieldVault.sol::asset`、`src/interoperation/interfaces/IOmnichainMemecoinStaker.sol` 与 `src/verse/interfaces/IYieldDispatcher.sol`（均 `TokenVaultMismatch`）。
 - `[代码已证]`
- 已投递未执行 compose 的兜底结算（token 层不再托管 compose 状态，兜底结算由 composer 自托管）：
 - OFT 合约 `_lzReceive` 遵循官方 LayerZero OFTCore 语义：mint 即终态 + `endpoint.sendCompose`，token 层不托管 compose 状态。
 - 每个 composer（`YieldDispatcherUpgradeable` / `OmnichainMemecoinStakerUpgradeable`）维护 `ComposeState{None,Settled,Released}` 互斥状态 + `settlePendingCompose(token, guid, message)` 入口，权限分列：`YieldDispatcherUpgradeable.settlePendingCompose` permissionless（接收方从 `message` 解码、不可篡改）；`OmnichainMemecoinStakerUpgradeable.settlePendingCompose` 仅接收人可调（`msg.sender == receiver`，receiver 从 hash 绑定的 `message` 解码），防第三方在 `lzCompose` 前 front-run 抢占导致用户 stake 无法入 vault 的 DoS。
 - `settlePendingCompose` 用 endpoint 公开 `composeQueue` 证明投递真实性（非零 = 已投递，`!= RECEIVED_MESSAGE_HASH` = lzCompose 未执行）+ `keccak256(message) == queueHash` 证明 message 真实性；接收方从 message 显式解码，调用者不可篡改。
 - `settlePendingCompose` / `MemecoinYieldVault.reAccumulateYields` 的 `message` 参数与目标链 composer 的 `ComposeSent` 事件 `message` 字段逐字节一致（由 `OutrunOFTCoreInit::_lzReceive` 经 `endpoint.sendCompose` 触发，即 `OFTComposeMsgCodec::encode` 的完整字节，布局 `[nonce(8)][srcEid(4)][amountLD(32)][composeFrom(32)][composeMsg]`）；恢复操作按 `guid` 过滤 `ComposeSent` 事件（`to` = 对应 composer、`from` = asset OFT、`index` = 0），原样拷贝 `message` 字段传入即可（注意：`ComposeSent` 字段均非 indexed，raw RPC 无法按 guid/to/from 做 topic 过滤，检索细节见 [docs/operations.md §3.13 步骤 1](../../operations.md)）；`ComposeSent` 的 `to` 即 compose 实际投递的 dispatcher（`reAccumulateYields` 的 `dispatcher` 参数取该值；vault 不存储 dispatcher，launcher `setYieldDispatcher` 旋转后须传 compose 实际所在的历史/当前 dispatcher），无需逐字段手工重组。
 - `YieldDispatcherUpgradeable.settlePendingCompose` 结算直接复用正向 `_settle`（单一事实源）：非合约 receiver 按 tokenType 分流（MEMECOIN → burn、UASSET → `protocolTreasury`）、越界 TokenType 在 `abi.decode` 解码边界即被拒绝（空数据回退，先于 `_settle`）；`_settle` 内的 `InvalidTokenType` 分支为当前不可达防御性 backstop——三个入口均前置过滤（`lzCompose` 经 `_parseCompose` 以 `ComposeRejected` 消费、`distributeSameChain` 经外部 calldata 解码、`settlePendingCompose` 经 `abi.decode`）；合约 receiver 按 tokenType 走 approve+pull（UASSET→governor `receiveTreasuryIncome`（pull + `treasuryBalances` 记账）、MEMECOIN→yieldVault `accumulateYields`（pull + `totalAssets` 记账））；`OmnichainMemecoinStakerUpgradeable.settlePendingCompose` 原币直接 push 给 receiver（`_transferOut`）。
 - `lzCompose` 与 `settlePendingCompose` 经 `composeStates`（按 (token, guid) 键控）单向迁移互斥（None→Settled 或 None→Released，不可逆）；键控绑定真实桥接 token，防止攻击者用伪造 token 地址写自己的 `composeQueue` 槽后烧毁真实 guid 的互斥锁；endpoint 的 `RECEIVED_MESSAGE_HASH` 作纵深防御（`AlreadyExecuted` 分支在正常路径下不可达——`composeStates` 先于它拦截，仅理论窗口覆盖）；`composeStates` 置位先于外部调用（CEI）；`composeStates == Released` 后 `lzCompose` 幂等放行（no-op），使 endpoint 状态机收敛到 `ComposeDelivered` 终态。
- replay 防护：
 - composer `composeStates` 互斥（权威）+ endpoint 原生 `lzCompose` 的 `LZ_ComposeNotFound` 防重放。
- 费用约束：
 - 跨链分发与跨链 staking 要求 `msg.value` 与 quote 精确相等（不是"大于等于"），见 [docs/spec/invariants.md INV-06](../invariants.md)；注册路径有意为 `>=`：`MemeverseRegistrationCenterUpgradeable.registration`（center 侧 `MemeverseRegistrationCenterUpgradeable.sol:254` `msg.value >= totalFee`，按报价精确花费、多付滞留 center、可经 `removeGasDust` 回收，退款地址 `address(this)`）与 `MemeverseRegistrarOmnichain.registerAtCenter`（spoke 侧 `MemeverseRegistrarOmnichain.sol:89` `msg.value >= lzFee`，多付由 endpoint 以 `refundAddress=msg.sender` 直退），hub 经 `MemeverseRegistrarAtLocal.registerAtCenter`（`MemeverseRegistrarAtLocal.sol:71-78` `msg.value == value` 转发，残差按 NatSpec `67-68` 作 gas dust 处理）

以上均为 `[代码已证]`。

## 5. 与本仓库外系统的边界

- DVN、消息库、endpoint 级配置由链外部署与 LayerZero 基础设施决定。`[未知]`
- 各链实际 endpoint 地址、EID 与 peer 配置最终值不在仓库内固定。`[未知]`

## 6. 注册时间单位语义

- 注册“天数”换算：`RegistrarAtLocal.quoteRegister` 读取 `RegistrationCenter.DAY`；最终写入以中心链为准，中心写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`（时间权威不变量见 [docs/spec/invariants.md](../invariants.md) INV-11；DAY / FIXED_LOCKUP_DURATION 数值见 [docs/spec/verse/config-matrix.md §3](../verse/config-matrix.md)）。`[代码已证]`
