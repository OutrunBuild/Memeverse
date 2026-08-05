# MemeverseV2 治理与收益细化说明

## 1. 目标

本文解释 yield vault、governor treasury 与 governance cycle incentivizer 在 V2 中如何协作，以及 fee / yield / reward 在账本上的流向。

## 2. 三个核心模块

- `MemecoinYieldVault`
  - 持有 memecoin 收益
  - 铸造 share token
  - 管理延迟赎回队列
- `MemecoinDaoGovernorUpgradeable`
  - 作为 DAO treasury 入口
  - 接收 uAsset treasury 收入
  - 执行治理动作
- `GovernanceCycleIncentivizerUpgradeable`
  - 记录 treasury / reward 周期账本
  - 结算 reward
  - 按上一周期的 `asset-denominated votes`（资产计价投票权）分发奖励

`asset-denominated votes`（资产计价投票权）指把 YieldVault 委托的 share 投票单位，按对应时点的 underlying 资产价值换算后得到的投票权，而不是直接使用 share 数量。当前 `MemecoinYieldVault` 使用 exchange rate 与固定虚拟缓冲 V 进行当前值和历史值换算，因此治理计票与 reward 分账使用的是该资产计价后的 votes。

## 3. fee 到治理与收益的分流

launcher 从 `memecoin/uAsset` 主池与三个辅助池捕获 fee 后，目标主分流为：

- 主池 `memecoin/uAsset` fee
  - `memecoin` fee 进入 yield 路径
  - `uAsset` fee 拆成 `executorReward + govFee`
- 辅助池 `POL/uAsset`、`PT/uAsset`、`PT/POL` fee
  - POL fee burn
  - 普通侧 `uAsset/PT` fee 进入普通 fee 领取账本
  - 杠杆侧 `uAsset` fee 进入 governor treasury 路径
  - 杠杆侧 `PT` fee 在 settle 前通过 `preRedeemPTFee` 预兑付成 `uAsset` 后分发；settle 后通过 `POLSplitter.redeemPT` 兑成 `uAsset` 后分发
  - settle 前捕获但未主动分发的杠杆侧 PT fee 记为 pending，后续 settled 后再 `redeemPT` 分发
  - 辅助池 fee 分流的 token 级处理与操作语义 home 在 [docs/spec/polend/settlement-and-fees.md §1](../polend/settlement-and-fees.md)，PT fee 的预兑付 / settle 后 redeem / pending 规则 home 在 [docs/spec/polend/settlement-and-fees.md §5](../polend/settlement-and-fees.md)；分账口径与 full-precision `mulDiv` 约束见 [docs/spec/verse/accounting.md](../verse/accounting.md) §5.2
- `memecoin` yield
  - 进入 yield 路径

进一步流向（`UASSET` → `Governor.receiveTreasuryIncome`、`MEMECOIN` → `YieldVault.accumulateYields`、非合约 receiver → burn）以 [docs/spec/interoperation/interoperation-details.md](../interoperation/interoperation-details.md) §3.3 为跨链终点 canonical；本链/异链分发路径见该文档 §3.1/§3.2。

## 4. YieldVault 的份额模型

YieldVault 不是简单余额池，而是 share 模型：

- 用户 deposit underlying memecoin
- vault 按当前 `price = (totalAssets + V) / (totalSupply + V)` 关系铸造 / 赎回 shares
- yield 进入后增加 `totalAssets`
- share 汇率随之变化

因此 vault 的核心不是“固定收益率”，而是“share 对 underlying 的兑换关系”。

### 4.1 虚拟缓冲 V

share 与 underlying 的转换使用一个**虚拟缓冲 V**：在虚拟资产与虚拟份额两侧同时引入同一常数 V，即 `virtualAssets = virtualSupply = V`。

- 转换公式（覆盖 deposit / redeem / preview / votes 转换）
  - `shares = assets × (totalSupply + V) / (totalAssets + V)`
  - `assets = shares × (totalAssets + V) / (totalSupply + V)`
