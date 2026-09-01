# Memeverse 治理与收益细化说明

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

`asset-denominated votes`（资产计价投票权）指把 YieldVault 委托的 share 投票单位，按对应时点的 underlying 资产价值换算后得到的投票权，而不是直接使用 share 数量。当前 `MemecoinYieldVault` 使用 exchange rate 与固定虚拟资产缓冲（`virtualAssets`） 进行当前值和历史值换算，因此治理计票与 reward 分账使用的是该资产计价后的 votes。

### 2.1 时钟域（ERC-6372 timestamp 时钟）

vault 的治理时钟是 **timestamp 域**（ERC-6372），不是 block 域：

- `MemecoinYieldVault.sol::clock` 返回 `uint48(block.timestamp)`，`MemecoinYieldVault.sol::CLOCK_MODE` 返回 `"mode=timestamp"`。votes 基类 `OutrunVotesInit.sol::clock` 默认返回 `Time.timestamp()`，`OutrunVotesInit.sol::CLOCK_MODE` 默认返回 `"mode=timestamp"` 并带 `ERC6372InconsistentClock` 一致性守卫（守卫比较对象为 `Time.timestamp()`；子类改动 `clock()` 语义后，调用基类 `CLOCK_MODE()` 会 revert `ERC6372InconsistentClock`）。默认采用 timestamp 时钟的理由：Arbitrum Nitro/Orbit 系链上 `block.number` 返回 L1（Ethereum）区块号，同一 L1 高度内多个 L2 区块时钟不前进、L1 reorg 时可回退，破坏 ERC5805 checkpoint 单调性；timestamp 时钟在这些链上单调不减：秒级粒度的时间戳可被相邻 L2 区块共享（区块时间约 250ms），时钟不会回退但并非严格递增，checkpoint 键为非递减而非严格递增。vault 保留这两个显式 override，与基类语义一致；vault 的 `CLOCK_MODE` override 为 pure、不经该守卫。
- governor 的时钟委托采用 vault：`MemecoinDaoGovernorUpgradeable.sol` 继承 OZ `GovernorVotesUpgradeable.sol::clock`（`try token().clock()`，token 即部署时传入的 `IVotes(yieldVault)`，见 `MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer`），`GovernorVotesUpgradeable.sol::CLOCK_MODE` 同样委托 `token().CLOCK_MODE()`；governor 自身不 override 这两个函数。
- 派生语义：OZ `GovernorUpgradeable.sol::_propose` 中计算 `snapshot = clock() + votingDelay()`，因此生产配置 `votingDelay = 1 days`、`votingPeriod = 1 weeks`（`MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer` 传入 governor initialize）以秒计：86400 / 604800 秒；提案快照与投票截止均为 timestamp 域 timepoint。`MemecoinDaoGovernorUpgradeable.sol::votingDelay` / `::votingPeriod` 的返回单位即 governor clock units。
- 查询语义：`OutrunVotesInit.sol::getPastVotes` / `::getPastTotalSupply` 需要 timestamp 域 timepoint。按 block 域查询（如 `getPastVotes(block.number)`）不报错但恒得 0：checkpoint 键是时间戳（`_writeTotalAssetCheckpoint` 以 `clock()` 为键），`upperLookupRecent` 对键小于首个 checkpoint 的查询无命中、返回 0（OZ `Checkpoints.sol::upperLookupRecent`）。timestamp 域查询则受 `OutrunVotesInit.sol::_validateTimepoint` 约束：查询当前或未来 timepoint 会 revert `ERC5805FutureLookup`。

### 2.2 票权激活前提与归属

- 票权须委托激活：份额本身不自动产生票权，持有人须先调用 `OutrunVotesInit.sol::delegate`（通常 `delegate(self)`）激活 checkpoint 才产生票权——OZ Votes 默认不自动激活，未 delegate 时 `OutrunVotesInit.sol::getPastVotes` 恒为零，该账户的份额不产生任何票权：不计入提案门槛（`MemecoinDaoGovernorUpgradeable.sol::proposalThreshold` 为 GovernorSettings 存储参数，且仅治理可通过 `GovernorSettingsUpgradeable.sol::setProposalThreshold` 更新；OZ `GovernorUpgradeable.sol::propose` 以 `getVotes(proposer, clock() − 1)`（委托 `token().getPastVotes`）与 `proposalThreshold()` 比较）也不构成计票。注意与总票基数的区别：`OutrunVotesInit.sol::getPastTotalSupply`（资产计价）按份额记录、与委托状态无关，未委托份额仍计入动态 quorum 基数——抬高所需票数而非贡献票权（治理启动前置条件见 §7.6）。
- `deposit` 的 receiver 开放：`MemecoinYieldVault.sol::deposit` 从 `msg.sender` 拉取资产、把份额铸给任意 `receiver`，铸出份额的票权随 `receiver` 的委托状态归属、与存款人无关——向第三方 receiver 存款不会给存款人计票；与 `MemecoinYieldVault.sol::requestRedeem` 的自我赎回限制（`controller == msg.sender && owner == msg.sender`，否则 revert `NotSelfRedemption`，见 §6）构成开放/封闭对照。

## 3. fee 到治理与收益的分流

launcher 从 `memecoin/uAsset` 主池与三个辅助池捕获 fee 后，目标主分流为：

- 主池 `memecoin/uAsset` fee
  - `memecoin` fee 进入 yield 路径
  - `uAsset` fee 拆成 `executorReward + govFee`
- 辅助池 `POL/uAsset`、`PT/uAsset`、`PT/POL` fee
  - POL fee burn
  - 普通侧 `uAsset/PT` fee 进入普通 fee 领取账本
  - 杠杆侧 `uAsset` fee 进入 governor treasury 路径
  - 杠杆侧 `PT` fee 在 settle 前通过 `preRedeemPTFee` 预兑付成 `uAsset` 后分发；settle 后通过 `POLSplitterUpgradeable.redeemPT` 兑成 `uAsset` 后分发
  - settle 前捕获但未主动分发的杠杆侧 PT fee 记为 pending，后续 settled 后再 `redeemPT` 分发
  - 辅助池 fee 分流的 token 级处理与操作语义 home 在 [docs/spec/polend/settlement-and-fees.md §1](../polend/settlement-and-fees.md)，PT fee 的预兑付 / settle 后 redeem / pending 规则 home 在 [docs/spec/polend/settlement-and-fees.md §5](../polend/settlement-and-fees.md)；分账口径与 full-precision `mulDiv` 约束见 [docs/spec/verse/accounting.md](../verse/accounting.md) §5.2
- `memecoin` yield
  - 进入 yield 路径

进一步流向（`UASSET` → `Governor.receiveTreasuryIncome`、`MEMECOIN` → `YieldVault.accumulateYields`、非合约 receiver 按 tokenType 分流：MEMECOIN→burn、UASSET→`protocolTreasury`）以 [docs/spec/interoperation/interoperation-details.md](../interoperation/interoperation-details.md) §3.3 为跨链终点 canonical；本链/异链分发路径见该文档 §3.1/§3.2。

## 4. YieldVault 的份额模型

YieldVault 不是简单余额池，而是 share 模型：

- 用户 deposit underlying memecoin
- vault 按当前 `price = (totalAssets + virtualAssets) / (totalSupply + virtualAssets)` 关系铸造 / 赎回 shares
- yield 进入后增加 `totalAssets`
- share 汇率随之变化

