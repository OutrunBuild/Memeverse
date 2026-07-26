# MemeverseV2 规格文档索引

本文档是 `docs/spec/` 的入口索引：按 region 列出全部规格文档及其职责，供编辑者快速定位"每类规则在哪个文件"。每条原子规则的权威主页见 §2 OCLPAR canonical-home 表。

文档分层（Product Truth / Implementation Evidence / Topic Guides）与冲突处理顺序见 [docs/ARCHITECTURE.md §2](../ARCHITECTURE.md)，本文不重定义层级。术语定义见 [docs/GLOSSARY.md](../GLOSSARY.md)。

标签约定：`[目标规范]` = 目标产品规则（可能尚未在代码实现）；`[代码已证]` = 当前代码可直接验证；`[未知]` = 仓库内无部署级最终值。

## 1. 文档地图（按 region）

### 跨模块（`docs/spec/` 根）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [protocol.md](protocol.md) | 100 | 协议总览、组件清单、文档分层 |
| [access-control.md](access-control.md) | 81 | 访问控制边界（authority / evidence） |
| [events.md](events.md) | 114 | 事件面（用户 / 索引器 / 运维） |
| [invariants.md](invariants.md) | 147 | 跨模块不变量 |
| [upgradeability.md](upgradeability.md) | 118 | 升级性与初始化约束 |

### 公共基础（`common/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [common/common-foundations.md](common/common-foundations.md) | 104 | 公共基础层说明 |

### Verse 生命周期（`verse/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [verse/accounting.md](verse/accounting.md) | 246 | 记账与资金语义 |
| [verse/state-machines.md](verse/state-machines.md) | 111 | 状态机 |
| [verse/lifecycle-details.md](verse/lifecycle-details.md) | 272 | 生命周期细化说明 |
| [verse/registration-details.md](verse/registration-details.md) | 178 | 注册链路细化说明 |
| [verse/deployment.md](verse/deployment.md) | 144 | 部署拓扑与初始化事实 |
| [verse/config-matrix.md](verse/config-matrix.md) | 99 | 配置矩阵（可配置面 / 常量面） |

### Swap（`swap/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [swap/swap-flow.md](swap/swap-flow.md) | 172 | Swap 流程图 |
| [swap/swap-integration.md](swap/swap-integration.md) | 279 | Swap 集成说明 |
| [swap/uniswap-v4.md](swap/uniswap-v4.md) | 101 | Uniswap v4 集成边界 |
| [swap/permit2.md](swap/permit2.md) | 60 | Permit2 集成边界 |

### 跨链互操作（`interoperation/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [interoperation/interoperation-details.md](interoperation/interoperation-details.md) | 109 | 跨链互操作细化说明 |
| [interoperation/layerzero-oapp-oft.md](interoperation/layerzero-oapp-oft.md) | 73 | LayerZero OApp / OFT 集成边界 |

### 治理与收益（`governance/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [governance/governance-yield-details.md](governance/governance-yield-details.md) | 176 | 治理与收益细化说明 |

### POLend（`polend/`）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| [polend/README.md](polend/README.md) | 30 | POLend 规格（四池模型 + PT/YT + settlement + 杠杆创世）聚合入口，下含 core/genesis/pt-yt-splitter/settlement-and-fees |
| [polend/core.md](polend/core.md) | 474 | POLend 模块边界 / 状态 / 债务推导 / 错误语义 / 互斥关系（§1-9） |
| [polend/genesis.md](polend/genesis.md) | 421 | POLend 创世流程（§1-7） |
| [polend/pt-yt-splitter.md](polend/pt-yt-splitter.md) | 234 | POLend PT/YT 生命周期 / POLSplitter settle / PT-YT 兑付（§1-3） |
| [polend/settlement-and-fees.md](polend/settlement-and-fees.md) | 855 | POLend fee 归集 / 结算编排 / 收益分发 / 权限配置 / Target ABI（§1-11） |

## 2. OCLPAR canonical-home 表

下表是 Phase 2 跨文档去冗余审计确立的"每条规则/概念权威主页"索引——**索引，不重述语义本体**。同名规则在其他文档出现均为引用，编辑应改 home。`polend/` 类目 canonical home 为 `polend/README.md`（子文件清单见 §1 POLend 区）。

### 2.1 常量群

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| `DAY`（1 天秒数） | [config-matrix.md §3](verse/config-matrix.md) | 时间常量权威值 |
| `unlockTime`（FIXED_LOCKUP_DURATION） | [config-matrix.md §3](verse/config-matrix.md) | 锁定期长度 |
| `UNLOCK_PROTECTION_WINDOW`（24h） | [config-matrix.md §3](verse/config-matrix.md) | 解锁保护窗口 |
| `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` | [config-matrix.md §3](verse/config-matrix.md) | 创世总资金聚合上限 |
| `PREORDER_SETTLEMENT_FEE_BPS`（1%） | [config-matrix.md §3](verse/config-matrix.md) | preorder 结算费率 |
| `tickSpacing` | [config-matrix.md §3](verse/config-matrix.md) | 池固定 tick 间距 |

