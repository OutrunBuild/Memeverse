# MemeverseV2 公共基础层说明

## 1. 目标

本文总结 `src/common/**` 在 V2 中提供的统一语义，帮助读者在看 launcher、yield、interoperation、registration 前先建立共同底层假设。

## 2. Native / ERC20 统一资金语义

`TokenHelper` 为多个业务模块提供统一资金操作语义：

- `address(0)` 代表 native token
- `_transferIn`
  - native 路径要求 `msg.value == amount`
  - ERC20 路径走 `safeTransferFrom`
- `_transferOut`
  - native 路径使用低层 call
  - ERC20 路径走 `safeTransfer`

这意味着多个上层业务模块在处理 native 与 ERC20 时，共享同一套基础约束。

但这不是对全仓所有模块的无条件承诺。

swap 栈是显式例外：

- swap / router / hook 只支持 ERC20/ERC20 pair
- native 拒绝规则（`NativeCurrencyUnsupported`）与收费/币种边界的完整定义见 [docs/spec/swap/uniswap-v4.md](../swap/uniswap-v4.md) §3；Permit2 入口语义见 [docs/spec/swap/permit2.md](../swap/permit2.md)
- protocol fee settlement currency 在 swap 栈内仅允许 ERC20

因此阅读 swap 相关文档或实现时，不能把 common 层的 native 能力外推成 swap 也支持 native。

## 3. Approval 语义

`TokenHelper` 中的 `_safeApprove` / `_safeApproveInf` 不是普通样板代码。

其关键语义是：

- 对某些 allowance 语义不标准的 token，先清零再重设（清零仅当当前 allowance 非零时执行；已为 0 则该步是同值 no-op，直接跳过）
- 当 allowance 低于下界时，才重新设置为 `type(uint256).max`

这能降低重复 approve 与奇怪 token 行为带来的兼容性风险。

## 4. Reentrancy 语义

`ReentrancyGuard` 使用 transient lock 作为统一重入保护基础。

在当前仓库里，它的重要含义不是“所有函数都防重入”，而是：

- 某些统一出口，如 `_transferOut`，带有基础重入保护
- 上层模块在做外部转账时默认共享这个边界
- 该重入保护仅在单次 `_transferOut` 调用内部持有——`_transferOut` 返回即释放锁（`_nonReentrantAfter` 复位），因此两次 `_transferOut` 之间的窗口不受此锁覆盖；跨出口的重入安全依赖调用方自身的 CEI 排序，而非这个 modifier
- 入站 pull（`_transferIn`）不带 `nonReentrant`：`safeTransferFrom` 是外部 call，若资产带转账回调（ERC-777 / ERC-1363 类 transfer hook）即在调用方层面构成 interaction-before-effects 重入窗口——经由 `_transferIn` 拉入的资产必须满足无 transfer hook 的信任前提，该前提按资产分别成立（uAsset 的权威信任边界定义见 [docs/spec/polend/settlement-and-fees.md §9.1](../polend/settlement-and-fees.md)）

因此读业务逻辑时，不能只看合约本身，还要意识到资金出口带着底层 guard。

## 5. Initializer / Clone 语义

`Initializable` 与相关 init 基类定义了 clone 体系的基本规则：

- 实现合约本体在 constructor 中即锁死初始化
- clone 实例只能初始化一次
- 重复初始化应回退

这套规则支撑：

- `Memecoin`
- `MemePol`
- `MemecoinYieldVault`

也解释了为什么这些模块在部署文档里表现为“clone + initialize”，而不是普通 constructor 初始化。

## 6. OApp / OFT 基础边界

`src/common/omnichain/**` 提供了 V2 跨链层共享的能力：

- peer / delegate / endpoint 基础配置
- OApp 收发消息初始化
- OFT token 基础能力
- compose 相关抽象

它们的意义不是“单独构成产品模块”，而是让 registration、token、yield、interoperation 共用同一套 LayerZero 基础边界。

## 7. 为什么 common 层重要

如果不理解 common 层，很容易把上层行为误判为各模块各自为政。

实际上：

- 资金输入输出语义来自 `TokenHelper`
- clone 初始化边界来自 `Initializable`
- peer / compose / replay 语义来自 common omnichain 基类

因此 common 层决定了多个业务模块的共同假设。

## 8. 当前实现提醒

- common 层不是面向用户的功能层，但它直接影响安全边界
- 文档分析 launcher / yield / interoperation 时，很多关键行为需要回到 common 层解释
- 未来若修改 common 层，应视为高影响面变更，而不是普通工具层重构

## 9. 相关真源与证据

- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/upgradeability.md](../upgradeability.md)
- [docs/spec/interoperation/layerzero-oapp-oft.md](../interoperation/layerzero-oapp-oft.md)
- [docs/implementation-map.md](../../implementation-map.md)