- 初始（空金库）`price = (0 + V) / (0 + V) = 1`，即 1 share = 1 wei underlying；该单点价格与无缓冲的 `+1` 语义一致，但这只是 `totalSupply == 0` 且 `totalAssets == 0` 这一点的巧合
- 一旦 `totalAssets != totalSupply`，`+1` 等价于 `price = (totalAssets + 1) / (totalSupply + 1)`，与本模型的 `(totalAssets + V) / (totalSupply + V)` 数学不再等价：V 是部署时一次写死的常数虚拟缓冲，而非每次调用 `+1` 量级的 per-call seed
- V 在治理链 deploy vault 时由 Launcher 计算后传入 `vault.initialize(...)`，vault 存储写住后**永久固定，不可改**

V 的推导规则（固定推导，不是独立配置项）：

```
V = minTotalFund × fundBasedAmount × 7 / 1000   // 即 0.7%
```

等价于「最小主池 memecoin 的 1%」（主池占创世资金 70%）。`minTotalFund` 与 `fundBasedAmount` 取自 `FundMetaData`（per-uAsset，现有字段，不加新字段）；`0.7%` 是 Launcher 端常量，不是 owner 可配项。推导口径与配置来源见 [docs/spec/verse/config-matrix.md](../verse/config-matrix.md) §3。

### 4.2 为什么需要 V

memecoin 金库是**高收益金库**：yield 到来的量级往往与真实本金同量级。本文用 `D_total` 指代 vault 当前真实资产 `totalAssets`（含历史 yield，**不含**虚拟缓冲 V，也**不是**仅指初始本金）。若用裸 `totalAssets / totalSupply`，yield 一进入：

- `price` 涨幅 = `Y / D_total`，当 `Y` 与 `D_total` 同量级时，单次 yield 可使汇率数倍膨胀
- 首个 / 早存入者会在 yield 进入瞬间攫取绝大部分收益

V 的作用是把汇率膨胀缓冲掉一层：

- 有 V 后 `price` 涨幅 = `Y / (D_total + V)`，被 V 稀释
- 初始阶段 `D_total ≪ V` 时缓冲最强，随 `D_total` 增长到 `≫ V`，缓冲自动退化，vault 退化为普通金库

### 4.3 资金流代价

V 的缓冲不是免费的：yield 进入时，按

```
V / (D_total + V)
```

比例的 yield 会被「虚拟份额」吸收并**永久锁定**，这部分 yield 永远无法被任何 share 持有人赎回，等价于锁死在金库内。这是 memecoin 高收益金库换取汇率稳定性的必要代价：

- `D_total ≪ V` 时吸收比例接近 1，几乎所有 yield 被吸收（但此时 vault 刚起步，真实本金也小）
- `D_total ≫ V` 时吸收比例趋近 0，yield 几乎全额计入可赎回 share

该吸收是单向不可逆的：被吸收的 yield 不会随 vault 缩水回流，也不会被任何角色提取。这里的 `D_total` 口径与 §4.2 一致（vault 当前真实 `totalAssets`，含历史 yield，不含 V，**不是**初始本金）。

物理上，被吸收的 yield 仍计在 `vault.totalAssets` 内、随 vault 资产一起存在，但它对应的是虚拟份额，没有真实持有人，因此不进入任何 fee / treasury / reward 路径，合约也没有任何提取这部分资产的入口。这是设计代价，不是资金丢失，也不是可被后续升级回收的余额。

## 5. 为什么 `totalSupply == 0` 时要 burn yield

当 vault 还没有任何 share 持有人时，历史 yield 不能留在池中等待第一个存入者白拿。

因此当前规则是：

- 若 `totalSupply == 0`
- 收到 yield 时直接 burn

这条规则的目标是防止首存者攫取历史收益。