因此 vault 的核心不是“固定收益率”，而是“share 对 underlying 的兑换关系”。

### 4.1 虚拟资产缓冲（`virtualAssets`）

share 与 underlying 的转换使用一个**虚拟资产缓冲（`virtualAssets`）**：在虚拟资产与虚拟份额两侧同时引入同一常数，即 `virtualAssets = virtualSupply`。

- 转换公式（覆盖 deposit / redeem / preview / votes 转换）
  - `shares = assets × (totalSupply + virtualAssets) / (totalAssets + virtualAssets)`
  - `assets = shares × (totalAssets + virtualAssets) / (totalSupply + virtualAssets)`
- 初始（空金库）`price = (0 + virtualAssets) / (0 + virtualAssets) = 1`，即 1 share = 1 wei underlying；该单点价格与无缓冲的 `+1` 语义一致，但这只是 `totalSupply == 0` 且 `totalAssets == 0` 这一点的巧合
- 一旦 `totalAssets != totalSupply`，`+1` 等价于 `price = (totalAssets + 1) / (totalSupply + 1)`，与本模型的 `(totalAssets + virtualAssets) / (totalSupply + virtualAssets)` 数学不再等价：virtualAssets 是部署时一次写死的常数虚拟缓冲，而非每次调用 `+1` 量级的 per-call seed
- virtualAssets 在治理链 deploy vault 时由 Launcher 计算后传入 `vault.initialize(...)`，vault 存储写住后**永久固定，不可改**
- `totalAssets` 携带隐式上界 `2^208 − 1`（即 `type(uint208).max`）：资产侧治理检查点 `OutrunVotesInit.sol::_totalAssetsCheckpoint` 是 uint208 存储，`OutrunVotesInit.sol::_writeTotalAssetCheckpoint` 中的 `SafeCast.toUint208(totalAssets)` 在超过上界时 revert；`MemecoinYieldVault.sol::_accumulateYield` 与 `MemecoinYieldVault.sol::_deposit` 在 `totalAssets +=` 更新后以命名错误校验（named-error require）强制该上界，超出即 revert 对应入口
- 该上界是 defense-in-depth：状态实际不可达（vault `totalAssets` ≤ memecoin 真实余额 ≤ memecoin 供应量；memecoin 供应量本身无 uint208 硬上限（不经 `OutrunERC20VotesInit`），不可达性依赖 Launcher 门控铸造），与 `OutrunERC20VotesInit.sol::_maxSupply` 的 share 侧上限理由形成对比

virtualAssets 的推导规则（固定推导，不是独立配置项）：

```
virtualAssets = minTotalFund × fundBasedAmount × 7 / 1000   // 即 0.7%
```

等价于「最小主池 memecoin 的 1%」（主池占创世资金 70%）。`minTotalFund` 与 `fundBasedAmount` 取自 `FundMetaData`（per-uAsset，现有字段，不加新字段），取值时点为治理链 deploy vault（Genesis→Locked 触发）时刻的当前值，非注册时快照；owner 在注册至 Locked 窗口内变更 `MemeverseLauncherUpgradeable.sol::setFundMetaData` 会改变 V 缓冲，为预期语义（vault 写入后永久固定不变）。`0.7%` 是 Launcher 端常量，不是 owner 可配项。推导口径与配置来源见 [docs/spec/verse/config-matrix.md](../verse/config-matrix.md) §3。

### 4.2 为什么需要虚拟资产缓冲

memecoin 金库是**高收益金库**：yield 到来的量级往往与真实本金同量级。本文用 `D_total` 指代 vault 当前真实资产 `totalAssets`（含历史 yield，**不含**虚拟资产缓冲（`virtualAssets`），也**不是**仅指初始本金）。若用裸 `totalAssets / totalSupply`，yield 一进入：

- `price` 涨幅（相对） = `Y / D_total`，当 `Y` 与 `D_total` 同量级时，单次 yield 可使汇率数倍膨胀
- 首个 / 早存入者会在 yield 进入瞬间攫取绝大部分收益

virtualAssets 的作用是把汇率膨胀缓冲掉一层：

- 有 virtualAssets 后 `price` 涨幅（相对） = `Y / (D_total + virtualAssets)`，被 virtualAssets 稀释
- 初始阶段 `D_total ≪ virtualAssets` 时缓冲最强，随 `D_total` 增长到 `≫ virtualAssets`，缓冲自动退化，vault 退化为普通金库

### 4.3 资金流代价

virtualAssets 的缓冲不是免费的：yield 进入时，按

```
virtualAssets / (totalSupply + virtualAssets)
```

比例的 yield 会被「虚拟份额」吸收并**永久锁定**，这部分 yield 永远无法被任何 share 持有人赎回，等价于锁死在金库内。这是 memecoin 高收益金库换取汇率稳定性的必要代价：

- `totalSupply ≪ virtualAssets` 时吸收比例接近 1，几乎所有 yield 被吸收（但此时 vault 刚起步，真实本金也小）
- `totalSupply ≫ virtualAssets` 时吸收比例趋近 0，yield 几乎全额计入可赎回 share

该吸收是单向不可逆的：被吸收的 yield 不会随 vault 缩水回流，也不会被任何角色提取。吸收比例只由 share 侧的 `totalSupply` 与 `virtualAssets` 决定，与资产侧 `totalAssets`（即 §4.2 的 `D_total`）口径无关：`totalAssets` 增长不改变吸收比例，只有 `totalSupply` 相对 `virtualAssets` 增长时比例才衰减。

物理上，被吸收的 yield 仍计在 `vault.totalAssets` 内、随 vault 资产一起存在，但它对应的是虚拟份额，没有真实持有人，因此不进入任何 fee / treasury / reward 路径，合约也没有任何提取这部分资产的入口。这是设计代价，不是资金丢失，也不是可被后续升级回收的余额。高 rate 态（share 供应远小于资产，含残留态）下，share-mint floor（`MemecoinYieldVault.sol::_convertToShares`）丢弃的分数股在赎回（`MemecoinYieldVault.sol::_convertToAssets`）时按汇率放大为往返损失，损失上界 ≈ 1 股 × 汇率（即 ≤ rate + 1 wei）。该损失留在 `totalAssets`、无对应 share：残留态（`totalSupply == 0`）下全额并入无人可提取的无主残留池；非残留态下按 §4.3 的虚拟份额吸收比例，`virtualAssets / (totalSupply + virtualAssets)` 部分永久锁定，其余经汇率抬高归现有持有人。

## 5. 为什么 `totalSupply == 0` 时要 burn yield

当 vault 还没有任何 share 持有人时，历史 yield 不能留在池中等待第一个存入者白拿。

因此当前规则是：

- 若 `totalSupply == 0`
- 收到 yield 时直接 burn

这条规则的目标是防止首存者攫取历史收益。

