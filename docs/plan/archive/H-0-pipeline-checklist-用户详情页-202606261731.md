# H-0 用户详情页 — 流水线 Checklist

> **目标**：feature-pipeline 7 步流水线执行追踪 + 反悔记录
> **关联 spec**：[H-0-spec-用户详情页-202606250130.md](H-0-spec-用户详情页-202606250130.md) v3
> **里程碑**：H 前置（IM 完善的隐性前置）
> **启动时间**：2026-06-25 01:30
> **完成时间**：2026-06-26 17:31
> **flow trial**：feature-pipeline trial #3（A 档全量 7 步）

---

## 当前进度

| Step | 状态 | 完成时间 |
|---|---|---|
| step 0 spec + 红队外审 | ☑ 完成 | 2026-06-25 02:00 |
| step 1a Store + 状态机 + protocol + 单测 | ☑ 完成 | 2026-06-25 18:11 |
| step 1b UI 还原（按 H5 视觉自构） | ☑ 完成 | 2026-06-25 19:37 |
| step 1c API model + 真接口 + decode tests | ☑ 完成 | 2026-06-25 19:58 |
| step 2 接线 + BlocklistVM observer | ☑ 完成 | 2026-06-25 20:00 |
| step 3+4 真集成 + 真机签字 | ☑ 完成 | 2026-06-26（含 10 项反悔批次修复） |
| step 5 代码审查（/review deep） | ☑ 完成 | 2026-06-25 22:56（5 项建议落地） |
| step 6 retrospective | ☑ 完成 | 本文件即产物 |

---

## step 0 — Spec v3 + 红队外审

### 产出
- [x] [spec v3](H-0-spec-用户详情页-202606250130.md) — 397 行（trial #2 699 → 砍 43%）
- [x] H5 二次校验完整：`userProfile/index.vue` 362 行 + `type.ts FollowUserOpt` + `c-followButton.vue` 真 emit
- [x] 范围三圈：核心（展示+关注+拉黑）/ 占位（私聊/通话/举报/礼物墙）/ 不做（Moments/customBack）
- [x] 状态机三层：LoadState + FollowState (optimistic) + BlockState (非 optimistic)
- [x] 7 不变量
- [x] 验收清单 F-1~11 + R-1~22
- [x] 多入口路由架构：UserProfileRoute enum 共享，各 tab 在 MainTabView 内 NavigationStack 根注册

### Plan agent 红队（backlog #1 首试用"挖未知 case"提示词）
- 10 条意见 / **0 噪声**（trial #2 是 27 条 70% 是 token 化品味优化）
- 全部属实：6 🔴 + 4 🟠
- 关键发现：H5 type.ts `followed: boolean` 实际是 H5 模板用 `followFlag`（H5 自身 bug）；LiveState 没 `.joined` 是 `.living`；blockUser body 含 `isLive` 与 BlocklistService.removeBlock 不同
- **prompt 改造首次成功验证** — 写入下次 trial 复用

### 验收门
- [x] 用户审字 → step 1a

---

## step 1a — Store + 状态机 + Service protocol + Fakes + 单测

### 产出
- [UserProfileModels.swift](../../Sources/Profile/UserProfile/UserProfileModels.swift) — UserDetail + FollowUserRequest + BlockUserRequest + UserProfileRoute + LoadState + Service protocol
- [UserProfileViewModel.swift](../../Sources/Profile/UserProfile/UserProfileViewModel.swift) — 三状态机 + 7 不变量 + loadGeneration token + pendingIds 并发守
- [UserProfileService.swift](../../Sources/Profile/UserProfile/UserProfileService.swift) — stub（step 1c 替换真实现）
- [FakeUserProfileService.swift](../../Tests/HilyTests/UserProfile/FakeUserProfileService.swift) — Result 注入 + delaySeconds + 调用记录 + UserDetail.fixture
- [UserProfileViewModelTests.swift](../../Tests/HilyTests/UserProfile/UserProfileViewModelTests.swift) — 22 单测
- [FollowRelationNotification.swift](../../Sources/Profile/FollowList/FollowRelationNotification.swift) — `.followRelationChanged` 从 FollowListModels 抽出独立文件（HilyTests target 编译需要）

### 验收门
- [x] xcodebuild test SUCCEEDED — 274/274（既有 247 + 新增 22 + decode tests 5 个先行）

---

## step 1b — UI 还原（按 H5 视觉自构）

### 决策：跳过 /restore-design，按 H5 视觉自构
- **理由**：用户暂不提供切图。`anchor-livechat-h5/src/views/userProfile/index.vue` 362 行模板齐全，三色光环 / Communication 按钮 / Stats 卡片 / 礼物墙等 H5 完整视觉已落 spec §1.3-1.4
- **效果**：高保真 ~80%（用户真机反馈"基本 80%"）+ 留 5 处反悔（见 step 3）