该 burn 规则与 §4 的虚拟缓冲 V 正交，但正交点不是 `totalSupply` 本身：share/asset 转换公式（§4.1）中 V 无条件参与，当 `totalAssets == totalSupply`（含全新空金库的 `(0 + V) / (0 + V)`）时恰好约掉、price 为 1；当 vault 因全额赎回而残留 §4.3 的吸收收益（`totalSupply == 0` 但 `totalAssets > 0`）时，V 依然参与转换，使汇率保持有定义且非退化（无 V 时 `assets × 0 / totalAssets` 恒为 0 份额）；残留态（`totalSupply == 0`）下低于 `(totalAssets + V) / V` 的存款在 `deposit` 时向下取整为 0 份额，`deposit` 显式 `revert ZeroSharesDeposit()` 拒绝该笔存款（资产留在调用方、不并入残留收益），防止小额定金本金被静默吸收（一般态即 `totalSupply > 0` 时的 0 份额阈值按 §4.1 公式为 `(totalAssets + V) / (totalSupply + V)`）。与 V 正交的是 burn 规则本身：空金库阶段 yield 直接 burn，不进入 `totalAssets`，因此不进入 V 缓冲吸收路径。

## 6. 延迟赎回队列

V2 当前没有即时赎回 underlying，而是：

1. `requestRedeem`
2. 进入队列
3. 等待 `REDEEM_DELAY`
4. `executeRedeem`

关键约束：

- 每个地址最多 `MAX_REDEEM_REQUESTS`
- 请求时即锁定本次 underlying 数量
- 实际转账在执行时完成
- `requestRedeem` 仅允许自我赎回：`receiver == msg.sender`，否则 revert `NotSelfRedemption()`。禁止第三方代排队的理由：`MAX_REDEEM_REQUESTS` 按 receiver 计数，若允许任意 `msg.sender` 向任意 receiver 排队，攻击者可用 5 wei dust 填满受害者的 5 个队列槽位，使受害者自己的赎回请求 revert `MaxRedeemRequestsReached()`；而 `executeRedeem` 只清成熟条目（`block.timestamp >= requestTime + REDEEM_DELAY`），该锁定持续 `REDEEM_DELAY` 并可每日重填，构成低成本可持续的退出封锁

这个模型的目的，是降低 flash 攻击和瞬时套利对 vault 的影响。

## 7. Governor Treasury 语义

`registerTreasuryToken` 必须在不可嵌套的 Governor `_executeOperations` 中作为唯一 operation 执行（`registration-only`，即只完成 token 注册/确认）；同一次 execution 不得再包含该 token 的支出、direct ERC20 target 或其他 operation。Incentivizer 完成注册后会回调 Governor 的 registration confirmation；该回调要求 execution 正在进行且 operation count 为 1，所以注册必须是 standalone operation。

受支持的 treasury spend path 只有 `Governor.sendTreasuryAssets(token, to, amount)`：该路径先调用 `Incentivizer.recordTreasuryAssetSpend` 更新 treasury ledger，再从 Governor 真实转账。该路径同时受到 Governor 的 execution-time balance-ratio 检查。

将 ERC20 合约直接作为 generic Governor execution target 的 direct ERC20 path 不属于受支持的 treasury spend path。若当前 generic execution 仍允许该 target，它不调用 `Incentivizer.recordTreasuryAssetSpend`，也不更新 Incentivizer ledger；只有 token 已注册且 execution 前 `Governor` 余额为正时，才进入现有 ratio loop。未注册 token 和 execution 前零余额按当前实现不进入 ratio/ledger 保护，治理不得将 direct target 当作 treasury spend 保护。

### 7.1 提案人 outstanding 标记

`proposer outstanding`（提案人未完成提案标记）是 Governor 按 proposer 保存的最近 proposal id。`propose` 会读取这个已保存 proposal 的状态：当该状态既不是 `Defeated` 也不是 `Succeeded` 时，同一 proposer 再次 `propose` 会回滚；进入这两种状态之一后，才可创建新 proposal，并用新 id 覆盖标记。这个检查是正常路径的 guard，不构成每个 proposer 绝对只能有一个未完成 proposal 的 invariant。