该 burn 规则与 §4 的虚拟资产缓冲（`virtualAssets`） 正交，但正交点不是 `totalSupply` 本身：share/asset 转换公式（§4.1）中 virtualAssets 无条件参与，当 `totalAssets == totalSupply`（含全新空金库的 `(0 + virtualAssets) / (0 + virtualAssets)`）时恰好约掉、price 为 1；当 vault 因全额赎回而残留 §4.3 的吸收收益（`totalSupply == 0` 但 `totalAssets > 0`）时，virtualAssets 依然参与转换，使汇率保持有定义且非退化（无 virtualAssets 时 `assets × 0 / totalAssets` 恒为 0 份额）；残留态（`totalSupply == 0`）下低于 `(totalAssets + virtualAssets) / virtualAssets` 的存款在 `deposit` 时向下取整为 0 份额，`deposit` 显式 `revert ZeroSharesDeposit()` 拒绝该笔存款（资产留在调用方、不并入残留收益），防止小额定金本金被静默吸收（一般态即 `totalSupply > 0` 时的 0 份额阈值按 §4.1 公式为 `(totalAssets + virtualAssets) / (totalSupply + virtualAssets)`）。与 virtualAssets 正交的是 burn 规则本身：空金库阶段 yield 直接 burn，不进入 `totalAssets`，因此不进入 virtualAssets 缓冲吸收路径。该零份额守卫只覆盖向下取整为 0 份额的情形；达到阈值以上的存款仍因 share-mint floor 承受亚 1 股的部分吸收（往返损失，见 §4.3），损失上界 ≤ 亚 1 股 × 当前汇率 + 1 wei（精确值见 `test/yield/MemecoinYieldVault.t.sol::test_RoundTripLossInResidualState` 与 `::test_RoundTripLossInHighRateState` 钉住用例）。该 ~1 wei 量级仅适用于汇率 ≈ 1（`totalAssets ≈ totalSupply`）的场景；高 rate 态（含残留态）下损失随汇率放大至 ~1 股 × rate 量级。

## 6. 延迟赎回队列

V2 当前没有即时赎回 underlying，而是：

1. `requestRedeem`
2. 进入队列
3. 等待 `REDEEM_DELAY`
4. `redeem` / `withdraw` claim（从成熟队列转出锁定的 assets，见 §6.2）

关键约束：

- 每个地址最多 `MAX_REDEEM_REQUESTS`（`MemecoinYieldVault.sol::MAX_REDEEM_REQUESTS` = 5，含已到期未领取条目；满队列时需先 `redeem`/`withdraw` 领取释放才能再 `requestRedeem`；到期不自动移除，条目仅在被完全消费后经 swap-pop 移除。该 5 条上限为 `MemecoinYieldVault.sol::maxWithdraw`/`_claimableShares`/claim 扫描的 gas 有界性而设（当前 5 × 双 SLOAD），放宽需重估）
- 治理投票权：`requestRedeem` 时立即 `MemecoinYieldVault.sol::_requestWithdraw`（`_burn` → `totalAssets -= lockedAssets` → `MemecoinYieldVault.sol::_writeTotalAssetCheckpoint`），该仓位的 `getVotes`/`getPastVotes`（资产计价 via `MemecoinYieldVault.sol::_convertVotes` / `MemecoinYieldVault.sol::_convertPastVotes` over `OutrunVotesInit.sol::_totalAssetsCheckpoint`）在请求时刻即降至烧后检查点，`REDEEM_DELAY` 窗口内快照为零且 `redeem`/`withdraw` 不回补（快照已固定），等价于提前一天退出治理；合约锚点 `MemecoinYieldVault.sol::requestRedeem` / `MemecoinYieldVault.sol::_requestWithdraw` / `OutrunVotesInit.sol::getPastVotes`
- 请求时即锁定本次 underlying 数量
- 实际转账在执行时完成
- `requestRedeem` 仅允许自我赎回：`controller == msg.sender && owner == msg.sender`，否则 revert `NotSelfRedemption()`。禁止第三方代排队的理由：`MAX_REDEEM_REQUESTS` 按 owner 计数，若允许任意 `msg.sender` 向任意 owner 排队，攻击者可用 5 wei dust 填满受害者的 5 个队列槽位，使受害者自己的赎回请求 revert `MaxRedeemRequestsReached()`；而 `redeem` / `withdraw` claim 时只消费成熟条目（`block.timestamp >= requestTime + REDEEM_DELAY`），该锁定持续 `REDEEM_DELAY` 并可每日重填，构成低成本可持续的退出封锁

这个模型的目的，是降低 flash 攻击和瞬时套利对 vault 的影响。

### 6.1 ERC-4626 接口面对齐

为支持外部聚合器报价与按份额存款，`MemecoinYieldVault.sol` 已新增 9 个公共函数（已落地），签名逐字节匹配 EIP-4626；但合约**不**继承 `IERC4626`、**不**补 `supportsInterface`（即不声称经 ERC-165 实现 ERC-4626 接口）。

只读视图（view）：

- `convertToShares(uint256 assets) → shares`：复用现有内部换算（向下取整 floor + `virtualAssets` 缓冲，见 §4.1），基线与 `MemecoinYieldVault.sol::previewDeposit`（`MemecoinYieldVault.sol::_convertToShares`）一致。
- `convertToAssets(uint256 shares) → assets`：直接复用内部换算 `MemecoinYieldVault.sol::_convertToAssets`（floor + `virtualAssets` 缓冲，见 §4.1）。claim 模型下 `previewRedeem` 自身 revert（见 §6.2 偏离 #2），故 `convertToAssets` 不再以 `previewRedeem` 为基线。
- `maxDeposit(address) → type(uint256).max`：无存款上限。
- `maxMint(address) → type(uint256).max`。
- `maxWithdraw(address owner)`：求和 `owner` 名下已成熟（`block.timestamp >= requestTime + REDEEM_DELAY`）队列条目的 `lockedAssets`（锚 `MemecoinYieldVault.sol::maxWithdraw`）。该 view 返回**总额**，因 `withdraw` 按逐条目 `floor(lockedAssets/shares)` 粒度以 exact-or-revert 结算（锚 `MemecoinYieldVault.sol::withdraw`），并非所有 `0 < assets <= maxWithdraw` 都能在单次 `withdraw` 中精确凑出，不可达时 revert `InsufficientClaimableRedeem`；全量 `withdraw(maxWithdraw(owner))` 恒精确，零散部分建议用 `redeem(shares)` 按份额提或先经 `MemecoinYieldVault.sol::isWithdrawReachable` 预检。
- `maxRedeem(address owner)`：返回 `_claimableShares(owner)`（已成熟条目 shares 之和；锚 `MemecoinYieldVault.sol::maxRedeem`）。
- `previewMint(uint256 shares) → assets`：**向上取整**（`Math.mulDiv` Ceil），满足 EIP-4626「no fewer than」约束（铸出指定份额所需资产不少于返回值）。
- `previewWithdraw(uint256 assets) → shares`：**永久 revert**（`PreviewWithdrawNotSupported`）。claim 模型按 per-request 锁定率结算，无法由单一 assets 参数预览（见 §6.2 偏离 #2）。

写操作：

- `mint(uint256 shares, address receiver) → assets`：复用 `MemecoinYieldVault.sol::_deposit`，assets 向上取整（与 `previewMint` 同基线），在同调用内写 `totalAssets` checkpoint（见 [docs/spec/invariants.md INV-26](../invariants.md)），emit 现有 `Deposit` 事件（签名已与 ERC-4626 标准 `Deposit` 逐字节一致，见 [docs/spec/events.md §2.5](../events.md)）。`mint` 与 `deposit` 同为 permissionless 入口（见 [docs/spec/access-control.md §3](../access-control.md)）：从 `msg.sender` 拉取 asset、把份额铸给任意 `receiver`，票权归属与 `deposit` 一致（见 §2.2）。