### 产出
- [UserProfileView.swift](../../Sources/Profile/UserProfile/UserProfileView.swift) — 主 View + 子组件 inline + 5 #Preview（默认/Following/已拉黑/Error/RTL）
- Theme.swift +UserProfile section：12 Palette / 30+ Metric / 11 Typography
- L10n.swift +H-0 23 keys + commonBack
- {en,ar,tr}.lproj/Localizable.strings +H-0 段（三语对照 H5 i18n）

### 接线
- [MainTabView.swift](../../Sources/Home/MainTabView.swift) — +homePath + .home NavigationStack + navigationDestination(UserProfileRoute) + onChange selection 清 homePath
- [LiveListUserCard.swift](../../Sources/Home/LiveTab/List/Components/LiveListUserCard.swift) — 整 cell NavigationLink(value: UserProfileRoute.userId(...)) + actionButton .borderless 阻断冒泡

### 验收门
- [x] BUILD SUCCEEDED
- [x] 单测无回归 332/332
- [x] **跳过 step 1b red team**（complexity-tier rule：UI 视觉问题留真机暴露 ROI 更高）

---

## step 1c — 真 Service + 5 路 decode + decode tests

### 产出
- UserProfileService.swift 替换 stub 为真实现：getUserDetail + followUser + blockUser
- 5 路 decode fallback：null literal / 顶层对象含 userId / wrapped (data/result/profile/user) / 字典无识别 key / 非 JSON
- parseGift helper：`giftImg || icon` / `giftCount || num` 双兼容
- **NSNumber objCType 严格 Bool 判定**（`"c"`/`"B"` 真 Bool / 其他 → false）防 H5 `followFlag` bug 桥接坑
- [UserProfileDecodeTests.swift](../../Tests/HilyTests/UserProfile/UserProfileDecodeTests.swift) — 26+5 = 31 单测含 thumbs/giftList/userId 类型边界

### 验收门
- [x] 332/332 → 339/339（5 路 fallback + thumbs 派生 + followed 严格 Bool + giftList 兼容）

---

## step 2 — 接线 + spec §5.4 BlocklistVM observer

### 产出
- BlocklistViewModel.swift +`.blocklistChanged` observer + reloadFirstPage
  - **trial #2 留的钩子本期真启用** —— spec §5.4 兑现
- isLiveProvider 维持默认 `{ 0 }`（H-0 当前唯一入口 LiveTab/List 主播未开播，isLive 永 0；待 LiveStore 全局化后升级）

### 验收门
- [x] 三轨接线齐：runtime/preview/test
- [x] 黑名单与详情页跨页同步契约对齐（trial #2 review #10 + 本期 spec §5.4 闭环）

---

## step 3+4 — 真集成 + 真机签字（按 complexity-tier rule 合并）

### 反悔批次记录（10 项）

| # | 触发点 | 假设 | 实际 | 反悔方向 | 修复 |
|---|---|---|---|---|---|
| 1 | 详情页加载 | spec §2.3 严格 String userId fail-loud（H5 type.ts:139 声明 string） | 真接口返 `__NSCFNumber` 1000001877 → decode fail-loud → load .error | spec 漏 case + 通用知识缺失 | parseDetail 兼容 NSNumber→String 排除 Bool；spec v3 升级；沉淀 `.claude/rules/ios-decode-userid-compat.md` |
| 2 | tap Follow | spec §2.1 body 字段名 `type` | 接口报 `followTypemust not be null` | spec 漏 case（H5 type.ts:58 FollowUserOpt 字段名是 `followType`） | FollowUserRequest 字段 rename + Service body 改 + 单测改 |
| 3 | NavBar Back 文案 | iOS 系统 back button 默认 | 用户：不要 Back 文案 | View 结构错 | `.navigationBarBackButtonHidden(true)` + 自定义 chevron toolbar |
| 4 | NavBar 中央昵称 | iOS 习惯显示标题 | 用户：H5 没有，不要 | View 结构错 | 去除 `ToolbarItem(.principal)` |
| 5 | 消息/拨打按钮位置 | 我做了底部 ActionBar 矩形按钮 | H5 是头像右侧 40x40 圆按钮（line 170 CCommunicationBtns） | View 结构错 | 移到头像行右侧 + 删底部 ActionBar |
| 6 | 文案对齐 | 我写 FOLLOW/Likes/Gifts received | H5 真文案 Follow/Like Count/Send Gifts/对应 i18n | View 结构错 | EN/AR/TR 三语全对齐 H5 真文案 |
| 7 | 礼物墙占位 | spec §0.3 占位 H 里程碑做 | 用户：接口返了 giftList 实数据要展示 | spec 范围扩展 | 加 Gift struct + parseGift + LazyVGrid 渲染（接口 giftList 字段名 type.ts 不完整，giftImg/icon/giftName/giftCount/num 双兼容） |
| 8 | 左滑返回 | `.navigationBarBackButtonHidden(true)` + 自定义 leading 禁用了 swipe back | 用户：为什么不支持左滑返回 | 通用知识缺失 | 新建 SwipeBackEnabler.swift UIViewControllerRepresentable hack interactivePopGestureRecognizer.delegate = nil + viewWillDisappear 还原 |
| 9 | 礼物墙 grid 自适应 vs 固定 | adaptive 列宽用户觉得稀疏 | 用户：1 行 5 个固定 + icon 放大 | View 结构错 | 改 `flexible()×5` + GeometryReader 让 icon 占 cell 宽 80%（review 后改为 maxWidth: .infinity + aspectRatio） |
| 10 | 拨打按钮接入 | 当前是 "Coming soon" 占位 | 用户：通话已开发，应该调用 | 范围扩展 | `CallStore.shared.callOut(remoteUserId:)` 接入 + 守卫（RTM ready + state==.idle）+ lastError toast |

