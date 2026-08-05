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
 - `MemeverseLauncher`（`IOFT.quoteSend/send` 分发 fee）
 - `MemeverseOmnichainInteroperation`（跨链 staking）
 - `YieldDispatcher`、`OmnichainMemecoinStaker`（compose 接收处理）

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

### 3.2.1 COMMON-001 跨链通胀对 token 模块的适用性

- `Memecoin`（`src/token/Memecoin.sol:10` `is OutrunOFTInit`）与 `MemePol`（`src/token/MemePol.sol:10` `is OutrunOFTInit`）均直接继承 `OutrunOFTInit`，且二者均 **未 override** `_credit`/`_debit`/`send`/`_lzReceive`/`withdrawIfNotExecuted`/`_update`（二者额外 override `burn`，但均未 override 上述 OFT compose 路径函数）。故 common OFT 的全部行为（含 COMMON-001）对二者直接成立。
- COMMON-001：源链上攻击者持 ≥1 个 `Memecoin`/`MemePol` 即可调用公开 `send({to: bytes32(0), composeMsg: ...})` →
  - 源端 `_debit` burn（`OutrunOFTInit.sol:80`）；
  - 目的端 `_lzReceive` → `_credit(0, ...)`，`OutrunOFTInit.sol:102,112` 把 `_to == address(0x0)` 重映射到 `0xdead` 并 mint 该数量；
  - 进入 compose 分支后，攻击者调用 `withdrawIfNotExecuted`（`OutrunOFTInit.sol:57`）→ `_update(composer, receiver, amount)`（`:66`）二次 mint。
  - 净效果：源端 burn 1X，目的端 mint 2X，绕过 token 层 launcher-only mint 约束，造成跨链通胀。
- 根因修复在 common 层；token 层可独立做防御性 override。

`[代码已证]`

### 3.2.2 OApp owner == delegate 的 endpoint 配置权

- token 合约（`Memecoin`/`MemePol`）继承以下 5 个 `onlyOwner` endpoint 配置 setter，部署后由 owner 直接持有该配置权：
  - `setPeer`（`src/common/omnichain/oapp/OutrunOAppCoreInit.sol:68` onlyOwner）
  - `setDelegate`（`OutrunOAppCoreInit.sol:90` onlyOwner）
  - `setMsgInspector`（`src/common/omnichain/oft/OutrunOFTCoreInit.sol:143` onlyOwner）
  - `setEnforcedOptions`（`src/common/omnichain/oapp/OutrunOAppOptionsType3Init.sol:54` onlyOwner）
  - `setPreCrime`（`src/common/omnichain/oapp/OutrunOAppPreCrimeSimulatorInit.sol:59` onlyOwner）
- `initialize` 时 owner 与 delegate 均设为 launcher（`Memecoin.sol:24-32` / `MemePol.sol:33-44`），故部署后 launcher 作为 owner == delegate 持有上述 endpoint 配置权。
- 与 §3.1（`launcher.registerMemeverse` 时调 `setPeer`）相区分：§3.1 是 launcher 注册流程的即时调用，本节是 token 自身 owner == delegate 的常态配置面。

`[代码已证]`

### 3.3 收益分发与 staking 边界

- Launcher fee 分发：
 - 本链治理：调用 `YieldDispatcher.distributeSameChain(...)` 本地直达
 - 异链治理：调用 `IOFT.send(...)` 远程发送，目标链由 LayerZero endpoint 调用 `YieldDispatcher.lzCompose(...)`
- Memecoin staking：
 - 本链治理：直接 deposit 到 yieldVault
 - 异链治理：OFT 发送到 `OmnichainMemecoinStaker`，compose 后 deposit/transfer

`[代码已证]`

## 4. 安全与执行约束

- compose 回调授权：
 - 见 [docs/spec/access-control.md §3](../access-control.md)（`YieldDispatcher.distributeSameChain` 仅 `memeverseLauncher`；远端 `YieldDispatcher.lzCompose` 由 LayerZero endpoint 调用且仅 `localEndpoint`；`OmnichainMemecoinStaker.lzCompose` 仅 `localEndpoint`）
- replay 防护：
 - endpoint 路径检查 `getComposeTxExecutedStatus(guid)`，并 `notifyComposeExecuted(guid)`
- 费用约束：
 - 多条远端路径要求 `msg.value` 与 quote 精确相等（不是“大于等于”）

以上均为 `[代码已证]`。

## 5. 与本仓库外系统的边界

- DVN、消息库、endpoint 级配置由链外部署与 LayerZero 基础设施决定。`[未知]`
- 各链实际 endpoint 地址、EID 与 peer 配置最终值不在仓库内固定。`[未知]`

## 6. 注册时间单位语义

- 注册“天数”换算：`RegistrarAtLocal.quoteRegister` 读取 `RegistrationCenter.DAY`；最终写入以中心链为准，中心写入固定 `unlockTime = endTime + FIXED_LOCKUP_DURATION`（时间权威不变量见 [docs/spec/invariants.md](../invariants.md) INV-11；DAY / FIXED_LOCKUP_DURATION 数值见 [docs/spec/verse/config-matrix.md §3](../verse/config-matrix.md)）。`[代码已证]`