### 2.2 不变量群（每条一行）

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| INV-01 注册单入口 | [invariants.md](invariants.md) | 注册写入链路单入口 |
| INV-02 memecoin→verseId 映射 | [invariants.md](invariants.md) | 注册时建立且不重写 |
| INV-03 治理链取 `omnichainIds[0]` | [invariants.md](invariants.md) | 治理链统一取首元素 |
| INV-04 启动结算显式路径 | [invariants.md](invariants.md) | 必须 Launcher→Hook |
| INV-05 Locked 费用分发恒等式 | [invariants.md](invariants.md) | 费用分发恒等约束 |
| INV-06 远端 msg.value 精确匹配 | [invariants.md](invariants.md) | 远端分发/staking 报价精确匹配 |
| INV-07 阶段机约束 | [invariants.md](invariants.md) | 关键业务动作受阶段机约束 |
| INV-07A Locked→Unlocked 同交易结算 | [invariants.md](invariants.md) | 结算与公开 swap 保护同交易落地 |
| INV-08 动态费池 + 固定 tickSpacing | [invariants.md](invariants.md) | Router/Hook 操作约束 |
| INV-09 代币增发权限集中 | [invariants.md](invariants.md) | 增发权限集中在 Launcher |
| INV-10 OFT compose replay 防护 | [invariants.md](invariants.md) | compose 回调具备 replay 防护 |
| INV-11 注册时间权威值 | [invariants.md](invariants.md) | 来自注册中心写入 |
| INV-12 解锁保护窗口优先 | [invariants.md](invariants.md) | 解锁后先经保护窗口再恢复 swap |
| INV-13 POLend 全局结算 bounded reserve | [invariants.md](invariants.md) | 全局结算只能用 bounded reserve 覆盖 dust |
| INV-14 POLend PT raw / uAsset backing 分离 | [invariants.md](invariants.md) | 必须分离 |
| INV-15 预兑付 PT fee 真实 supply 结清 | [invariants.md](invariants.md) | fee 由真实 PT supply 结清 |
| INV-16 normal fee entitlement / zero-backing dust | [invariants.md](invariants.md) | 保持可领取语义 |
| INV-17 创世总资金累计上限 | [invariants.md](invariants.md) | 累计且排除 preorder |
| INV-18 PT settlement backing 偿还 | [invariants.md](invariants.md) | backing 偿还不变量 |
| INV-19 PT backing ratio 实际额约束 | [invariants.md](invariants.md) | backing ratio 实际额约束 |

### 2.3 权限边界

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| lzCompose 授权 | [access-control.md §3](access-control.md) | lzCompose 调用授权 |
| Governor reward path | [access-control.md §4](access-control.md) | Governor 收益路径权限 |
| preorder settlement 权限 | [access-control.md §5](access-control.md) | preorder 结算权限边界 |

### 2.4 记账语义

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| actual spend（实际花费） | [accounting.md §3.2](verse/accounting.md) | 实际花费记账语义 |
| preorder settlement fee | [accounting.md §7.4](verse/accounting.md) | preorder 结算费记账 |

### 2.5 swap 边界

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| 收费/币种/native | [uniswap-v4.md §3](swap/uniswap-v4.md) | swap 栈收费语义、币种配置与 native 拒绝边界 |
| 普通动态 Swap 的一次选费、四路径、价格限制、容量、核心/最终用户 delta | [uniswap-v4.md §3.1–§3.2](swap/uniswap-v4.md) | 普通动态 Swap 的唯一 canonical |
| execute-or-revert | [uniswap-v4.md §4](swap/uniswap-v4.md) | 普通 swap 的执行边界 |
| Permit2 入口 | [permit2.md](swap/permit2.md) | Permit2 token 入口边界 |

### 2.6 跨链/interop

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| exact fee（精确费用） | [INV-06](invariants.md) | msg.value 精确匹配报价 |
| compose replay 防护 | [INV-10](invariants.md) | OFT compose 回调 replay 防护 |
| LayerZero OApp/OFT 集成边界 | [layerzero-oapp-oft.md §4](interoperation/layerzero-oapp-oft.md) | OApp/OFT 集成边界 |

### 2.7 governance custody

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| vault burn | [governance-yield-details.md §5](governance/governance-yield-details.md) | vault 销毁路径 |
| Governor custody + ledger | [governance-yield-details.md §5](governance/governance-yield-details.md) | Governor 托管与账本 |
| token 准入 | [governance-yield-details.md §7](governance/governance-yield-details.md) | 治理 token 准入规则 |

### 2.8 POLend 规则

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| POLend 四池/PT/YT/settlement/杠杆创世 | [polend/README.md](polend/README.md) | POLend 聚合入口（四池模型 + PT/YT + settlement + 杠杆创世） |
| POLend 模块边界 / 状态 / 债务推导 / 错误语义 / 互斥 | [polend/core.md](polend/core.md) | §1-9 |
| 创世流程（普通 / Preorder / 杠杆 / Genesis→Locked） | [polend/genesis.md](polend/genesis.md) | §1-7 |
| PT/YT 生命周期 / POLSplitter settle / PT-YT 兑付 | [polend/pt-yt-splitter.md](polend/pt-yt-splitter.md) | §1-3 |
| fee 归集 / 结算编排 / 收益分发 / 权限配置 / Target ABI | [polend/settlement-and-fees.md](polend/settlement-and-fees.md) | §1-11 |

### 2.9 注册/状态机权威

| 规则/概念 | canonical home | 说明 |
| --- | --- | --- |
| registerMemeverse 7 步执行序列 | [registration-details.md §10](verse/registration-details.md) | launcher 侧注册执行顺序权威 |
| Symbol 注册状态生命周期 | [state-machines.md §3.1](verse/state-machines.md) | symbol 状态迁移（Available/Active/Historical）权威 |

## 3. 相关真源

- 分层与冲突顺序：[docs/ARCHITECTURE.md](../ARCHITECTURE.md)
- 术语：[docs/GLOSSARY.md](../GLOSSARY.md)
- 控制文件与产物位置：[docs/TRACEABILITY.md](../TRACEABILITY.md)
- 实现证据（规则落地）：`src/**`、`test/**`
