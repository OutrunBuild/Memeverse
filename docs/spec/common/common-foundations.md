# Memeverse 公共基础层说明

## 1. 目标

本文总结 `src/common/**` 在 V2 中提供的统一语义，帮助读者在看 launcher、yield、interoperation、registration 前先建立共同底层假设。

## 2. Native / ERC20 统一资金语义

`TokenHelper` 为多个业务模块提供统一资金操作语义：

- `address(0)` 代表 native token
- `_transferIn`
  - 所有 pull 均为 caller 出资：`from` 必须等于 `msg.sender`，否则 revert `TokenHelper.sol::TransferFromNotCaller`——`from` 参数不是任意来源，不支持 allowance 式第三方代拉
  - native 路径要求 `msg.value == amount`
  - ERC20 路径走 `safeTransferFrom`；`amount == 0` 时跳过外部调用，不触碰 token
- `_transferOut`
  - `amount == 0` 时静默 no-op：直接返回，native 路径不对 `to` 发起 0 值 call
  - native 路径使用低层 call，失败即 revert `TokenHelper.sol::NativeTransferFailed`
  - native 路径在低层 call 前校验 `to != address(0)`，为零时 revert `NativeTransferToZeroAddress`（`src/common/token/TokenHelper.sol::_transferOut`）
  - ERC20 路径走 `safeTransfer`
- ERC20 路径失败语义（`_transferIn` 与 `_transferOut` 共享，经 `OutrunSafeERC20`）：低层 call 失败时原样冒泡 token 自身 revert 数据；call 成功但返回非 `true`（返回 `false`/非 bool 数据，或空 returndata 且 token 无 code）时 revert `OutrunSafeERC20.sol::SafeERC20FailedOperation`

这意味着多个上层业务模块在处理 native 与 ERC20 时，共享同一套基础约束。

但这不是对全仓所有模块的无条件承诺。

swap 栈是显式例外：

- swap / router / hook 只支持 ERC20/ERC20 pair
- native 拒绝规则（`NativeCurrencyUnsupported`）与收费/币种边界的完整定义见 [docs/spec/swap/uniswap-v4.md](../swap/uniswap-v4.md) §3；Permit2 入口语义见 [docs/spec/swap/permit2.md](../swap/permit2.md)
- protocol fee settlement currency 在 swap 栈内仅允许 ERC20

因此阅读 swap 相关文档或实现时，不能把 common 层的 native 能力外推成 swap 也支持 native。

## 3. Approval 语义

`TokenHelper.sol::_safeApprove` 不是普通样板代码。它用低层 call 直接调用 ERC20 `approve`，其关键语义是：

- 空 returndata 仅当 token 有 code 时才视为成功：向 EOA 地址的低层 CALL 同样成功且返回空数据，缺少 `token.code.length > 0` 检查会把无实现合约的 token 地址误判为 approve 成功（假阳性）
- 有 returndata 时解码出布尔结果一并校验；call 失败或校验不通过即 revert `SafeApproveFailed(token, to, value)`

生产路径仅按操作授予精确额度，无无限授权；launcher 的 bootstrap 与结算路径在各操作尾部显式撤销为零。`TokenHelper` 不提供无限授权 helper。

但这不是对全仓授权面的无条件承诺，向 swap 栈组件的授权存在两处显式例外：

- swap router 对 hook 的常驻授权：`MemeverseSwapRouter.sol::_ensureHookApproval` 对协议自有的 hook 采用惰性 `type(uint256).max` 常驻授权、从不撤销。hook 经流动性结算流以该授权从 router 支取资金；仓内发行 token 在 `type(uint256).max` 额度下不递减授权数值（`OutrunERC20Init.sol::_spendAllowance`），额度不足时补满的分支不会再次触发，外部 token 至多在额度被消耗后由该分支惰性补满。spender 是 swap 栈自有组件，按操作授予/撤销的 gas 开销大于收益，故按取舍保留常驻额度。
- launcher 对 swap router 的 exact 模式残留授权：`MemeverseLiquidityImpl.sol::mintPOLToken` 先按调用方 desired 预算对 uAsset 与 memecoin 授权，exact 模式（`amountOutDesired != 0`）实际仅按 quote 额度拉取，操作尾在两侧留下 `desired − quoted` 的授权残留（desired 恰等于 quote 时为零），且无撤销入口。spender 是协议自有 router，下一次操作以非零→非零 approve 直接覆盖；`uAsset` 发行合约支持非零到非零的 approve 变更（同类取舍见 [settlement-and-fees.md](../polend/settlement-and-fees.md)：Splitter 对 POLendUpgradeable 的 allowance 用完后不做 approve-to-zero）；memecoin 为本仓发行的标准 ERC20，approve 同样允许非零→非零覆盖。auto 模式（`amountOutDesired == 0`）按完整预算拉取，无残留。