### 6.2 类 ERC-7540 claim 模式与 ERC-4626 语义偏离声明

> 本节描述 redeem 侧 claim 模式。claim-mode 机制已全量落地（代码已实现）：`requestRedeem` 烧份额 + 锁定 underlying + 入队并 emit `RedeemRequest`；`redeem` / `withdraw` 作为 claim 入口从成熟队列按队列扫描序转出锁定的 assets 并 emit `Withdraw`（完全消耗非尾部条目时队列以 swap-pop 压缩，部分领取后剩余条目不保证严格时间序；每条目按自身请求时锁定率结算、逐条守恒）。`requestRedeem` 返回 `lockedAssets`；`pendingRedeemRequest` / `claimableRedeemRequest` 为单参 `(controller)`；`RedeemRequest` 含未索引 `lockedAssets` 字段（emit 见 `MemecoinYieldVault.sol::requestRedeem`）。下方 `requestRedeem` 入队语义、§6 延迟队列、`REDEEM_DELAY` 防闪电贷说明、自我赎回防 griefing 说明同 §6。

#### 总述

vault 采用**类 ERC-7540 的异步 claim 模式**（非逐字实现 EIP-7540）：

1. `requestRedeem`（request）：烧份额 + 锁定本次 underlying assets + 入队（沿用 §6 延迟队列与 `MemecoinYieldVault.sol::MAX_REDEEM_REQUESTS` / 单笔 `uint192` 上限）。（EIP-7540 允许 `requestRedeem` 时立即烧份额或锁存；本 vault 选立即烧，故 share `totalSupply` 在 request 时即降、票权立即移除——这也是偏离 #1 claim 自赎回的前提，本身不构成对 EIP-7540 的偏离。） 票权语义同 §6：`REDEEM_DELAY` 窗口内 `getVotes`/`getPastVotes` 为零且不回补，等价提前一天退出治理。
2. 等待 `MemecoinYieldVault.sol::REDEEM_DELAY`（`1 days`）成熟。
3. `redeem` / `withdraw`（claim）：从成熟队列把 request 时锁定的 assets 转给 receiver。

`deposit` / `mint` 保持**同步**（类 ERC-4626，即时铸造，见 §6.1）。`REDEEM_DELAY` 是防闪电贷存取套利的第二道防线（`virtualAssets` 缓冲是第一道，见 §4.2），与 §6 自我赎回防 griefing 说明一并保留。

#### 偏离声明

本 vault **不声称完整 ERC-4626 / ERC-7540 合规**。与标准的有意偏离逐条说明如下：

1. **claim 自赎回**：`redeem` / `withdraw` 强制 `owner == msg.sender`（`receiver` 可任意），**不支持 owner ≠ caller**。理由：份额在 `requestRedeem` 时已烧，claim 时无 allowance 可查；引入 allowance / operator 路径即构成 theft 面。偏离 ERC-4626 owner ≠ caller 条款与 EIP-7540 operator 模型。
2. **`previewRedeem` / `previewWithdraw` revert**：claim 按 per-request 锁定率结算，无法由单一 shares / assets 参数预览。此 revert 是对 EIP-4626「preview 函数 MUST 返回」要求的有意偏离（理由：per-request 锁定率无法由单一参数预览；若强行返回估值会误导集成方）。`previewDeposit` / `previewMint` 保留（deposit 同步可预览，见 §6.1）。§6.1 已据此把 `previewWithdraw` 标为永久 revert、`convertToAssets` 改为直接复用 `MemecoinYieldVault.sol::_convertToAssets`（不再以 `previewRedeem` 为基线）。
3. **不加 `supportsInterface` / 不声称 IERC-7540 合规**：因实现不完整（无 operator、claim 自赎回、preview 部分保留）。
4. **vault 形态说明（同步 deposit + 异步 redeem claim）**：`deposit` / `mint` 即时（类 ERC-4626），`redeem` / `withdraw` 是 claim（类 ERC-7540 async-redeem 形态）。这是 vault 的混合形态说明，并非对 EIP-7540 的偏离（EIP-7540 允许 async-redeem-only）；本 vault 不声称 IERC-7540 合规的真正原因是偏离 #1 / #2 / #3（claim 自赎回、preview revert、不声明 `supportsInterface`），而非此处形态本身。
5. **不引入 requestId 概念**：本 vault 采用单一时间延迟模型（统一 `MemecoinYieldVault.sol::REDEEM_DELAY`），无批次 / epoch 区分，故**不使用 requestId 概念**。`requestRedeem` 按当前汇率算出并锁定本次 underlying（已落地，`MemecoinYieldVault.sol::_convertToAssets` + `_requestWithdraw`），把该锁定的 `lockedAssets` 返回给调用方（前端可直接据此显示锁定值）。`pendingRedeemRequest` / `claimableRedeemRequest` 为单参 `(controller)`（按账户聚合查询）；**但不**经 `supportsInterface` 声称实现 IERC-7540（见偏离 #3）——这些 view 仅为 claim 流程的可观测性而设，集成方按账户（controller）查询 pending / claimable，不构成接口合规声明。
6. **claim 语义**：`redeem` / `withdraw` 从成熟队列（`requestTime + REDEEM_DELAY <= block.timestamp`）按队列扫描序转出 request 时锁定的 assets（swap-pop 压缩使部分领取后剩余条目顺序不保证 FIFO）；未成熟或 claimable 不足则 revert（对应 ERC-4626「MUST revert if cannot be withdrawn」）。实际赎回另受 `MemecoinYieldVault.sol::MAX_REDEEM_REQUESTS`（每账户队列 5 笔上限）与单笔 `uint192` 上限约束，故 §6.1 的 `maxRedeem` / `maxWithdraw` 返回精确可 claim 总额（已成熟 shares / 已成熟 lockedAssets 求和），而非 `balanceOf` 推导；集成方据此可知成熟可 claim 量。
7. **零额 `deposit`/`mint` 不 emit `Deposit`**：`deposit(0)` / `mint(0)` 静默 `return 0`，不进入 `MemecoinYieldVault.sol::_deposit`，不触发 `emit Deposit`，不对 `MemecoinYieldVault.sol::totalAssets` 及 `OutrunVotesInit.sol::_totalAssetsCheckpoint` 产生写入。构成对 EIP-4626 `deposit` / `mint` “MUST emit Deposit” 的窄偏离；`previewDeposit(0) == 0 == deposit(0)` / `previewMint(0) == 0 == mint(0)` round-trip 保持，协议账务一致性不受影响（零额无状态变化），索引器若以 `Deposit` 事件为唯一数据源则零额不可见。与 Solmate 零额 revert（`ZeroShares`）、OZ 零额 0/0 事件并列为三选一显式取舍，本 vault 取静默返回以避免冗余 `safeTransferFrom`/`_mint`/checkpoint 写入（锚 `MemecoinYieldVault.sol::deposit` / `MemecoinYieldVault.sol::mint` / `MemecoinYieldVault.sol::_deposit`，行为自 `MemecoinYieldVault.sol::deposit` 注释钉定）。

