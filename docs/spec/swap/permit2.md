# MemeverseV2 集成边界：Permit2

## 1. 范围

本文只覆盖 `MemeverseSwapRouter` 中的 Permit2 并行入口。  
标签：

- `[目标规范]`
- `[代码已证]`
- `[未知]`

## 2. 支持入口

Router 暴露 3 组 Permit2 入口（与普通入口并行，不替代）：

- `swapWithPermit2(...)`
- `addLiquidityWithPermit2(...)`
- `removeLiquidityWithPermit2(...)`

`[代码已证]`

## 3. 验签与拉资边界

### 3.1 单 token 路径（swap/remove）

- 校验 `permit.permitted.token` 必须等于预期 token
- 校验 `transferDetails.to` 必须是 `address(this)`（Router）
- 校验 `transferDetails.requestedAmount` 必须等于业务预算

### 3.2 双 token 路径（add）

- 仅接受 ERC20/ERC20 pair，期望 batch 长度固定为 2
- 逐项校验 token 顺序、接收地址、请求金额

以上为 `[代码已证]`。

## 4. Witness 绑定语义

Router 为每条 Permit2 入口构造独立 witness：

- `SWAP_WITNESS_TYPEHASH`
- `ADD_LIQUIDITY_WITNESS_TYPEHASH`
- `REMOVE_LIQUIDITY_WITNESS_TYPEHASH`

witness 绑定了关键业务参数（池子、方向、预算、截止时间等），签名不可跨业务复用。`[代码已证]`

## 5. 与普通入口一致/不一致点

- 一致：Permit2 只改变 ERC20 资金准备方式，后续 slippage、deadline、hook 语义一致。`[代码已证]`
- 一致：`removeLiquidityWithPermit2(...)` 进入共享 Router remove-liquidity 出款路径；最终 `recipient` 不允许是 `address(0)`，否则在 Router payout helper fail-close。`[代码已证]`
- 不一致：swap 栈对 native fail-close（规则见 [docs/spec/swap/uniswap-v4.md](uniswap-v4.md) §3），Permit2 不为 native 提供任何兜底路径。`[代码已证]`
- pool creation 不是 Permit2 路径；仅允许 `Launcher -> Router.createPoolAndAddLiquidity(...)`，并由 Router 的 `onlyLauncher` 限制。`[代码已证]`

### 5.1 Smart EOA session 边界 `[代码已证]`

- Permit2 只负责资金授权与 ERC20 拉资；permit owner、签名和 `spender` 都不认证 trader 或 principal，也不是 Hook 的 principal 来源。
- 任意 swap 路径（包括 `swapWithPermit2(...)`）都必须在合约账户 `A` 的 active Hook account session 内执行；Permit2 不替代 `A` 的 `beginAccountSession() -> Router -> endAccountSession()` 生命周期。

## 6. 安全边界

- Permit2 spender 语义由 Router 作为调用方固定下来；签名目标应与 Router 地址一致。`[代码已证]`
- Permit2 失败会导致整笔交易回退，不存在“部分生效”路径。`[代码已证]`

## 7. 明确未知项

- `[未知]` 生产环境实际 Permit2 合约地址；仓库仅体现“构造注入 + `permit2()` 只读暴露”，不含最终部署清单。
