# Feature-pipeline 复杂度分级 + 降档执行细则

> 来源：
> - I-1 黑名单 trial #2 复盘——CRUD 极简页跑了 ~5h / 6 次询问 / 700 行 spec / 27 条红队，全程过度工程
> - **2026-07-17 直播间任务面板 LiveGiftTask 复盘**——3 接口(全 fetch) + IM 单向触发 refresh 硬性命中 A 档,但业务本质是"拉数据展示",走完整 A 档(600 行 spec / 15 条红队 / 5-agent 精读 workflow)明显过度。用户明示"这么简单的功能不要搞 spec 这么久这么复杂"

## 规则

**调 feature-pipeline 前先判档**，不是所有"跨 3+ 文件 + 含状态机 + 含 UI"都走全套 7 步。

| 档 | 判定阈值（spec 起草前可判断的硬指标） | 例子 |
|---|---|---|
| **A** | 接口 ≥3 或 状态机 >5 态 或 跨 ≥1 SDK 或 含异步竞态/跨模块状态同步 | 直播 / PK / 派对房 / 1v1 通话 / 美颜管线 |
| **B** | 接口 ≤2 且 状态机 ≤5 态 且 0 SDK 且 单一 view 入口 | 黑名单 / 反馈列表 / 收益明细 / 消息列表 |
| **C** | 单文件改动 / cosmetic / bug 修复 | 不走流水线 |

**不用**"反向用例数 R-*"作为阈值（要先写 spec 才能数，循环依赖）。

## ⚠️ 硬指标命中 A 但仍应走 B 档的降档信号(2026-07-17 加严)

硬阈值容易错判"复杂度"。以下 3 类"命中 A 硬指标但实际是简单展示"的场景**强制降档 B**:

### 信号 1:所有接口是 fetch-only,无写操作

若 ≥3 接口但**全部**是 `GET/POST 拉数据返 JSON`,**无** create/update/delete/claim/settlement/settle/publish/pay 类**写操作** → 走 B。

典型:榜单 sheet(拉 3 个 tab list)、任务面板(拉进度+历史+规则)、数据统计页(拉多个 metric)。

反例(不算降档):
- 有 claim 领奖接口 → 涉及后端幂等 + 前端合成 pending state → A
- 有 pay 支付接口 → 涉及 SDK + 回调 + 时序 → A

### 信号 2:IM/WS 事件是单向触发 store.refresh()

若 IM/WS 事件触发的是**单个 store 的单个方法**(通常是 refresh),不涉及跨 store 状态传播、无本地累加/优先级/竞态融合逻辑 → 不算"跨模块状态同步"。

典型:`if attachType == X { store.refresh() }` 一行代码,与 [`contributionStore.refresh()`](../../Sources/Live/BadgeRow/LiveContributionStore.swift) 同排注入。

反例(不算降档):
- IM 到达要按 payload 更新 3 个 store + 触发跨 view 动画 + 埋点上报 → A
- IM 要合并 initTaskList/liveTaskList 双源 + hook 优先级排序 → A

### 信号 3:状态机 >5 态但全是 `loading/loaded/refreshing/error/errorWithPrevious` 变体

状态机数量看着大但都是 [list-refresh-preserve-items](list-refresh-preserve-items.md) rule 的标准 preserve-visual pattern 变体,**无业务分支**(如 pending/settling/refunding/expired 等业务态) → 走 B。

典型:分页无限滚动 store 的 6 态 = idle/loading/refreshing/loaded/loadingMore/finished/error,这就是**基建 pattern 不是业务复杂度**。

反例:PK / 通话 / 派对房状态机(inviting/matching/inPK/punishing/ending 等)是**真业务分支**,A。

### 降档判定检查

命中 A 硬指标时**强制**过一遍以下清单:
- [ ] 接口是否**全 fetch,无写操作**?(信号 1)
- [ ] IM 触发是否**单个 refresh,无跨 store 传播**?(信号 2)
- [ ] 状态机是否**只是 preserve-visual 变体,无业务分支**?(信号 3)

**≥2 条命中 → 强制走 B**,不允许"接口个数硬指标 override"。

### 具体到本项目已知场景

| 场景 | 硬指标 | 降档信号 | 判档 |
|---|---|---|---|
| 直播间任务面板 LiveGiftTask(2026-07-17 复盘) | 3 fetch + IM 触发 → A | 全 fetch ✅ + 单 refresh ✅ + 无业务分支 ✅ | **应 B**(实际走了 A,复盘教训) |
| Contribution sheet(v7) | 2 fetch + 1 tab → B | — | B ✅ |
| 数据统计页 DS | 多 metric fetch | 全 fetch + 无 IM + 无业务分支 | B ✅ |
| PK 全流程 | 多接口 + 多 SDK + 复杂状态机 | 无信号命中 | A ✅ |
| 派对房 E 期 | RTC SDK + 座位状态机 + 多向 IM | 无信号命中 | A ✅ |