综上，本 vault 提供 deposit 侧（同步，类 ERC-4626）+ redeem 侧（异步 claim，类 ERC-7540）的混合模型；redeem 侧不提供标准 ERC-4626 即时赎回语义，而是 request → 延迟 → claim 的异步流。

## 7. Governor Treasury 语义

`registerTreasuryToken` 必须在不可嵌套的 Governor `_executeOperations` 中作为唯一 operation 执行（`registration-only`，即只完成 token 注册/确认）；同一次 execution 不得再包含该 token 的支出、direct ERC20 target 或其他 operation。Incentivizer 完成注册后会回调 Governor 的 registration confirmation；该回调要求 execution 正在进行且 operation count 为 1，所以注册必须是 standalone operation。

受支持的 treasury spend path 只有 `Governor.sendTreasuryAssets(token, to, amount)`：该路径先调用 `Incentivizer.recordTreasuryAssetSpend` 更新 treasury ledger，再从 Governor 真实转账。该路径同时受到 Governor 的 execution-time balance-ratio 检查。

将 ERC20 合约直接作为 generic Governor execution target 的 direct ERC20 path 不属于受支持的 treasury spend path。若当前 generic execution 仍允许该 target，它不调用 `Incentivizer.recordTreasuryAssetSpend`，也不更新 Incentivizer ledger；只有 token 已注册且 execution 前 `Governor` 余额为正时，才进入现有 ratio loop。未注册 token 和 execution 前零余额按当前实现不进入 ratio/ledger 保护，治理不得将 direct target 当作 treasury spend 保护。注册 token 的 `approve` 操作另受 §7.2 allowance 面守卫约束。

原生 ETH 同属未覆盖资产类：governor 继承的 payable `receive()` 允许任意地址捐入 ETH，generic execution 提案可携带 ETH `values[]` 转出；原生 ETH 无法注册为 treasury token，因此不在 §7.2 的 registered-token 快照环与 incentivizer ledger 覆盖内。治理审计应把携带 ETH value 的提案与 governor 原生 ETH 余额视同 direct-path 未覆盖类处理。

**治理把 vote-token yield vault 作为 generic execution target 的自利/固权面。** 提案可以把 `MemecoinYieldVault.sol` 直接作为 generic Governor execution target；该 target 不是 Governor self-call，因此不触发 supermajority，简单多数即可通过并执行 `MemecoinYieldVault.sol::deposit`。执行时 Governor 是 `msg.sender`，vault 从 Governor treasury 拉走 memecoin——该拉取依赖 Governor 对 vault 的 memecoin 授权（governor 无自有 approve 入口，须由同提案或先前提案以 memecoin 为 generic target 执行 `approve(vault, …)` 建立；该 approve 的 spender 即 vault，受 §7.2 allowance 面守卫放行，paired 拉款发生在同一次 execution 内、受余额环约束；memecoin 已注册时，任意非 vault spender 的 approve 会因 §7.2 allowance 面守卫整次回滚，未注册时该守卫不适用，审计时仍应将 paired approve action 一并纳入）——并按现行汇率把份额铸造给 calldata 指定的任意 `receiver`：treasury memecoin 按 1:1 转为资产计价票权（`MemecoinYieldVault.sol::_convertVotes`；`mulDiv` 取整的亚 1 股 dust 使 receiver 实得票权略低于 1:1、新汇率微升，方向为既有持有人获益、不放大该路径，见 §4.3），构成治理自利/固权面；receiver 须按 §2.2 完成委托激活后票权才生效（未委托账户 `getPastVotes` 恒为零）。`deposit` 本身对汇率近似中性——按现行汇率铸造份额，fair-value；除 share-mint floor 取整 dust（见 §4.3）外汇率不因存款移动，"汇率抬升"主要来自后续 yield 累积（`MemecoinYieldVault.sol::_accumulateYield`），且由全体份额持有人按比例共享，不是该路径独有的放大。支出面约束上，memecoin 已注册为 treasury token 且 execution 前 Governor 余额为正时，该路径受 §7.2 单次执行 balance-ratio 约束（in-repo 部署脚本 `script/MemeverseScript.s.sol` 配置 `maxTreasurySpendRatio = 1000` bp，即 10%/次），可跨提案重复执行；与 direct ERC20 path 一致，该路径不调用 `Incentivizer.recordTreasuryAssetSpend`、不更新 incentivizer ledger。治理侧应把任何 target 为 vault `deposit` 的提案视为 treasury spend 进行审计。

### 7.1 提案人 outstanding 标记

`proposer outstanding`（提案人未完成提案标记）是 Governor 按 proposer 保存的最近 proposal id。`propose` 会读取这个已保存 proposal 的状态：当该状态既不是 `Defeated` 也不是 `Succeeded` 时，同一 proposer 再次 `propose` 会回滚；进入这两种状态之一后，才可创建新 proposal，并用新 id 覆盖标记。这个检查是正常路径的 guard，不构成每个 proposer 绝对只能有一个未完成 proposal 的 invariant。

`propose` 成功后写入新 id；`execute` 和 `_cancel` 仅在当前 marker 仍等于正在处理的 proposalId 时清零；若 marker 已更新为较新的 proposalId，则保留该较新 marker。`Defeated` 和 `Succeeded` 仍会放行新 proposal。

### 7.2 Treasury spend cap 与执行快照

`maxTreasurySpendRatio` 是 `treasury spend cap`（国库支出上限），单位为 basis points（基点），分母固定为 `10000`；例如 `500` 表示 `5%`。它只约束一次 Governor execution 中已注册 treasury token 的实际余额减少。

Governor 在 `_executeOperations` 开始执行 proposal actions 前，从 Incentivizer 读取执行开始时的 registered treasury token list，并为列表中的每个 token 快照 `pre = IERC20(token).balanceOf(Governor)`。所有 operation 执行完成后，按同一列表逐 token 检查：

- `pre == 0` 时跳过该 token；
- `post >= pre` 时没有支出，跳过该 token；
- 仅当 `post < pre` 时，计算 `spent = pre - post`；
- 计算 `limit = pre * maxTreasurySpendRatio / 10000`，并要求 `spent <= limit`，否则整次 execution 回滚。

该循环使用执行开始时取得的已注册列表；registration-only operation 新注册的 token 不会加入本次执行已经建立的余额快照。余额 delta 检查也不替代 `sendTreasuryAssets` 的 ledger hook。

allowance 面守卫：generic execution 中 target 为已注册 treasury token、calldata 以 `approve(address,uint256)` selector 开头且长度不少于 68 字节的 operation，仅当 `spender` 为 vote token（yield vault，即 §7 vault 存款路径的授权对象）时放行；其余 spender 使整次 execution 以 `UnauthorizedTreasuryAllowance(token, spender)` 回滚。该守卫与余额 delta 检查同域：`approve` 不移动余额、余额环不可见，但对任意 spender 的授权等价于日后 execution 之外经 `transferFrom` 全额提走的支出准备，故纳入同一次执行的校验面。更短的 selector 匹配 calldata 不进入该守卫，由 token 自身解码回滚。间接路径无法绕过：ERC20 `approve` 以调用者自身为授权人，governor 经中间合约转发的 `approve` 只能为中间合约建立 allowance，`allowance(governor, …)` 只能由 target 为 token 的直接调用建立。该守卫假定注册 token 除标准 `approve` 外无其他**免认证的** allowance 写入口（如 `increaseAllowance`）：签名门控入口（`permit`）不构成绕过——governor 是合约、无私钥且不支持 ERC-1271 签名校验，无法为 `permit(governor, …)` 提供有效签名；存在免认证 allowance 写入口的 token 不应注册为 treasury token。