`propose` 成功后写入新 id；`execute` 和 `_cancel` 仅在当前 marker 仍等于正在处理的 proposalId 时清零；若 marker 已更新为较新的 proposalId，则保留该较新 marker。`Defeated` 和 `Succeeded` 仍会放行新 proposal，因此该标记是正常路径的 guard，不构成每个 proposer 绝对只能有一个未完成 proposal 的 invariant。

### 7.2 Treasury spend cap 与执行快照

`maxTreasurySpendRatio` 是 `treasury spend cap`（国库支出上限），单位为 basis points（基点），分母固定为 `10000`；例如 `500` 表示 `5%`。它只约束一次 Governor execution 中已注册 treasury token 的实际余额减少。

Governor 在 `_executeOperations` 开始执行 proposal actions 前，从 Incentivizer 读取执行开始时的 registered treasury token list，并为列表中的每个 token 快照 `pre = IERC20(token).balanceOf(Governor)`。所有 operation 执行完成后，按同一列表逐 token 检查：

- `pre == 0` 时跳过该 token；
- `post >= pre` 时没有支出，跳过该 token；
- 仅当 `post < pre` 时，计算 `spent = pre - post`；
- 计算 `limit = pre * maxTreasurySpendRatio / 10000`，并要求 `spent <= limit`，否则整次 execution 回滚。

该循环使用执行开始时取得的已注册列表；registration-only operation 新注册的 token 不会加入本次执行已经建立的余额快照。余额 delta 检查也不替代 `sendTreasuryAssets` 的 ledger hook。

### 7.3 Self-call 的 supermajority

`supermajority`（超级多数）指赞成票占全部计入该 proposal 的赞成、反对和弃权票的最低比例。只要 proposal 的 targets 中有任一项是 Governor 自身的 self-call，就适用 `upgradeSupermajorityRatio`，不只适用于升级操作。

其判定为：

```text
forVotes / (forVotes + againstVotes + abstainVotes)
    >= upgradeSupermajorityRatio / 10000
```

其中分母包含 `forVotes`、`againstVotes` 和 `abstainVotes`，不是只取赞成票与反对票，也不是 quorum 或总供应量。实现使用等价的整数比较 `forVotes * 10000 >= totalVotes * upgradeSupermajorityRatio`。

Governor 在 V2 中不只是投票入口，也是 DAO treasury 与 governance reward payout 的唯一资产托管者。

治理与奖励路径采用以下固定语义：

- `MemecoinDaoGovernorUpgradeable`
  - 持有 DAO treasury 资产
  - 持有 governance reward payout 资产
  - 执行真实 treasury 收款、真实 treasury 支出与真实 reward payout
- `GovernanceCycleIncentivizerUpgradeable`
  - 维护 treasury ledger
  - 维护 reward ledger
  - 负责 cycle finalize 与用户 reward claim 结算
  - 不承担奖励资产托管职责

因此：

- `Governor` 中的真实 ERC20 余额才是 DAO treasury / reward payout 的 canonical asset state
- `Incentivizer` 中的 `treasuryBalances` 与 `rewardBalances` 只是针对 `Governor` 托管资产的账本视图，不等同于 `Incentivizer` 的 ERC20 实际余额
- 除文档显式声明 escrow 模式外，`Incentivizer` 不应作为 reward token 的 canonical holder
- `registerTreasuryToken(...)` 与 `registerRewardToken(...)` 仅允许治理注册已审查的标准 ERC20
- fee-on-transfer、rebasing、或其他会使名义 `amount` 与实际余额变化不一致的 token 不在支持范围内
- treasury / reward 资产准入责任由治理承担，不由运行时 delta 检查兜底