### review（建议-1~5）落地
经 [代码审查报告 202606252256](代码审查报告-202606252256.md) 13 条 → 9 个独立问题（去重）→ 二次复查 5 建议 / 4 可忽略 → 用户拍板修建议：
- 建议-1 SwipeBackEnabler delegate 还原（避免 nav 污染）
- 建议-2 userId logger 全部加 privacy:.private（项目纪律一致性 9 处）
- 建议-3 decodeDetail preview 加 privacy:.private（PII 边界）
- 建议-4 礼物 a11yLabel `userProfileA11yGiftFallback` 三语 key
- 建议-5 showingComingSoonToast 用 `.task(id: comingSoonToken)` 模式（与 transientError 对齐）

### 跨 trial 发现：BlocklistRow 头像 fix
- **pre-existing**：trial #2 step 1b review #9 TODO "step 1c 加 AsyncImage" 没在 step 1c 完成 → 用户黑名单列表头像永远显示 SF Symbol
- 修复：AsyncImage + SF Symbol 兜底（与 LiveListUserCard / UserProfileView 同款）
- **教训**：trial #2 当时自评"零反悔"失实

### 验收门
- [x] xcodebuild test SUCCEEDED — 339/339 全过
- [x] 用户真机签字
- [x] 反悔批次全部归类（spec / View / 通用知识 三方向 + 范围扩展）

---

## step 5 — 代码审查（/review deep）

详见 [代码审查报告 202606252256](代码审查报告-202606252256.md)。

### 关键数据
- Workflow：5 维度并行 finder + 3 票对抗验证（59 agents / 287 tool uses / 6.5 min）
- 原始 18 条 → 验证通过 14 条 → 去重 13 条
- 二次复查（按 [code-review-discipline.md](../../.claude/rules/code-review-discipline.md)）→ **9 个独立问题**：0 必修 / 5 建议 / 4 可忽略

### 关键反思
- 第一次报告**高估了严重度**（P1 都不是 user-triggerable bug）
- Workflow 多维并行的去重盲点：同问题被 4 维度发现，对抗投票通过但语义聚类缺失

---

## step 6 — Retrospective

### A. 各验收门有效性

| step | 验收门 | 本次有效？ | 决策 |
|---|---|---|---|
| 0 | spec 用户审字 + Plan agent red team | ✅ 高价值 | 保留 + "挖未知 case" prompt 改造已固化 |
| 0 | red team 0 噪声 | ✅ 验证成功 | backlog #1 prompt 修改写入 skill |
| 1a | 反向→单测对应表 | ✅ 有效 | 保留 |
| 1b | Build SUCCEEDED + Preview 覆盖 | ⚠️ 部分 | UI 视觉问题靠真机暴露（5 项反悔印证留真机 ROI 合理） |
| 1b | **跳过 red team** | ✅ 决策正确 | trial #2 step 1b 27 条 70% 噪声，跳过省时间 |
| 1c | Fakes 异常 ↔ spec 反向对应表 | ✅ 高价值 | 保留 |
| 2 | spec §5.4 兑现 | ✅ 闭环 | trial #2 留的钩子本期真启用 |
| 3+4 | 真机签字（反悔 10 项归类） | ✅ 有效 | 4 方向分类机制完整使用 |
| 5 | /review deep + 二次复查 | ✅ 新流程验证 | `code-review-discipline.md` 防"高估严重度"机制有效 |
| 6 | 元复盘 | ✅ | 本文件 |