### 7.3 Self-call 与激励器 target 的 supermajority

`supermajority`（超级多数）指赞成票占全部计入该 proposal 的赞成、反对和弃权票的最低比例。只要 proposal 的 targets 中有任一项是 Governor 自身的 self-call（`targets[i] == address(this)`）**或**激励器地址（`targets[i] == address(激励器)`），就适用 `upgradeSupermajorityRatio`，不只适用于升级操作。激励器是 governor 持有的特权合约，其攻陷可经 `MemecoinDaoGovernorUpgradeable.sol::disburseReward` 移动 treasury 资产；若激励器升级仅需简单多数，简单多数联盟可换上恶意实现并经 `disburseReward` 旁路 §7.2 cap 与本节超多数，故激励器升级须与 governor 自身升级同等门槛。实现见 `MemecoinDaoGovernorUpgradeable.sol::_executeOperations`（self-call + 激励器 target 检测循环）。

其判定为：

```text
forVotes / (forVotes + againstVotes + abstainVotes)
    >= upgradeSupermajorityRatio / 10000
```

其中分母包含 `forVotes`、`againstVotes` 和 `abstainVotes`，不是只取赞成票与反对票，也不是 quorum 或总供应量。实现使用等价的整数比较 `forVotes * 10000 >= totalVotes * upgradeSupermajorityRatio`。

### 7.4 Quorum 下限（minQuorumNumerator）

`minQuorumNumerator` 是 `MemeverseProxyDeployer` 上的部署期治理参数，百分比（分母 `100`）。

部署时 `MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer` 计算 `_minQuorum = memecoin.totalSupply() * minQuorumNumerator / 100`，作为绝对 quorum 下限传入 `IMemecoinDaoGovernor.initialize`。governor 的 `MemecoinDaoGovernorUpgradeable.sol::quorum` 取 `Math.max(super.quorum(timepoint), _minQuorum)`：OZ 动态 quorum 不得低于该绝对下限。

与 OZ `quorumNumerator`（`MemeverseProxyDeployer.quorumNumerator`，同样经 `IMemecoinDaoGovernor.initialize` 传入 governor）的语义区分——两者分母同为 `100`（OZ `GovernorVotesQuorumFraction.quorumDenominator()` 默认值，本 governor 未 override），区别在基数与结果语义：
- `minQuorumNumerator`：基数 = 部署时 `memecoin.totalSupply()`（当前供给，冻结为 `_minQuorum`，governor init 后无 setter），算的是**绝对票数下限**，经 `Math.max` 兜底。
- `quorumNumerator`：基数 = `getPastTotalSupply(timepoint)`（该 timestamp-clock timepoint 的历史供给，按 timepoint 动态重算），算的是**比例型动态 quorum**（即 `super.quorum(timepoint)`）。
- 两者都仅影响新部署 governor 的初始化值，不回溯既有实例；`MemeverseProxyDeployer` 的 `setMinQuorumNumerator` / `setQuorumNumerator`（均 onlyOwner；`setMinQuorumNumerator` 要求 `>0 且 <=100`，见 `InvalidMinQuorumNumerator`，`setQuorumNumerator` 仅非零校验）只改后续部署值。

### 7.5 治理启动延迟（bootstrapPeriod）

`bootstrapPeriod` 是 `MemeverseProxyDeployer` 上的部署期治理参数，单位为秒。

部署时传入 `IMemecoinDaoGovernor.initialize`，governor 存 `_governanceStartTime = block.timestamp + bootstrapPeriod`（`MemecoinDaoGovernorUpgradeable.sol::initialize`）。该时间戳之前提交 proposal 被拒绝（`GovernanceNotStarted`），用于部署后留出缓冲再开放治理。`setBootstrapPeriod`（onlyOwner、非零校验）只改后续部署值，不回溯既有实例。

> 注意：本参数与"池引导流动性 bootstrap"（四池 bootstrap / `deployBootstrapLiquidity`，见 [docs/spec/verse/deployment.md](../verse/deployment.md)）是完全不同的概念，仅词形相同。

### 7.6 治理启动前置条件

治理参数刻意保留完整 memecoin 供给作为安全分母，不应改为按 vault 当前供给比例缩放。vault 只决定哪些质押资产产生投票权，因此启动时可能出现“投票权不足、治理尚未可用”的阶段。

设 `M = memecoin.totalSupply()`，`T = M / 50`，`Q = M * minQuorumNumerator / 100`。在治理准备度检查中，至少需要同时确认：

- **提案创建前的 proposer timepoint**：先取 `PROPOSER_TIMEPOINT = governor.clock() - 1`。这对应 `GovernorUpgradeable.sol::propose` 内部对 `getVotes(proposer, clock() - 1)` 的门槛检查，因此应确认存在账户 `account`，使 `yieldVault.getPastVotes(account, PROPOSER_TIMEPOINT) >= T`。该检查不得使用投票 snapshot。
- **提案已创建且 snapshot 已成为 past timepoint 后的投票 snapshot**：读取 `PROPOSAL_SNAPSHOT = governor.proposalSnapshot(proposalId)`，并仅在 `PROPOSAL_SNAPSHOT < governor.clock()` 时查询 `yieldVault.getPastTotalSupply(PROPOSAL_SNAPSHOT) >= Q` 与 `governor.quorum(PROPOSAL_SNAPSHOT)`；否则未来 timepoint 查询会被拒绝。该 snapshot 只用于 quorum/历史总票基数，不替代 proposer timepoint 的门槛检查。
- 两类 timepoint 都使用 yieldVault 的 ERC-6372 timestamp 时钟，不得用 block number 代替。

`quorum` 参数命名为 `timepoint`（与 OZ 5.6.1 上游一致），与 Governor 由 yieldVault 委托的 timestamp 时钟匹配；在本系统中该参数表示 timestamp timepoint。

`totalAssets + virtualAssets` 只是资产计价总票权的上界，不代表已有委托票权。当前 `MemeverseLaunchImpl.sol::_deployGovernanceComponents` 不向 vault 注入 bootstrap 资产，`MemecoinYieldVault.sol::_accumulateYield` 在空仓时会销毁收益；因此上述条件是部署后的治理启动前置条件，而不是自动激活逻辑。运维方应先通过 `MemeverseOmnichainInteroperation.sol::memecoinStaking` 或 vault `deposit` 完成质押，并调用 `OutrunVotesInit.sol::delegate`（通常 `delegate(self)`）完成委托激活，再创建 proposal（票权激活前提与归属语义见 §2.2）。

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
- treasury ledger 的初始入账口径：`GovernanceCycleIncentivizerUpgradeable.sol::_registerTreasuryToken` 在注册时点以 `max(G − R, 0)` 入账（`G` = `Governor` 托管余额 `balanceOf(governor)`，`R` = 上一周期未领 reward 储备 `_cycles[_currentCycleId - 1].rewardBalances[token]`），与 `GovernanceCycleIncentivizerUpgradeable.sol::syncTreasuryBalance` 同一公式，任意写入点（注册与 sync）在 `G ≥ R` 时账本守恒 `G = T + R` 成立；`R ≥ G` 时见下条边界；`GovernanceCycleIncentivizerUpgradeable.sol::registerTreasuryToken` 与初始化部署路径均如此——初始化时 `Governor` 零余额，初始入账 0——该零余额为部署流事实（而非代码强制），由 `MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer` 的单事务原子性保证：governor 初始化与 incentivizer 初始化之间不得注入任何 token 转账；未来若变更部署时序（如先注资后初始化），失效的是「初始化时初始入账 0」及相应注册时点守恒表述（`CycleStarted` 事件 `balances` 数组取 `_registerTreasuryToken` 写入 storage 的初始入账种子、与初始入账值同源），需同步修订

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