Treasury income 与通过 `Governor.sendTreasuryAssets` 发起的 treasury spend 调用链为：

- `Governor.receiveTreasuryIncome(token, amount)`
  - 表示真实资产进入 DAO treasury
  - 在同一事务中把 `token` 转入 `Governor`
  - 再调用 `Incentivizer.recordTreasuryIncome(token, amount)` 把这笔收入登记到当前周期账本
- `Governor.sendTreasuryAssets(token, to, amount)`
  - 表示真实 treasury 支出
  - 在同一事务中先调用 `Incentivizer.recordTreasuryAssetSpend(token, to, amount)` 把这笔支出登记到当前周期账本
  - 再把真实 token 从 `Governor` 转给 `to`

这里：

- `Incentivizer.recordTreasuryIncome(token, amount)` 是纯账本动作，不发生 token transfer
- `Incentivizer.recordTreasuryAssetSpend(token, to, amount)` 是纯账本动作，不发生 token transfer

## 8. Incentivizer 周期语义

Incentivizer 负责把 treasury ledger 的一部分，按周期转成 reward ledger，并按用户投票份额结算奖励。

关键要点：

- 周期长度固定
- `rewardRatio`（奖励比例）是以 basis points 表示的 treasury-to-reward 划拨比例；`finalizeCurrentCycle()` 按 `rewardAmount = treasuryBalance * rewardRatio / 10000` 把满足条件的 treasury ledger 余额划入 reward ledger
- 用户最终按“上一周期 userVotes / totalVotes”获取奖励
- `finalizeCurrentCycle()` 的核心语义是账本切换与结算，不要求把 token 从 `Governor` 转入 `Incentivizer`
- 上一周期未领完的 `rewardBalances` 会在后续 `finalizeCurrentCycle()` 时回卷到 treasury ledger

因此 reward 分发依赖的不是实时余额，而是周期化结算。

用户奖励领取入口采用以下固定语义：

- 用户通过 `Incentivizer.claimReward()` 领取奖励
- 第一版只支持 `msg.sender` 领取给自己，不支持指定 `receiver`，不支持代领
- `Incentivizer.claimReward()` 在同一事务中：
  1. 以 `msg.sender` 作为 reward owner 计算上一周期可领奖励
  2. 扣减上一周期对应的 `rewardBalances`
  3. 调用 `Governor.disburseReward(token, msg.sender, amount)` 完成真实付款
- `Governor.disburseReward(...)` 的调用方权限（仅配对 `Incentivizer`、非通用 treasury 支出）见 [docs/spec/access-control.md](../access-control.md) §4
- 若 `Governor.disburseReward(...)` 失败，则整笔 claim 回滚，账本扣减也回滚

## 9. 权限边界

Governance reward path 的权限边界（`Governor.sendTreasuryAssets` / `disburseReward`、`Incentivizer.recordTreasuryIncome` / `recordTreasuryAssetSpend` / `claimReward` / `finalizeCurrentCycle` 的调用方与 reward owner 语义）以 [docs/spec/access-control.md](../access-control.md) §4 为 canonical。

阅读建议：对开放入口要关注其调用前提，而不是只看是否 `onlyGovernance`；`claimReward()` 必须始终把终端用户 `msg.sender` 视为 reward owner。

## 10. 当前实现提醒

Governor 托管资产、Incentivizer 维护账本的 custody/ledger 分层是本文件的固定边界，定义见 §7。reward 不是在 fee 到达时立即逐用户发放，而是先进入 treasury ledger，再在 finalize 后转成 reward ledger，最后由用户 claim（周期语义见 §6、§8）。若后续引入更多治理金融化能力，必须继续尊重该边界。

## 11. 相关真源与证据

- [docs/spec/verse/accounting.md](../verse/accounting.md)
- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/verse/deployment.md](../verse/deployment.md)
- [docs/implementation-map.md](../../implementation-map.md)
- [docs/TRACEABILITY.md](../../TRACEABILITY.md)
