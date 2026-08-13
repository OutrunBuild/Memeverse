# POLendUpgradeable 与 POLSplitterUpgradeable 规范

POLendUpgradeable 是杠杆 lending + settlement 编排子系统：管理市场注册、债务推导、PT/YT 拆分与兑付、Locked→Unlocked 编排，并依赖 POLSplitterUpgradeable 完成 PT backing ratio 的记录与 settlement。

本目录按主题组织为 4 个子文件，本文档为聚合导航入口。

## 文件导航

| 文件 | 覆盖 §节 | 主题 |
| --- | --- | --- |
| [core.md](core.md) | §1-9 | 文档定位/核心目标/术语（含 PT backing ratio 公式）/模块边界/市场注册/POLendUpgradeable 状态（含 §6.7 dust reserve 全局池）/债务推导/错误语义/互斥关系 |
| [genesis.md](genesis.md) | §1-7 | 普通创世/Preorder/门槛与杠杆上限/杠杆创世/Genesis→Locked（§5.2 四池部署、§5.3 初始 YT）/PT-YT 生命周期/初始 YT claim |
| [pt-yt-splitter.md](pt-yt-splitter.md) | §1-3 | PT/YT 生命周期（recordPTBackingRatio/split/merge/preview）/POLSplitterUpgradeable settle（含 §2.1 INV-18 验证）/PT-YT 兑付 |
| [settlement-and-fees.md](settlement-and-fees.md) | §1-11 | 辅助池 fee（1.1-1.5）/普通 fee 领取/辅助 LP 领取/Locked→Unlocked 编排（§4 唯一权威）/PT fee 预兑付三路径（5.1-5.3）/全局结算/杠杆残值+floor dust/uAsset mint-repay 权限/YieldDispatcherUpgradeable 分发/权限配置矩阵/Target ABI |

## 关键交叉引用

- PT backing ratio 链：`recordPTBackingRatio`（[pt-yt-splitter.md](pt-yt-splitter.md)）→ [INV-19](../invariants.md)
- settlement dust reserve 链：[core.md §6.7](core.md)（全局池定义）→ [genesis.md §5.1](genesis.md)（credit 引用）
- §4 Locked→Unlocked 编排唯一权威：[core.md §4.1](core.md)（模块边界自引用）指向 [settlement-and-fees.md §4](settlement-and-fees.md)
- preRedeemPTFee 三路径：[settlement-and-fees.md §5.1-5.3](settlement-and-fees.md)

## 外部依赖清单

POLendUpgradeable 在以下 canonical home 文件中定义其依赖的语义（以下均为本目录之外）：

- invariants：[INV-04 / INV-13 / INV-14 / INV-15 / INV-18 / INV-19](../invariants.md)
- access control：[access-control.md](../access-control.md)
- accounting §7.4 preorder settlement fee：[verse/accounting.md](../verse/accounting.md)
- governance-yield §5 / §7：[governance/governance-yield-details.md](../governance/governance-yield-details.md)