## B 档降档执行细则

| 维度 | A 档（默认） | B 档 |
|---|---|---|
| **step 拆分** | 0/1a/1b/1c/2/3/4/5/6 共 9 步 | 0 / impl（合并 1a+1b+1c+2）/ 真集成+真机 / 5（轻量）/ 6（事件触发） |
| **询问** | step 0 多次 picker 中断 | 确认点用陈述+反驳指引（"我按 X 推进，如非此意请打断"），决策点才用 AskUserQuestion |
| **spec 篇幅** | 12 节 + 附录（700 行） | 5 节（150 行）：业务+契约 / model+状态机 / 验收(F 全列 + R critical 3-5 条) / 复用判断 / 待问用户(仅 critical) |
| **red team** | 全方位评审 27+ 条 | 提示词限定"只挖未覆盖 case，不报品味优化" |
| **TodoWrite** | 每 step 切换更新 | 禁用（单线程流程用 todo 仪式化） |
| **xcodebuild test** | 每验收门跑 | 无改动不跑 |
| **step 3 / 4** | 拆 2 步 | 合并为「真集成+真机签字」单步 |
| **step 6** | 强制做 | 反悔 0 → 跳过；反悔 ≥1 → 必做 |
| **sink rule** | step 6 仪式化沉淀 | 新 rule 与本次 checklist 重复 ≥50% → 不沉淀 |

### 维度匹配

- **治中断成本**：上表「询问」「TodoWrite」→ 6 次 picker → 1 次文档反馈
- **治总耗时**：上表「step 拆分」「spec 篇幅」「step 3+4 合并」「step 6 事件触发」
- **治评审噪声**：上表「red team」

### B 档自检清单

进流水线前：

- [ ] 是否符合 B 档阈值（接口 ≤2 + 状态机 ≤5 态 + 0 SDK + 单一入口）？
- [ ] 即将用 AskUserQuestion 的点，是真决策还是确认？确认 → 改陈述+反驳
- [ ] spec 草稿 >200 行？→ 砍元节（§0.3 信源限制 / §8 rules 候选 / §11 自检 / §12 红队详细落地都不应进 spec）
- [ ] red team ≥10 条？→ 重写提示词限定"挖未知 case"
- [ ] 当前 step 真有改动需测试？无 → 跳过 xcodebuild test

### spec §0.3 范围三圈"占位"栏必答

grep Sources/ 看依赖模块是否已就绪；已就绪 + 接入成本 <50 行 → **不应占位，直接做**
（trial #3 教训：CallStore 早就完整，接入 30 行 / 10 分钟，被误占位）。

### step 1c 验收门强制项

step 1b 留的所有 TODO 必须逐条核对（已消化 / 已延期带 reason + 后续里程碑指向）。
**未核对 = step 1c 未达**（trial #2 review #9 黑名单头像 TODO 跨 trial 遗债教训）。

### step 3 反悔归类（5 方向）

| 方向 | 含义 | 修复路径 |
|---|---|---|
| spec 漏 case | §1-§4 未覆盖的反向 | 回 step 0 spec 升级 |
| 状态机错 | VM 不变量违反 | 回 step 1a 改 VM |
| View 结构错 | 视觉 / 交互 / 接线 | 回 step 1b 改 View |
| 通用知识缺失 | 项目级技术坑 | 沉淀到 `.claude/rules/` |
| **范围扩展** | 用户期望随场景演进（§0.3 占位 → 真做） | spec 升级范围 + 实施；不算流水线失误 |

## 不适用

- **A 档任务**：仍按全量 7 步
- **C 档任务**：本来不走流水线
- **首次试某新形态**：即使硬指标命中 B，若项目内首次尝试该形态（如首次"无限滚动"/"WebSocket 列表"），**明示**按 A 档投资跑一次

## 与既有规则关联

- **`feature-pipeline` skill**:skill 是"做什么 + 怎么做",本规则是"何时降档"
- **本规则不再扩展**:诞生于"三次复查直至终版"复盘。下次想加新维度时先问"是不是又在仪式化"

## 历史教训

- **2026-06 I-1 黑名单 trial #2**:CRUD 极简页跑 A 档 ~5h,首次立本 rule
- **2026-07-17 LiveGiftTask**:3 fetch + IM refresh 硬命中 A,走 A 档 spec v1/v2 + 15 finding red team + 5-agent 精读 workflow,用户明示"这么简单的功能不要搞 spec 这么久这么复杂"。**加严"降档信号"三条**,让"看着接口多但业务简单"的场景自动走 B。**代码本身有效,复盘的是过程重量**