treasury ledger 的账本守恒为 `G = T + R`：`G` = `Governor` 对该 token 的实时 ERC20 托管余额，`T` = 当前周期 treasury ledger，`R` = 上一周期未领 reward 储备（`_cycles[_currentCycleId - 1].rewardBalances[token]`）。`GovernanceCycleIncentivizerUpgradeable.sol::syncTreasuryBalance(token)` 是该守恒的 permissionless 整额对账入口：

- 任意调用者可调（permissionless）；不接受金额参数，函数自读真值（governor 实际托管余额与上一周期未领 reward 储备确定性导出，调用者无法控制结果），消除了治理手动补记（`recordTreasuryIncome`）传错金额的错误面
- token 须已注册为 treasury token，未注册 revert `NonTreasuryToken`（与 `recordTreasuryIncome` 同）
- 语义：把 `T` 重设为 `max(G − R, 0)`（饱和到 0，`R` 超过 `G` 时置 0）
- 对 drift 的治愈效果按边界限定：under-count（直接捐赠给 governor 的未记账余额经一次 syncTreasuryBalance 或治理 recordTreasuryIncome 入账）恒可治愈；over-count 仅在 `G ≥ R` 时治愈（sync 把账本拉回真实）；`R ≥ G` 时 `T` 置 0，账本仍超记 `R − G`（reward 储备超出 `Governor` 托管，需补充托管（直接向 `Governor` 注入资产后经 `syncTreasuryBalance` 入账）治愈；调整 reward ratio 不改变 `R − G` 缺口，sync 不能治愈托管缺口）

手动用 `recordTreasuryIncome` 补记参数易错且错误后果 sticky（账本无独立扣减路径），`syncTreasuryBalance` 是替代方案。

## 8. Incentivizer 周期语义

Incentivizer 负责把 treasury ledger 的一部分，按周期转成 reward ledger，并按用户投票份额结算奖励。

关键要点：

- 周期长度固定
- `rewardRatio`（奖励比例）是以 basis points 表示的 treasury-to-reward 划拨比例；`finalizeCurrentCycle()` 按 `rewardAmount = treasuryBalance * rewardRatio / 10000` 把满足全部以下条件的 treasury ledger 余额划入 reward ledger：该 token 已注册为 reward token（`GovernanceCycleIncentivizerUpgradeable.sol::registerRewardToken`）、当期 `treasuryBalance > 0`、当期 `totalVotes > 0`；三个条件缺一即不划拨
- 初始 `rewardRatio = 2500`（25%）：由 `GovernanceCycleIncentivizerUpgradeable.sol::__GovernanceCycleIncentivizer_init` 硬编码写入，deployer 不可传参；修改仅可经 `GovernanceCycleIncentivizerUpgradeable.sol::updateRewardRatio`（`onlyGovernance`，即需治理提案；上界 `BPS_BASE = 10000`）
- 无票周期（`totalVotes == 0`）不划拨任何奖励，当期 treasury ledger 余额全额 rollover 至下一周期 treasury ledger（下一周期仍可参与划拨）
- `rewardRatio` 在 `finalizeCurrentCycle()` 调用时刻取当前存储最新值，不是周期开始时的快照（周期结构不保存 per-cycle ratio）
- 用户最终按“上一周期 userVotes / totalVotes”获取奖励
- 票权归属：Governor 投票后经 `MemecoinDaoGovernorUpgradeable.sol::_castVote` 回调 `GovernanceCycleIncentivizerUpgradeable.sol::accumCycleVotes`，票权记入 cast 时刻的当前周期（`_currentCycleId`），与提案快照所在周期解耦；跨周期边界：当投票窗口（`votingDelay + votingPeriod`，生产配置 1 天 + 1 周）跨过周期边界且 `finalizeCurrentCycle()` 已推进周期时，同一提案的票会被拆分到两个周期，分别参与各自周期的 userVotes / totalVotes 奖励分配；边界未推进：`finalizeCurrentCycle()` 未被调用时周期不推进，超时后 cast 的票仍记入原周期
- 累计口径：`GovernanceCycleIncentivizerUpgradeable.sol::accumCycleVotes` 按每笔成功 `castVote` 的增量权重累计（含最终为 `Defeated`/`Canceled` 的提案），不做跨提案去重；周期奖励份额因此按投票量（次数×权重）分配，同一提案内多次分步投票受 `GovernorCountingFractionalUpgradeable.sol::_countVote` 的 `remainingWeight` 限额约束不超快照权；`sum(userVotes)==totalVotes` 保证 `mulDiv` 守恒
- `finalizeCurrentCycle()` 的核心语义是账本切换与结算，不要求把 token 从 `Governor` 转入 `Incentivizer`
- 上一周期未领完的 `rewardBalances` 会在后续 `finalizeCurrentCycle()` 时回卷到 treasury ledger

因此 reward 分发依赖的不是实时余额，而是周期化结算。

用户奖励领取入口采用以下固定语义：

- 用户通过 `Incentivizer.claimReward()` 领取奖励
- 只支持 `msg.sender` 领取给自己，不支持指定 `receiver`，不支持代领
- `Incentivizer.claimReward()` 在同一事务中：
  1. 以 `msg.sender` 作为 reward owner 计算上一周期可领奖励
  2. 扣减上一周期对应的 `rewardBalances`
  3. 调用 `Governor.disburseReward(token, msg.sender, amount)` 完成真实付款
- `Governor.disburseReward(...)` 的调用方权限（仅配对 `Incentivizer`、非通用 treasury 支出）见 [docs/spec/access-control.md](../access-control.md) §4
- 若 `Governor.disburseReward(...)` 失败，则整笔 claim 回滚，账本扣减也回滚

### 8.1 claim 窗口与 forfeit 语义

`GovernanceCycleIncentivizerUpgradeable.sol::claimReward` 只领取**紧邻上一周期**（`_currentCycleId - 1`）的奖励，且不接受 cycleId 参数，故无法补领更早周期。由此推出固定的 claim 窗口：