## 4. Token 签名扩展基面

common 层为 clone token 提供统一的 EIP-712 签名扩展基类，本节是这些基类决定的对外签名面语义的 canonical home。

### 4.1 EIP-712 域构造

所有签名入口共享 `OutrunEIP712Init`（`src/common/cryptography/OutrunEIP712Init.sol`）的域规则：

- domain name 取各 token 自身 name，version 恒为 `"1"`（`src/common/token/OutrunERC20PermitInit.sol` 的 `__OutrunERC20Permit_init` 以 `__OutrunEIP712_init(_name, "1")` 初始化）
- `chainId` 与 `verifyingContract` 活取（`block.chainid` / `address(this)`，见 `OutrunEIP712Init.sol::_buildDomainSeparator`）：同一合约地址跨链天然分域，签名不跨链通用
- name/version 在初始化时快照并哈希缓存（`__OutrunEIP712_init_unchained`），初始化后恒定；子类覆盖 `_EIP712Name` / `_EIP712Version` 必须返回初始化后稳定的值，否则链上签名域与 `eip712Domain()` 暴露值失同步
- `eip712Domain()`（IERC-5267）暴露完整域元数据供钱包/前端自动发现域：`fields = 0x0f`（name/version/chainId/verifyingContract 均启用，salt 与 extensions 为空）

### 4.2 permit（ERC-2612 免交易授权）

`OutrunERC20PermitInit`（`src/common/token/OutrunERC20PermitInit.sol`）提供 ERC-2612 `permit`：

- typehash：`Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)`
- nonce 经 `nonces(owner)` 查询、签名验证时单次消费；`DOMAIN_SEPARATOR()` 返回当前链域
- deadline 含端点：`block.timestamp <= deadline` 内有效，过期 revert `ERC2612ExpiredSignature(deadline)`
- 恢复地址非 `owner` 时 revert `ERC2612InvalidSigner`；成功即按签名设置精确 allowance。permit 是用户侧免交易授权路径，不改变 §3 的协议侧 `_safeApprove` 精确额度原则

### 4.3 delegateBySig（免交易票权委托）

`OutrunVotesInit`（`src/common/token/extensions/governance/OutrunVotesInit.sol` 的 `delegateBySig`）提供 EIP-712 签名委托：

- typehash：`Delegation(address delegatee,uint256 nonce,uint256 expiry)`
- expiry 含端点：仅 `block.timestamp > expiry` 时 revert `VotesExpiredSignature`；nonce 经 `_useCheckedNonce` 对签名人以单次消费校验
- 委托生效语义与链上 `delegate` 完全一致；票权激活前提与计票语义见 [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md) §2.2

### 4.4 暴露矩阵

- `MemecoinYieldVault` 份额：permit 与 delegateBySig 都有
- `UniswapLP`：仅 permit，无票权面
- `Memecoin` / `MemePol`：两者都无（未继承签名基类，纯 ERC20/OFT 面）

swap 栈 Router 的 Permit2 拉资入口是另一套独立机制，canonical 见 [docs/spec/swap/permit2.md](../swap/permit2.md)。

## 5. Reentrancy 语义

统一重入保护基础是 OpenZeppelin 的 `ReentrancyGuardTransient`（`ReentrancyGuardTransient.sol`），仍使用 transient lock。

在当前仓库里，它的重要含义不是“所有函数都防重入”，而是：