### B. trial #3 vs trial #2 关键改进

| 维度 | trial #2（黑名单） | trial #3（用户详情页） |
|---|---|---|
| Spec 篇幅 | 699 行 | 397 行（-43%） |
| Red team 意见 | 27 条 / 70% 噪声 | 10 条 / **0 噪声** |
| Red team 接受率 | 17/27 = 63% | 10/10 = 100% |
| step 3 反悔 | 0（自评）/ **实有 1 项 review #9 遗债** | 10 项（10/10 真问题，含 review 5 建议） |
| 真机 UI 还原度首版 | 接近完美 | 80%（5 项反悔） |
| 决策 picker 数 | 6 | 2 |
| step 1b red team | 跑了 25 条 70% 噪声 | **跳过**（节省 ~15 分钟） |
| 反悔归类 4 方向 | 0 触发未验证 | 4 方向都触发 + 范围扩展 2 项 |

### C. 沉淀 .claude/rules/

- [x] `.claude/rules/ios-decode-userid-compat.md`（trial #3 step 3 反悔 #1 教训）
- [x] `.claude/rules/xcodegen-podinstall-binding.md` 更新（"Xcode 同时开着会让 pod install 静默失效" 真因 + sanity check 模板）

### D. 流程性发现

**1. UI 视觉自构的真机反悔率高**
trial #3 跳过 /restore-design 按 H5 视觉自构 → step 3 真机暴露 5 项 UI 不对齐（反悔 #3~#6 + #9）。**结论**：有切图就走 /restore-design；纯按 H5 模板视觉自构 expect ~5 项 UI 真机微调，不算流程失败。

**2. 流水线对 H5 type.ts 信任问题**
trial #2 + trial #3 各暴露 1 处 H5 type.ts 与真接口字段名/类型不一致（trial #2 没遇到、trial #3 遇到 userId NSCFNumber + followType / giftList 字段名）。**结论**：spec §1 H5 二次校验**必须 + 真机抓包验证字段类型**，不能只信 type.ts。

**3. 跨 trial 发现的 review #9 遗债**
trial #2 step 1b 留 TODO，step 1c 没完成，trial #2 自评"零反悔"失实。trial #3 用户使用时发现。**结论**：step 1b/1c 切换时**显式核对所有 TODO 已消化或显式延期**（写入 step 1c 验收门）。

### E. step 5 + code-review-discipline 新流程验证

trial #3 是 [code-review-discipline.md](../../.claude/rules/code-review-discipline.md) 沉淀后**首次试用**。流程发现：
1. **/review deep 易高估严重度**：3 条 P1 都是 user-non-triggerable，二次复查全降级为建议
2. **二次复查"主动找反例"机制有效**：发现 P2-6 cross-page observer 不必要（MainTabView 已有切 tab 清 path 机制）
3. **rule §3"禁止私自修"机制有效**：分级建议 → 用户拍板 → 按列表执行；修完 §4 评估副作用 → 无新发现

### F. 给下一里程碑（trial #4）建议

| 维度 | 建议 |
|---|---|
| Spec 篇幅 | A 档目标 ≤400 行；B 档 ≤150 行 |
| Red team prompt | 沿用 "挖未知 case" 提示词（trial #3 验证 0 噪声） |
| step 1b red team | 默认跳过（除非用户明示）— trial #3 验证留真机暴露 ROI 更高 |
| step 1c 切换 | 必须显式核对 step 1b 所有 TODO（trial #2 review #9 遗债教训） |
| spec H5 校验 | 必须含**接口真返字段类型验证**节，不能只信 type.ts |
| step 5 /review | 跑 deep + 必走二次复查；按 rule §3 禁止私自修 |
| step 6 retro | 沿用本文件 6 节模板（A 验收门 / B trial 对比 / C 沉淀 / D 流程性 / E 新流程验证 / F 下次建议） |

### 验收门
- [x] 各验收门有效性核对（A 节）
- [x] trial 间对比（B 节）
- [x] rules 沉淀（C 节）
- [x] 流程性发现（D 节）
- [x] 新流程（code-review-discipline）验证（E 节）
- [x] 下次建议（F 节）

**step 6 验收门通过**。

---

## 文档版本

| 时间 | 版本 |
|---|---|
| 2026-06-25 01:30 | spec v1 |
| 2026-06-25 02:00 | spec v2（red team 10 条全吸收）+ step 0 签字 |
| 2026-06-26 | spec v3（step 3 真机反悔批次 + ios-decode-userid-compat rule 落地后修订） |
| 2026-06-26 17:31 | 本 checklist 产出（流水线全程归档） |