- **窗口范围**：用户在周期 K 投票（经 `MemecoinDaoGovernorUpgradeable.sol::_castVote` 回调 `GovernanceCycleIncentivizerUpgradeable.sol::accumCycleVotes` 记入周期 K）产生的奖励，只能在 `currentCycleId == K + 1` 期间领取（即 K 成为紧邻上一周期时）；窗口关闭时机是下一次 `GovernanceCycleIncentivizerUpgradeable.sol::finalizeCurrentCycle` 把 `currentCycleId` 推进到 `K + 2` 的那一刻。
- **错过即 forfeit**：一旦 `currentCycleId` 推进到 `K + 2` 及以后，周期 K 的 reward 份额按本节已记载的回卷机制并入后续周期 treasury ledger，不再归属原投票者，且无任何补领入口；周期 K 的 reward 不再被任何 view 或 claim 入口读取/领取（二者恒读 `currentCycleId - 1`，即 K+1 及以后，不再触及 K）。
- **permissionless 关窗**：`finalizeCurrentCycle` 无访问控制（见 [docs/spec/access-control.md](../access-control.md) §4），任何人都可在 `block.timestamp >= currentCycle.endTime` 后调用以推进周期，从而关闭当前领取窗口；窗口至少持续一个 `CYCLE_DURATION`（下一周期的 `endTime` 在本次 finalize 时设为 `block.timestamp + CYCLE_DURATION`，且 finalize 要求到点才能推进），无强制上限（无人调用 finalize 则窗口一直开着），但因 permissionless，第三方可在周期 `endTime` 一到就立即调用 finalize 把窗口压到该下限。
- **历史 userVotes 残留（良性）**：错过窗口后，周期 K 的 `userVotes[user]` 不再被任何结算或 claim 路径读取或清零（`finalizeCurrentCycle` 不触碰 userVotes，`claimReward` 只清紧邻 prevCycle 的对应用户）。`GovernanceCycleIncentivizerUpgradeable.sol::getUserVotesCount` 作为只读历史 view 仍可读该周期的票数快照，但**仅作历史记录，不代表可领奖励**；这是良性的 storage 残留，无资金影响（份额已按上一条 forfeit 并入国库）。

## 9. 权限边界

Governance reward path 的权限边界（`MemecoinDaoGovernorUpgradeable.sol::sendTreasuryAssets` / `MemecoinDaoGovernorUpgradeable.sol::disburseReward`、`GovernanceCycleIncentivizerUpgradeable.sol::recordTreasuryIncome` / `GovernanceCycleIncentivizerUpgradeable.sol::recordTreasuryAssetSpend` / `GovernanceCycleIncentivizerUpgradeable.sol::syncTreasuryBalance` / `GovernanceCycleIncentivizerUpgradeable.sol::claimReward` / `GovernanceCycleIncentivizerUpgradeable.sol::finalizeCurrentCycle` 的调用方与 reward owner 语义）以 [docs/spec/access-control.md](../access-control.md) §4 为 canonical。

阅读建议：对开放入口要关注其调用前提，而不是只看是否 `onlyGovernance`；`claimReward()` 必须始终把终端用户 `msg.sender` 视为 reward owner。

## 10. 当前实现提醒

Governor 托管资产、Incentivizer 维护账本的 custody/ledger 分层是本文件的固定边界，定义见 §7。reward 不是在 fee 到达时立即逐用户发放，而是先进入 treasury ledger，再在 finalize 后转成 reward ledger，最后由用户 claim（周期语义见 §6、§8）。若后续引入更多治理金融化能力，必须继续尊重该边界。

### 10.1 治理执行无 Timelock 的风险接受 `[代码已证]`

当前 `MemecoinDaoGovernorUpgradeable` 未混入任何 `GovernorTimelock*` 扩展（继承面中的 Governor 扩展仅 `GovernorSettings/CountingFractional/Storage/Votes/VotesQuorumFraction`，`MemecoinDaoGovernorUpgradeable.sol`），`GovernorUpgradeable.sol::proposalNeedsQueuing` 恒 `false`，`GovernorUpgradeable.sol::queue` 未实现（`GovernorQueueNotImplemented`），`MemecoinDaoGovernorUpgradeable.sol::execute` 直接 `super.execute` → `MemecoinDaoGovernorUpgradeable.sol::_executeOperations` 同步 `call` 执行 `[代码已证]`。语义为 `votingDelay(1 days)+votingPeriod(1 weeks)`（`MemeverseProxyDeployer.sol::deployGovernorAndIncentivizer`）结束后提案处于 `Succeeded` 即被任何地址 `execute`，无 `Queued` 队列期与 timelock 延迟，投票期结束即终局，持币人没有"通过后、执行前"的额外退出窗口（docs/operations.md §3.9 同步记载"当前 Governor 没有 Timelock extension，OZ base `queue` 没有实现"）`[代码已证]`。

- **升级面已加固**：`MemecoinDaoGovernorUpgradeable.sol::_authorizeUpgrade` 仅 `onlyGovernance`；任意 `target == address(this)` 或 `target == incentivizer` 的提案需满足 `upgradeSupermajorityRatio` 超多数（`MemecoinDaoGovernorUpgradeable.sol::_executeOperations`），incentivizer 纳入判定理由为被换实现可经 `GovernanceCycleIncentivizerUpgradeable.sol::claimReward` → `MemecoinDaoGovernorUpgradeable.sol::disburseReward`（`incentivizer-only`）绕过单次 `maxTreasurySpendRatio` 限额 `[代码已证]`。
- **剩余即时执行面**：除上述升级路径外，治理可经提案执行任意第三方 `targets/calldatas`（`relay`/外部合约调用）——此即预期治理能力，非旁路；单次注册 `ERC20` 类 treasury 支出仍受 `_executeOperations` 内 `preBalances → super._executeOperations →  spent = pre - post ≤ pre * maxTreasurySpendRatio / 10000` 约束（`MemecoinDaoGovernorUpgradeable.sol::_executeOperations`）；注册 `ERC20` 的 allowance 面另受 §7.2 allowance 面守卫约束（generic execution 中对注册 token 的 `approve` 仅放行 vote token 一个 spender）`[代码已证]`，但 `ETH` 与未注册 `ERC20` 不在覆盖内`[代码已证]`。
- **持币人退出**：无 timelock 场景下，退出须在 `votingPeriod` 内完成。对 `MemecoinYieldVault` 持仓者，requestRedeem 的票权影响见 §6；治理排期应避免在巨鲸赎回窗口内取快照。

本节为模板级设计决策的风险接受，非代码缺陷，当前不要求合约改动，记录于此以避免后续审计重复提出。后续若在 memecoin 治理模板中提供可选 `GovernorTimelockControlUpgradeable` 混入，应经 `MemeverseProxyDeployer` bootstrap 参数化（`TimelockController` 地址 + `minDelay`），并评估：资产托管将从 `Governor` 迁至 `Timelock`（`GovernorTimelockControl` 要求 `timelock` 持有资产与权限），`_executor` 覆盖、`proposalNeedsQueuing = true`、`state/queue/execute/cancel` 时序、`_timelockIds` 存储与 `ERC7201` 布局、以及部署时序原子性（`Create2` 同盐 `governor/incentivizer` 初始化序）均需同步更新，属于未来可选架构分支而非本次变更。

## 11. 相关真源与证据

- [docs/spec/verse/accounting.md](../verse/accounting.md)
- [docs/spec/access-control.md](../access-control.md)
- [docs/spec/verse/deployment.md](../verse/deployment.md)
- [docs/implementation-map.md](../../implementation-map.md)
- [docs/TRACEABILITY.md](../../TRACEABILITY.md)