- 某些统一出口，如 `_transferOut`，带有基础重入保护
- 上层模块在做外部转账时默认共享这个边界
- 该重入保护仅在单次 `_transferOut` 调用内部持有——`_transferOut` 返回即释放锁（`_nonReentrantAfter` 复位），因此两次 `_transferOut` 之间的窗口不受此锁覆盖；跨出口的重入安全依赖调用方自身的 CEI 排序，而非这个 modifier
- 入站 pull（`_transferIn`）不带 `nonReentrant`：`safeTransferFrom` 是外部 call，若资产带转账回调（ERC-777 / ERC-1363 类 transfer hook）即在调用方层面构成 interaction-before-effects 重入窗口——经由 `_transferIn` 拉入的资产必须满足无 transfer hook 的信任前提，该前提按资产分别成立（uAsset 的权威信任边界定义见 [docs/spec/polend/settlement-and-fees.md §9.1](../polend/settlement-and-fees.md)）

因此读业务逻辑时，不能只看合约本身，还要意识到资金出口带着底层 guard。

## 6. Initializer / Clone 语义

`Initializable` 与相关 init 基类定义了 clone 体系的基本规则：

- 实现合约本体在 constructor 中即锁死初始化
- clone 实例只能初始化一次
- 重复初始化应回退

这套规则支撑：

- `Memecoin`
- `MemePol`
- `MemecoinYieldVault`

也解释了为什么这些模块在部署文档里表现为“clone + initialize”，而不是普通 constructor 初始化。

## 7. OApp / OFT 基础边界

`src/common/omnichain/**` 提供了 V2 跨链层共享的能力：

- peer / delegate / endpoint 基础配置
- OApp 收发消息初始化
- OFT token 基础能力
- compose 相关抽象

它们的意义不是“单独构成产品模块”，而是让 registration、token、yield、interoperation 共用同一套 LayerZero 基础边界。

## 8. 为什么 common 层重要

如果不理解 common 层，很容易把上层行为误判为各模块各自为政。

实际上：

- 资金输入输出语义来自 `TokenHelper`
- clone 初始化边界来自 `Initializable`
- peer 语义来自 common omnichain 基类 `OutrunOAppCoreInit`（`setPeer`/`_getPeerOrRevert` 门控 `lzReceive` 与 send 路径，见 `src/common/omnichain/oapp/OutrunOAppCoreInit.sol`）
- compose 语义由 `IComposeState`（`src/common/types/IComposeState.sol` 生命周期枚举与错误单点）+ `OFTComposeSettleVerify.verifySettle`（`src/common/omnichain/OFTComposeSettleVerify.sol::verifySettle` 交付证明库，`internal` 内联）+ 各消费方 `composeStates[token][guid]` 互斥（`src/verse/YieldDispatcherUpgradeable.sol::composeStates`/`::lzCompose`/`::settlePendingCompose` / `src/interoperation/OmnichainMemecoinStakerUpgradeable.sol::composeStates`/`::lzCompose`/`::settlePendingCompose`）共同承担，非基类
- replay 语义由 LayerZero endpoint `composeQueue` 的 `RECEIVED_MESSAGE_HASH` 哨兵（外部协议行为，`src/common/omnichain/OFTComposeSettleVerify.sol::RECEIVED_MESSAGE_HASH` 仅镜像该常量，`OFTComposeSettleVerify.sol::verifySettle` 作 `AlreadyExecuted` 检查）+ 上述消费方 `composeStates` 互斥共同承担；common receiver 基类 `OutrunOAppReceiverInit.nextNonce`（`src/common/omnichain/oapp/OutrunOAppReceiverInit.sol::nextNonce`）缺省恒返 `0`、不提供防线

因此 common 层决定了多个业务模块的共同假设。

## 9. 当前实现提醒

- common 层不是面向用户的功能层，但它直接影响安全边界
- 文档分析 launcher / yield / interoperation 时，很多关键行为需要回到 common 层解释
- 未来若修改 common 层，应视为高影响面变更，而不是普通工具层重构

## 10. 相关真源与证据

- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/upgradeability.md](../upgradeability.md)
- [docs/spec/interoperation/layerzero-oapp-oft.md](../interoperation/layerzero-oapp-oft.md)
- [docs/implementation-map.md](../../implementation-map.md)
- [docs/spec/governance/governance-yield-details.md](../governance/governance-yield-details.md)
