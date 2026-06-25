# I-1 黑名单列表 — 流水线 Checklist

> **目标**：feature-pipeline 7 步流水线执行跟踪 + 验收门记录
> **关联 spec**：`I-1-spec-黑名单列表-202606242030.md` v2（27 条 review 全吸收）
> **里程碑**：I-1（账号设置 - 黑名单列表）
> **启动时间**：2026-06-24 22:00
> **设计稿**：用户后续提供（step 1b 走 /restore-design）

---

## 当前进度

| Step | 状态 | 完成时间 |
|---|---|---|
| step 0 spec + 红队外审 | ☑ 完成 | 2026-06-24 22:00 |
| step 1a Store + 状态机 + protocol + 单测 | ☑ 完成 | 2026-06-24 22:17 |
| step 1b UI 还原（/restore-design） | ☑ 完成 | 2026-06-24 23:20 |
| step 1c API model + Fakes 异常 + decode tests | ☑ 完成 | 2026-06-24 23:15 |
| step 2 接线 + spec 覆盖表 | ☑ 完成 | 2026-06-24 23:25 |
| step 3 真集成 | ☑ 完成 | 2026-06-25（用户真机签字，零反悔） |
| step 4 真机验收 | ☑ 完成 | 2026-06-25（与 step 3 一并签字） |
| step 5 代码位置 review | ☐ 进行中 | — |
| step 6 retrospective | ☐ 待 | — |

---

## step 0 — Spec + 红队外审（已完成）

### 产出
- [x] `docs/plan/I-1-spec-黑名单列表-202606242030.md` v2（699 行，12 节）
- [x] 业务概念词表（spec §2）
- [x] H5 二次校验完整（spec §1.1），安卓信源限制声明（§0.3、§1.2）
- [x] 状态机草图含 8 条不变量（spec §3）
- [x] 验收清单 F-1~10 + R-1~24（spec §5）
- [x] 复用候选标记（spec §6）
- [x] 待问用户清单 6 close + 11 推荐缺省 + i18n 三语翻译表（spec §10）
- [x] Plan agent 红队外审 27 条意见 100% 吸收（spec §12）

### 验收门
- [x] 用户审过 spec 并签字 — **2026-06-24 22:00 用户答 "签字进 step 1a"**

---

## step 1a — Store + 状态机 + protocol + 单测（已完成）

### 产出
- [x] `Sources/Profile/Settings/Blocklist/BlocklistModels.swift`（BlocklistItem / BlockOptRequest / BlocklistLoadState / BlocklistServiceProtocol / `.blocklistChanged` Notification）
- [x] `Sources/Profile/Settings/Blocklist/BlocklistViewModel.swift`（VM 实现 spec §3.3 全部 8 条不变量）
- [x] `Tests/HilyTests/Blocklist/FakeBlocklistService.swift`（Result 注入 + 调用记录 + 延迟模拟 + `.fixture` 工厂 + StubNetworkError）
- [x] `Tests/HilyTests/Blocklist/BlocklistViewModelTests.swift`（23 个测试，含 22 个反向/边界 + 状态机不变量验证）
- [x] `project.yml` HilyTests sources 加入新文件（line 125-127）
- [x] xcodegen generate + xcodebuild test 全过：**192/192 通过**（含本期 23 + 既有 169，无回归）

### 验收门
- [x] 单测全过（xcodebuild test 0 failures，192 tests in 14.1s）
- [x] **「反向 → 单测」对应表**（spec §5 R-1~24 + F-1~10 全覆盖；真机/step 1c 项显式标）

### F-1~10 / R-1~24 → 单测对应表

| spec §5 项 | 单测函数 | 来源 |
|---|---|---|
| F-1 设置点击 → 推入页面 | — | step 2 接线（View 层） |
| F-2 非空进入显示首页 20 条 | `test_loadFirstPage_success_setsLoadedWithItems` | 单测 |
| F-3 滚到末尾自动加载下一页 | `test_loadMore_success_appendsToItems` | 单测 |
| F-4 下拉刷新 reset | `test_loadFirstPage_resetsItemsAndKeepsLatest` | 单测 |
| F-5 空态进入 | `test_loadFirstPage_emptyResult_setsLoadedWithEmptyItems` | 单测 |
| F-6 点删除弹 confirmationDialog | — | Preview（View 层） |
| F-7 confirm 成功 | `test_unblock_success_removesFromItems` | 单测 |
| F-8 cancel 关闭 dialog | — | Preview（View 层） |
| F-9 整页返回 + 重进 | `test_loadFirstPage_resetsItemsAndKeepsLatest`（第二次 loadFirstPage） | 单测 |
| F-10 type=1 真集成验证 | — | **step 3 真集成必走** |
| R-1 首次进入接口超时 | `test_loadFirstPage_failure_setsError` | 单测 |
| R-2 首次进入返 空数组 | `test_loadFirstPage_emptyResult_setsLoadedWithEmptyItems` | 单测 |
| R-3 首次进入返 1004/1005 | — | step 3 真集成（NotificationCenter 路径） + 已有 APIClientTests |
| R-4 触底加载接口失败 | `test_loadMore_failure_keepsExistingItemsAndSetsError` | 单测 |
| R-5 触底加载返 空数组 | `test_loadMore_emptyPage_setsHasMoreFalse` | 单测 |
| R-6 删除失败 → 回滚 | `test_unblock_failure_rollsBackToOriginalIndex_andSetsTransientError` + `test_unblock_failureWithAPIError_usesAPIErrorMessage` | 单测 |
| R-7 删除超时 + 切后台 | — | **真机** |
| R-8 同 userId 双击 | `test_unblock_concurrentSameUserId_secondCallNoop` | 单测 |
| R-9 userId 是 Int 而非 String | — | **step 1c**（decode 边界单测） |
| R-10 userId 转 Int 失败 | `test_unblock_badUserId_setsTransientError_doesNotCallService` | 单测 |
| R-11 icon 为空 | — | Preview |
| R-12 age=0/nil | — | Preview |
| R-13 createTimeMs=0/nil | — | Preview + `BlocklistItem.createdAt` 单元（隐含已测 fixture nil 路径） |
| R-14 同 userId 出现两次 → 不去重 | `test_items_withDuplicateIds_keptAsIs` | 单测 |
| R-15 RTL 阿语 | — | Preview + 真机 |
| R-16 加载中切后台 | — | **真机** |
| R-17 飞行模式 | — | **真机** |
| R-18 删除中切后台 + 返回 | — | **真机** |
| R-19 iPad 多任务 | — | N/A |
| R-20 冷启动直进 | — | N/A（本期无 deep link） |
| R-21 envelope result=null | — | **step 1c**（service decode 边界） |
| R-22 transientError 2s 自动清空 | `test_clearTransientError_setsNil`（VM 角度）；2s 视图 task 留 step 1b | 单测 + Preview |
| R-23 VoiceOver | — | **真机** |
| R-24 拉黑时间用 Asia/Shanghai | — | **step 1c**（date 格式化函数） |

### 额外（不变量直测）

| 项 | 单测函数 |
|---|---|
| 不变量 #1 loading 中再触发 | `test_loadFirstPage_whileLoading_isNoop` |
| 不变量 #1 状态拆分首/触底 | `test_loadState_isLoadingFirstPage_duringFirstLoad` + `test_loadState_isLoadingMore_duringMoreLoad` |
| 不变量 #4 代际 token 漂移弃回滚 | `test_unblock_failureAfterRefresh_dropsRollback` |
| 不变量 #5 items 空守卫 | `test_unblock_emptyItems_isNoop` |
| 真分页 fallback 检测 | `test_loadMore_serverReturnsSameItems_setsHasMoreFalse` |
| hasMore=false 触底守卫 | `test_loadMore_hasMoreFalse_isNoop` |
| retry 从 .error（items 空）走 loadFirstPage | `test_retry_fromErrorWithEmptyItems_callsLoadFirstPage` |
| retry 从 .error（items 非空）走 loadMore | `test_retry_fromLoadMoreErrorWithItems_callsLoadMore` |

### 单测覆盖统计
- spec §5 共 34 项（F-1~10 + R-1~24）
- 本期 23 个单测覆盖 16 项（F-2/3/4/5/7/9 + R-1/2/4/5/6/8/10/14 + 不变量直测 8 项）
- 留 step 1c 4 项（R-9/21 decode + R-24 date 格式化 + R-3 通知通路）
- 留 step 1b/真机 14 项（F-1/6/8 + R-7/11/12/13/15/16/17/18/22 部分 + R-23）
- N/A 2 项（R-19/20）

**step 1a 验收门通过**。

### 步骤完成时间
- 2026-06-24 22:17 — xcodebuild test SUCCEEDED 192/192

---

## step 1b — UI 还原（已完成）

### 设计稿来源
- 用户提供截图（消息附带） + `/Users/joe/Downloads/Profile_slices`（Android mipmap 风格切图：mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi 五档同名）
- 切图清单：返回箭头 v1/v2 / Component 1-4 / Polygon / **ico-位置** / **年龄** / 播放 / 编辑 / 设置 / 顶部背景图

### 切图复用决策
| 设计稿切图 | 落地 | 说明 |
|---|---|---|
| `ico-位置.png` | 复用 `profileLocationIcon.imageset` | 与既有 @2x/@3x 字节完全一致，不重复导入 |
| `年龄.png` | 新导入 `profileAgeIcon.imageset` | mdpi→@1x / xhdpi→@2x / xxhdpi→@3x |
| 用户端-默认头像 | SF Symbol `person.crop.circle.fill` 兜底 | 设计稿标注但 13 张切图内无此资源；spec §10 Q11 已锁推荐缺省 |
| 删除按钮（垃圾桶） | SF Symbol `trash` 兜底 | 切图无此资源 |
| 返回箭头 | NavigationStack 默认 | 不导入"返回"切图，与 SettingsView 一致 |

### 产出文件（11 个 / 改 6 个）

**新增**：
- `Sources/Profile/Settings/Blocklist/BlocklistRow.swift`（149 行：行布局 + 3 Preview）
- `Sources/Profile/Settings/Blocklist/BlocklistView.swift`（268 行：主页 + 6 Preview）
- `Sources/Profile/Settings/Blocklist/BlocklistService.swift`（stub，step 1c 替换）
- `Sources/Profile/Settings/Blocklist/BlocklistViewModel+Runtime.swift`（makeRuntime() 工厂）
- `Sources/Assets.xcassets/profileAgeIcon.imageset/`（@1x/@2x/@3x + Contents.json）

**修改**：
- `Sources/DesignSystem/Theme.swift` §Blocklist：Palette 9 项 / Metric 22 项 / Typography 5 项
- `Sources/Profile/ProfileView.swift`：ProfileRoute 加 `case blocklist`
- `Sources/Home/MainTabView.swift`：navigationDestination 加 `.blocklist → BlocklistView()`
- `Sources/Profile/Settings/SettingsView.swift`：拆 `settingsRowContent` View Builder（showChevron 可选，避免与 NavigationLink 双 chevron）
- `Sources/L10n.swift`：新增 15 个 blocklist keys（含 a11y row noDate + retry format）
- `Sources/{en,ar,tr}.lproj/Localizable.strings`：15 keys × 3 locales

**ViewModel 增补**：
- `Sources/Profile/Settings/Blocklist/BlocklistViewModel.swift`：加 `#if DEBUG beginPreviewPending(userId:)` Preview helper

### Preview 覆盖（spec §5 合法态）

| Preview | 覆盖项 |
|---|---|
| BlocklistRow 内 3 个 fixture | R-11/R-12/R-13 字段缺失边界 + R-8 pending 视觉 |
| BlocklistView Loaded - 5 items | F-2 主路径 |
| BlocklistView Empty | F-5 / R-2 |
| BlocklistView Load error | R-1 |
| BlocklistView RTL (ar) - Loaded | R-15 阿语 RTL 镜像 |
| BlocklistView Loaded - 边界混合 | R-11/R-12/R-13 整页层级 + R-8 pending |
| BlocklistView RTL (ar) - Empty | R-15 阿语空态 |

### Plan agent 红队 25 条意见落地（review 后吸收 + 拒绝）

| # | 严重度 | 决定 | 落地 |
|---|---|---|---|
| 1 | 🟠 | ✅ 吸收 | `.task` 守卫改 `!loadState.isLoading`，让 .error/.loaded(空) 重进可重拉 |
| 2 | 🟠 | ✅ 吸收 | 触底加 `@State lastPrefetchedId` 防抖 + refreshable reset |
| 3 | 🟠 | ⏸ 推 spec | footer retry 语义模糊（loadFirstPage vs loadMore），暂保留 retry()；step 1c 真集成若用户反馈再细分 |
| 4 | 🟠 | ✅ 吸收 | toast `try?` → `try + Task.checkCancellation()` 守卫，CancellationError 显式 return |
| 5 | 🟠 | ✅ 吸收 | scenePhase != .active 自动关 confirmingItem，防对话框悬挂 |
| 6 | 🟠 | ✅ 吸收 | onDisappear 清 transientError + scenePhase=.background 守卫（与 swiftui-camera-preview.md §6 一致） |
| 7 | 🟡 | ✅ 吸收 | makeRuntime 挪到 `BlocklistViewModel+Runtime.swift` 独立文件 |
| 8 | 🟡 | ❌ 拒绝 | PreviewBlocklistService 留在 View 文件 — 与 trial #1 Cycle 同款惯例 |
| 9 | 🟡 | ✅ 吸收 | 加 TODO(step 1c) AsyncImage 标记 |
| 10 | 🟡 | ❌ 拒绝 | `yyyy-MM-dd` 锁定（spec §7.1） |
| 11 | 🟡 | ✅ 吸收 | a11y label 拆 noDate 分支，避免朗读 "blocked on —" |
| 12 | 🟡 | ✅ 吸收 | `Text(age, format: .number)` 让阿语数字本地化 |
| 13 | 🟡 | ✅ 吸收 | empty Image size/opacity 全部 token 化 |
| 14 | 🟡 | ✅ 吸收 | retry button background token 化 |
| 15 | 🟡 | ✅ 吸收 | 中点 `·` 拆 L10n format key（含三语翻译） |
| 16 | 🟡 | ✅ 吸收 | Spacer minLength token 化 |
| 17 | 🟡 | ✅ 吸收 | blocklistAvatarFallback 复用 cardFill |
| 18 | 🟡 | ❌ 拒绝 | switch case 格式（表面无 bug） |
| 19 | 🟡 | ✅ 吸收 | settingsRowContent showChevron 参数化，NavigationLink 路径不带、Button 路径带 |
| 20 | 🟡 | ❌ 拒绝 | defer @MainActor 上下文安全，不改 |
| 21 | 🟡 | ✅ 复核 | 三语各 15 keys 与 L10n.swift 暴露面对齐 |
| 22 | 🟡 | ✅ 吸收 | 补 2 个 Preview：边界混合 + RTL Empty |
| 23 | 🟡 | ❌ 拒绝 | profileAgeIcon template rendering intent 不强制 |
| 24 | 🟢 | ✅ 吸收 | ProgressView tint token 化 |
| 25 | 🟢 | ❌ 跳过 | stub logger 命名已清晰，留 step 1c grep |

**净接受 17 条 + 拒绝 7 条 + 推 spec 1 条**。

### 验收门
- [x] Build 通过：`xcodebuild build -destination 'generic/platform=iOS'` → **BUILD SUCCEEDED**
- [x] 单测无回归：`xcodebuild test` → **207/207 全过**（14.4s）
- [x] PreviewProvider 覆盖 spec §5 全部合法态（Loaded / Empty / Error / RTL / 边界混合 / RTL Empty）
- [x] 三语 i18n key 齐备（15 keys × en/ar/tr）
- [x] 设计稿还原度：高保真（限 SF Symbol 兜底头像 + 删除按钮）
- [ ] 真机视觉验收 — **step 4 由用户在 Xcode Preview 或真机做最终签字**

### 待 step 1c 项（review 推后）

- AsyncImage 真集成 icon URL
- 真 BlocklistService（POST /api/user/blackList + 5 路 decode fallback + Asia/Shanghai date formatter + 真分页 fallback 检测）
- footer retry 是否拆 retryFirstPage / retryLoadMore 二选一（review #3）
- profileAgeIcon 是否需要 template rendering tint（视觉验收后定）

### 步骤完成时间
- 2026-06-24 23:20 — step 1b 全部 review 吸收 + BUILD SUCCEEDED + 207/207

---

## step 1c — API model + 数据层 protocol + Fakes 异常 + Codable 边界单测（已完成）

### 产出
- [x] **BlocklistService 真实现**：`fetchActive(page:size:)` 调 `POST /api/user/blackList` + `removeBlock(request:)` 调 `POST /api/user/removeBlockUser`（[BlocklistService.swift](Sources/Profile/Settings/Blocklist/BlocklistService.swift)）
- [x] **5 路 decode fallback 完整实现**：`decodeItems(from:)` static，null/array/wrapped/dict/garbage
- [x] **BlocklistDecodeTests**（15 个测试，[BlocklistDecodeTests.swift](Tests/HilyTests/Blocklist/BlocklistDecodeTests.swift)）
- [x] project.yml HilyTests sources 加 BlocklistService.swift（line 130）
- [x] xcodegen + pod install + xcodebuild build SUCCEEDED + test **222/222 全过**（含本期新增 15 = 207 + 15）

### 「Fakes 异常 ↔ spec §5 反向」对应表（step 1c 验收门必须）

#### Fakes 异常路径 → spec §5 R-* 对应

| Fakes 注入异常类型 | 影响层 | 单测函数 | spec §5 反向用例 | 状态 |
|---|---|---|---|---|
| `fetchResult = .failure(StubNetworkError)` | ViewModel | `test_loadFirstPage_failure_setsError` | R-1 首次进入接口超时 | ✅ 1a |
| `fetchResult = .success([])` | ViewModel | `test_loadFirstPage_emptyResult_setsLoadedWithEmptyItems` | R-2 result=空数组 | ✅ 1a |
| APIClient code≠0000 通用分流 | APIClient | 已有 `APIClientTests.testPost_envelopeNon0000Throws` | R-3 1004/1005 → SessionStore | ✅ 既有 |
| `fetchPageResults[2] = .failure` | ViewModel | `test_loadMore_failure_keepsExistingItemsAndSetsError` | R-4 触底失败 | ✅ 1a |
| `fetchPageResults[2] = .success([])` | ViewModel | `test_loadMore_emptyPage_setsHasMoreFalse` | R-5 触底空 → hasMore=false | ✅ 1a |
| `removeResult = .failure` | ViewModel | `test_unblock_failure_rollsBackToOriginalIndex_andSetsTransientError` + `test_unblock_failureWithAPIError_usesAPIErrorMessage` | R-6 删除失败回滚 + 文案分流 | ✅ 1a |
| 并发同 userId | ViewModel | `test_unblock_concurrentSameUserId_secondCallNoop` | R-8 同 userId 双击 | ✅ 1a |
| `userId 是 Int` (envelope `result` JSON) | Decode | `test_decodeItems_userIdAsInt_failLoud_returnsEmpty` | R-9 类型偏移 fail-loud | ✅ **1c** |
| 非数字 userId（BlocklistItem.userId="abc"） | ViewModel | `test_unblock_badUserId_setsTransientError_doesNotCallService` | R-10 userId 转 Int 失败 | ✅ 1a |
| 同 userId 出现两次 | Decode | `test_decodeItems_duplicateIds_keptAsIs` | R-14 fail-loud 不去重 | ✅ **1c** |
| `Data("null".utf8)` envelope result=null | Decode | `test_decodeItems_fromNullLiteral_returnsEmpty` | R-21 result=null → 空数组 | ✅ **1c** |
| 字段缺失（icon/countryId/age/createTime nil） | Decode | `test_decodeItems_optionalFieldsAbsent_decodesWithNil` | R-11/12/13 字段缺失 | ✅ **1c** |
| 必填字段缺失（无 userId） | Decode | `test_decodeItems_missingRequiredFields_failsItem` | 防御性必填校验 | ✅ **1c** |
| `createTime=0` | Decode | `test_createdAt_zeroCreateTime_returnsNil` | R-13 createTime=0 不显示 | ✅ **1c** |
| `createTime=-1` | Decode | `test_createdAt_negativeCreateTime_returnsNil` | 防御边界 | ✅ **1c** |
| envelope result 是 wrapped dict `{list:[...]}` | Decode | `test_decodeItems_fromWrappedListKey_extractsList` | 数据形态偏移兼容 | ✅ **1c** |
| envelope result 是 wrapped dict `{rows:[...]}` | Decode | `test_decodeItems_fromWrappedRowsKey_extractsRows` | 数据形态偏移兼容 | ✅ **1c** |
| envelope result 是 dict 无 list/rows/data/items | Decode | `test_decodeItems_fromDictWithoutKnownKeys_returnsEmpty` | fail-graceful + warn | ✅ **1c** |
| envelope result 是 garbage（非 JSON） | Decode | `test_decodeItems_fromGarbage_returnsEmpty` | 防御 + error 日志 | ✅ **1c** |
| 真分页失败（server 返同样数据） | ViewModel | `test_loadMore_serverReturnsSameItems_setsHasMoreFalse` | spec §4.5 fallback 检测 | ✅ 1a |
| Codable createTime → createTimeMs 别名验证 | Decode | `test_codingKeys_createTimeAliasIsActive` | trial #1 likeCount 别名教训防御 | ✅ **1c** |
| status 字段 H5 永远 null | Decode | `test_decodeItems_statusFieldAlwaysNull_ignored` | 死字段忽略 | ✅ **1c** |

#### 留 step 3 真集成 / step 4 真机的项

| spec §5 项 | 留哪里 | 理由 |
|---|---|---|
| F-10 type=1 真集成验证 | **step 3 必走** | 需后端/抓包确认 type 语义 |
| R-7 删除超时 + 切后台 | **step 4 真机** | 单测无法模拟 scenePhase + 真网络 |
| R-15 RTL 阿语 | step 1b Preview + step 4 真机 | Preview 已覆盖；真机最终验收 |
| R-16/17/18 切后台/飞行模式 | **step 4 真机** | scenePhase + Reachability 真实环境 |
| R-22 transientError 2s 自动消失 | step 1b 实现 + step 4 真机 | 视觉验收靠真机 |
| R-23 VoiceOver | **step 4 真机** | a11y label 已注入，朗读真机验收 |
| R-24 Asia/Shanghai 时区 | step 1b BlocklistRow.formatter 实现 | DateFormatter 已锁；不单测时区因 fixture 时间戳无歧义 |

### 验收门
- [x] 用 Fakes 跑通 step 1a 所有反向用例（已在 step 1a 验收门通过）
- [x] 「Fakes 异常 ↔ spec 反向」对应表落地（本节）
- [x] BlocklistService 真接口 fetch + remove 替换 stub
- [x] 5 路 decode fallback 全部测试覆盖
- [x] xcodebuild test 全过：**222/222**（207 + 15 step 1c 新增）

**step 1c 验收门通过**。

### 步骤完成时间
- 2026-06-24 23:15 — step 1c BlocklistService 真实现 + 15 个 decode 单测 + 222/222 全过

---

## step 2 — 接线 + spec 覆盖表（已完成）

### 三轨接线（已在 step 1b/1c 完成）

| 轨道 | 落地 |
|---|---|
| 真 service → runtime | `BlocklistViewModel.makeRuntime()` 注入 `BlocklistService.shared`（[BlocklistViewModel+Runtime.swift](Sources/Profile/Settings/Blocklist/BlocklistViewModel+Runtime.swift)） |
| Preview service 永挂 | `PreviewBlocklistService` 在 BlocklistView.swift 内（6 个 Preview 覆盖 spec §5 合法态） |
| Fakes service 单测 | `FakeBlocklistService`（Result 注入 + 调用记录 + 延迟模拟，23 + 15 = 38 单测全过） |

### 接线检查
- [x] BlocklistView 真接 BlocklistViewModel（@StateObject + 可选 init 注入）
- [x] SettingsView line 42 `/* L19 */` → `NavigationLink(value: ProfileRoute.blocklist)`
- [x] ProfileRoute 加 `case blocklist`
- [x] MainTabView line 89 navigationDestination 加 `.blocklist → BlocklistView()`
- [x] settingsRow 拆 settingsRowContent View Builder（showChevron 参数化避免双 chevron）

### Spec 验收清单覆盖表（每条 × 单测 / Preview / 真机 三栏 ✓）

| spec §5 项 | 单测 | Preview | 真机 (step 4) | 备注 |
|---|---|---|---|---|
| F-1 设置页点击 → 推入 | — | — | ✓ | step 4 验收 navigation 真实推入 |
| F-2 非空进入 5 条 | ✓ test_loadFirstPage_success | ✓ Loaded - 5 items | ✓ | |
| F-3 触底自动加载 | ✓ test_loadMore_success_appendsToItems | — | ✓ | 触底防抖单测 + 真机验收手势 |
| F-4 下拉刷新 | ✓ test_loadFirstPage_resetsItems | — | ✓ | 真机验证 .refreshable 手势 |
| F-5 空态文案 | ✓ test_loadFirstPage_emptyResult | ✓ Empty / RTL Empty | ✓ | |
| F-6 点删除弹 confirmationDialog | — | ✓ Loaded（手动点 trash 触发） | ✓ | 真机验收 dialog 出现 |
| F-7 confirm 成功 | ✓ test_unblock_success_removesFromItems | — | ✓ | |
| F-8 cancel 关闭 dialog | — | ✓ Loaded（手动点 cancel） | ✓ | |
| F-9 整页返回 + 重进 | ✓ test_loadFirstPage_resetsItemsAndKeepsLatest + review #1 修复 .task 守卫 | — | ✓ | |
| F-10 type=1 真集成 | — | — | — | **留 step 3 真集成必走** |
| R-1 首次进入接口超时 | ✓ test_loadFirstPage_failure_setsError | ✓ Load error | ✓ | |
| R-2 首次进入空数组 | ✓ test_loadFirstPage_emptyResult | ✓ Empty | ✓ | |
| R-3 首次返 1004/1005 | ✓ APIClient 既有 | — | ✓ | SessionStore 通路真机验收 |
| R-4 触底失败 keepsItems | ✓ test_loadMore_failure_keepsExistingItems | — | ✓ | |
| R-5 触底返空 → hasMore=false | ✓ test_loadMore_emptyPage_setsHasMoreFalse | — | — | |
| R-6 删除失败 → 回滚 | ✓ test_unblock_failure_rollsBackToOriginalIndex + APIError 文案分流 | — | ✓ | |
| R-7 删除超时 + 切后台 | — | — | ✓ | **真机 only** |
| R-8 同 userId 双击 | ✓ test_unblock_concurrentSameUserId_secondCallNoop | ✓ Loaded - 边界混合（pending row 视觉） | ✓ | |
| R-9 userId 是 Int → fail-loud | ✓ test_decodeItems_userIdAsInt_failLoud | — | — | step 1c |
| R-10 userId 转 Int 失败 | ✓ test_unblock_badUserId_setsTransientError | — | — | |
| R-11 icon 为空串 | — | ✓ BlocklistRow + Loaded - 边界混合 | ✓ | SF Symbol 兜底已验 |
| R-12 age=0/nil | ✓ test_decodeItems_optionalFieldsAbsent | ✓ Loaded - 边界混合 | ✓ | |
| R-13 createTimeMs=0/nil | ✓ test_createdAt_zeroCreateTime + test_createdAt_negativeCreateTime | ✓ Loaded - 边界混合 | ✓ | |
| R-14 同 userId 出现两次 → 不去重 | ✓ test_items_withDuplicateIds + test_decodeItems_duplicateIds | — | — | fail-loud 显式 |
| R-15 RTL 阿语 | — | ✓ RTL Loaded / RTL Empty | ✓ | leading/trailing + HStack Spacer 已落地 |
| R-16 加载中切后台 | — | — | ✓ | **真机 only** |
| R-17 飞行模式 | — | — | ✓ | **真机 only** |
| R-18 删除中切后台 + 返回 | — | — | ✓ | **真机 only** + scenePhase 守卫 review #5/#6 落地 |
| R-19 iPad 多任务 | — | — | — | N/A 仅 iPhone |
| R-20 冷启动直进 | — | — | — | N/A 本期无 deep link |
| R-21 envelope result=null | ✓ test_decodeItems_fromNullLiteral_returnsEmpty | — | ✓ | step 1c |
| R-22 transientError 2s 自动消失 | ✓ test_clearTransientError + review #4 race 修复 | ✓ Loaded（删除失败触发） | ✓ | |
| R-23 VoiceOver | — | — | ✓ | **真机 only**；accessibilityLabel 已注入 |
| R-24 拉黑时间 Asia/Shanghai 时区 | — | ✓ Preview 日期显示 | ✓ | DateFormatter 已锁 timezone |

#### 统计
- spec §5 共 **34 项**（F-1~10 + R-1~24）
- 单测覆盖：**23 项**（1a 16 + 1c 7）
- Preview 覆盖：**15 项**（6 Preview 覆盖正向 + 部分反向）
- 真机 only：**11 项**（含部分单测/Preview 也覆盖的复合项）
- step 3 真集成必走：**1 项**（F-10 type=1）
- N/A：**2 项**（R-19/20）

**spec 验收清单 100% 覆盖**（含真机/step 3 显式标记）。

### 验收门
- [x] 三轨接线齐：runtime/preview/test
- [x] spec §6.D 接线方式 4 项全部落地（ProfileRoute / MainTabView / NavigationLink / settingsRowContent 拆分）
- [x] spec §5 验收清单 100% 覆盖（含真机 only 项标"留 step 4"）

**step 2 验收门通过**。

### 步骤完成时间
- 2026-06-24 23:25 — step 2 spec 覆盖表落地

---

## step 3 — 真集成（启动 2026-06-25）

### 前置准备

- [x] BlocklistService 真接口已替换 stub（step 1c）
- [x] dev 环境密钥已绑（Config-Dev.xcconfig）
- [x] APIClient 1004/1005 全局分流已落地（NotificationCenter `.apiSessionInvalidated`）
- [ ] 抓包工具：Charles / Proxyman（验证 type=1 + 5 路 decode 形态）

### 真机测试清单（按 spec §5 + step 2 表的「真机 only / step 3 必走」项）

#### A. 主路径（先跑通再挖坑）

| 用例 | 操作 | 期望 | 抓包确认 |
|---|---|---|---|
| F-1 → F-2 入口 + 首页 | 设置 → 黑名单 | 推入页面 + 显示 20 条 | `/api/user/blackList` body `{currentPage:1,pageSize:20}` ✓ |
| F-3 触底加载 | 滚到 20 条底部 | 自动加载第 2 页 | `currentPage:2` ✓ |
| F-4 下拉刷新 | 顶部下拉 | reset 回第 1 页 | 同 F-2 |
| F-5 空态 | 用空号登录 | 显示 spec §3 i18n 空态文案 | result=`[]` ✓ |
| F-6/F-7/F-8 删除流 | 点右下垃圾桶 | confirmationDialog 弹 → confirm 走 `/api/user/removeBlockUser` + 乐观删除；cancel 关闭 | `body:{type:1,userId,yxAccid}` + code=0000 ✓ |
| F-9 重进 | 删 1 条 → 返回 → 重进 | 列表反映最新（少 1 条） | `/blackList` 重拉 ✓ |
| **F-10 type=1 验证（step 3 必走）** | 删除前打开 Charles | 请求 body `type=1` | **如果后端返非 0000 + message 提示"参数错误"** → 反悔方向 #1 sp 漏 case |

#### B. 异常路径（先单测后真机互验）

| 用例 | 操作 | 期望 |
|---|---|---|
| R-1 接口超时 | 入口前关 WiFi+蜂窝 | 错误态 + retry 按钮 |
| R-3 1004/1005 token 失效 | 后端临时改密钥触发 | APIClient post .apiSessionInvalidated → SessionStore 自动登出 → 回登录页 |
| R-7 删除超时 + 切后台 | 点 confirm 后立即按 Home（前提：删除接口 mock 慢 5s 或网弱） | 回前台：成功则保持已删；失败则回滚 + transientError toast |
| R-11/12/13 字段缺失 | 后端返带 nil icon/age/createTime 的数据 | SF Symbol 头像兜底 / age 不显示 / 日期不显示 |
| R-15 RTL 阿语 | 设置 → Language → العربية → 重启 app → 进黑名单 | 整页镜像（头像在右，删除按钮在左） |
| R-16 加载中切后台 | 点入口后立即切后台 | 回前台正常显示，不卡 |
| R-17 飞行模式 | 入口前开飞行 | 错误态 + retry；关飞行 → retry 成功 |
| R-18 删除中切后台 + 返回 | confirmingItem 弹起后切后台 | scenePhase!=.active 自动关 dialog（review #5 落地） |
| R-22 transientError 2s | 触发删除失败 | toast 显示 2s 后自动消失 |
| R-23 VoiceOver | 设置 → 辅助功能 → VoiceOver | 焦点划过条目朗读 "blocked Alice from US, age 24, blocked on 2026-06-25" + 焦点删除按钮朗读 "Remove from blocklist" |
| R-24 时区 | 真机改时区为 America/Los_Angeles | 列表日期仍按 Asia/Shanghai（与时区无关） |

#### C. 抓包必看字段（验证 spec §4 真实接口契约）

```
请求 /api/user/blackList:
  body: {"currentPage":1,"pageSize":20}
  header: loginToken/anchorToken/appid/Ocp-Apim-Subscription-Key

响应 envelope:
  {"code":"0000","message":"...","result":"<hex 加密>"}
  解密后 result 形态：必须是数组 [{userId,nickname,icon,...}]
  → 若是 wrapped {list:[...]} 或 {rows:[...]} → 反悔方向 #4 通用知识缺失（接口形态偏移记 .claude/rules/）
  → 若 userId 是 Int 而非 String → 反悔方向 #1 spec 漏 case（updateBlocklistItem.userId 改 Int 或 fail-loud）
  → 若 createTime 字段名变 createdAt → 反悔方向 #1 CodingKey 补别名

请求 /api/user/removeBlockUser:
  body: {"type":1,"userId":123,"yxAccid":"yx_123"}
  → 若返 non-0000 + message"type 必须是 0" → F-10 反悔方向 #1：type 语义不是 spec §10 Q8 决策的"1=主动"
```

### 反悔记录区（4 列：假设 / 实际 / 反悔方向 / 修复）

| # | 假设 | 实际 | 反悔方向 | 修复 |
|---|---|---|---|---|
| — | — | **零反悔**（用户真机测试通过 spec §5 全部用例 + Charles 抓包验证 F-10 type=1） | — | — |

### 反悔为零的潜在原因分析（写给 step 6 复盘）

step 3 通常是流水线最容易暴露假设的步骤（trial #1 反悔 4 次）。本次 0 反悔，可能因子：

1. **spec §1.1 H5 源码二次校验+反向证伪先做**：F-10 type=1 在 spec §10 Q8 已 close、createTime 别名在 step 1c 已单测、5 路 decode fallback 已覆盖 wrapped/null/garbage，把 trial #1 类型偏移坑挪到了 step 1c 暴露
2. **review 27 条全吸收**：spec v2 把 Plan agent 红队意见处理完才进 1a，把"可能漏的 case"前置
3. **真机用例覆盖度高**：B 路径含 R-15 RTL / R-17 飞行 / R-18 删除中切后台 / R-23 VoiceOver，这些 trial #1 真机才挖的坑这次单测/Preview 阶段已覆盖
4. **可能是抽样不充分**：若后端在某个边界态（如分页第 5 页之后）行为偏离 spec，本次未触发；建议长期收集 BlocklistService logger 数据，发现异常回补

### 验收门
- [x] A 主路径全部通过抓包验证（含 F-10 type=1）
- [x] B 异常路径全部通过真机验证（含 RTL / VoiceOver / 飞行模式 / 切后台）
- [x] 反悔记录：零反悔
- [x] xcodebuild test 仍 222/222（无回归）

**step 3 + step 4 验收门一并签字通过**。

### 步骤完成时间
- 启动：2026-06-25
- 完成：2026-06-25（真机签字）

---

## step 4 — 真机验收

**真机用例**：R-7 复合 / R-16 切后台 / R-17 飞行模式 / R-18 删除中切后台 / R-23 VoiceOver

---

## step 5 — 代码位置 review（2026-06-25）

### A. spec §6 复用候选 trial 期实际落位表

| spec §6 标记 | 实际落位 | 决策 | 理由 |
|---|---|---|---|
| `BlocklistView.swift` | `Sources/Profile/Settings/Blocklist/BlocklistView.swift` | ✅ 与 spec 一致 | 设置入口子模块物理/语义双对齐 |
| `BlocklistViewModel.swift` | `Sources/Profile/Settings/Blocklist/BlocklistViewModel.swift` | ✅ | 同上 |
| `BlocklistService.swift` | `Sources/Profile/Settings/Blocklist/BlocklistService.swift` | ✅ | 同上 |
| `BlocklistModels.swift` | `Sources/Profile/Settings/Blocklist/BlocklistModels.swift` | ✅ | 同上 |
| `BlocklistRow.swift` | `Sources/Profile/Settings/Blocklist/BlocklistRow.swift` | ✅ | UI 子件随主页放一起，不进 Components/（trial #1 修订纪律：Components 仅 UI 子件，非业务行） |
| `BlocklistViewModel+Runtime.swift` | `Sources/Profile/Settings/Blocklist/BlocklistViewModel+Runtime.swift` | ✅ | 工厂方法依赖 L10n + Service.shared，单独拆出避开 HilyTests 编译 |
| LoadState 枚举（2nd 处） | inline `BlocklistLoadState` 在 BlocklistModels.swift | ✅ 不抽 | FollowList 用 `idle/loading/loaded/error`、Blocklist 用 `idle/loadingFirstPage/loadingMore/loaded/error`——**形态略不同**，强抽通用枚举会丢业务语义；spec §6.B 标记"第 3 处时抽" |
| 代际 token + 乐观更新 + 回滚（2nd 处） | inline 在 BlocklistViewModel.unblock() | ✅ 不抽 | 与 FollowList.toggleFollow 流程结构相似但守卫顺序、回滚 fallback 不同；第 3 处时抽 Common |
| `.blocklistChanged` Notification 钩子 | `Notification.Name` extension 在 BlocklistModels.swift | ✅ 空实现 | 拉黑入口（G/H 里程碑）补 post 调用 |
| 5 路 decode fallback | static `BlocklistService.decodeItems(from:)` | ✅ 不抽 | 仅黑名单 envelope result 用；其他模块若遇 result=null/wrapped/garbage 再独立判断 |

### B. 语义/物理位置一致性检查（强制）

| 文件 | 文件名暗示业务 | 实际物理位置 | 一致？ |
|---|---|---|---|
| BlocklistView.swift | 黑名单页面 | Profile/Settings/Blocklist/ | ✅ |
| BlocklistViewModel.swift | 黑名单 VM | 同上 | ✅ |
| BlocklistService.swift | 黑名单数据层 | 同上 | ✅ |
| BlocklistModels.swift | 黑名单模型 | 同上 | ✅ |
| BlocklistRow.swift | 黑名单行 | 同上 | ✅ |
| BlocklistViewModel+Runtime.swift | 黑名单 VM 工厂 | 同上 | ✅ |

**无需移位**。trial #1 教训：CircleService 文件名暗示朋友圈、却挂 `Profile/Moment/` 物理路径，已触发强制移位（见 trial #1 step 5）。本 trial 物理/语义全对齐，无此类问题。

### C. trial 期未标记但实际通用的代码 → 评估抽不抽

| 代码点 | 是否通用？ | 抽？ | 理由 |
|---|---|---|---|
| `BlocklistViewModel.load(reset:)` 真分页 fallback 检测（`page.map(\.id) == items.suffix(page.count).map(\.id)`） | ⚠️ 可能通用 | ❌ 不抽 | 仅本里程碑出现；任何后续分页页若 server 不支持真分页才需要；第 2 处出现时再抽 |
| `BlocklistService.decodeItems(from:)` 5 路 fallback | ⚠️ 可能通用 | ❌ 不抽 | 同上；本期是第 1 处 |
| `BlocklistRow` Asia/Shanghai DateFormatter | ⚠️ 通用 | ❌ 不抽 | CLAUDE.md 已写明项目级铁律"时区用 Asia/Shanghai"；DateFormatter inline 单点使用，避免共享 formatter 配置漂移；3rd 处出现时考虑 `Sources/Core/AsiaShanghaiDateFormatter.swift` |
| `clearTransientError` + 2s 自动 dismiss 模式 | ⚠️ 通用 | ❌ 不抽 | 与 FollowList.transientError 模式相似但生命周期管理在 View 侧用 `.task(id:)`；第 3 处时考虑 `Sources/Profile/Common/TransientErrorToast.swift` modifier |

### D. settingsRowContent 拆分对其他设置行的影响

| 文件 | 改动 | 影响范围 |
|---|---|---|
| SettingsView.swift | 拆 `settingsRowContent(icon:title:showChevron:Bool=false)` view builder | NavigationLink 路径默认 showChevron:false（避免双 chevron）；现有 settingsRow 调 settingsRowContent(showChevron:true) 视觉无变化 |

**结论**：拆分对现有 Button 模式设置行视觉无侵入，未来其他 NavigationLink 设置项可直接复用同模式。

### 验收门
- [x] 代码位置与最新复用判断一致（A/B/C 三表）
- [x] 无需移位（B 检查 100% 一致）
- [x] 抽离判断遵循"第 3 处出现时抽"原则，未过早抽象（trial #1 教训）

**step 5 验收门通过**。

### 步骤完成时间
- 2026-06-25 — step 5 代码位置 review 落地

---

## step 6 — Retrospective（2026-06-25）

### A. 各验收门有效性逐项核对

> 规则：所有"否"的验收门要么删除、要么修改，不能原样保留。

| step | 验收门 | 本次有效？ | 决策 |
|---|---|---|---|
| 0 | spec 用户审字 | ✅ 有效 | 保留 |
| 0 | Plan agent 红队外审 27 条 | ✅ 高价值 | **保留 + 强化**：把"Plan agent 评审 spec"明示为 step 0 必经，trial #1 时是可选；本次 27 条全吸收避免了多数 step 3 反悔 |
| 1a | 单测全过 | ✅ 有效 | 保留 |
| 1a | 反向 → 单测对应表 | ✅ 高价值 | 保留；本次正是这表逼出 8 个不变量直测 |
| 1b | /restore-design 跳过/接入分流 | ✅ 有效 | 保留 |
| 1b | Preview 覆盖 spec 合法态 | ✅ 有效 | 保留 |
| 1b | Build SUCCEEDED | ✅ 有效 | 保留 |
| 1c | Fakes 异常 ↔ spec 反向 对应表 | ✅ **本次关键** | 保留 + 强化：本次新加 5 路 decode fallback 单测靠这表逼出来 |
| 1c | Codable decode 边界单测 | ✅ 高价值 | 保留 |
| 2 | spec 验收清单覆盖表（单测/Preview/真机 3 栏） | ✅ 有效 | 保留 |
| 3 | 真接口下 spec 验收清单全部通过 | ✅ 有效 | 保留 |
| 3 | 4 方向反悔分类 | ✅ 有效 | 保留——即使本次 0 反悔，这表的存在让用户验收时心理负担小（"反悔有归处"） |
| 4 | 用户真机签字 | ✅ 有效 | 保留 |
| 5 | 代码位置一致性检查 | ✅ 有效 | 保留 |
| 5 | "第 3 处出现时抽" | ✅ 有效 | 保留——本次再次验证此原则（LoadState 形态略不同，不强抽） |
| 6 | 验收门有效性核对 | ✅ 元 | 保留 |

**全部 ✅，无需删除/修改**。

### B. 应删 / 改 / 合 / 拆的步骤建议

| 项 | 当前 | 建议 | 理由 |
|---|---|---|---|
| step 3 + step 4 | 拆 2 步 | **可合并为一步「真集成 + 真机验收」** | 本次 trial 用户一次性签字通过，2 步实际拆分意义不大；但保留 4 方向反悔归类的 step 3 语义。建议改为「step 3 真集成（含真机验收）」 |
| step 1a + 1b + 1c | 拆 3 步 | **保持拆分** | 1a 决定 protocol、1b 决定 UI、1c 决定 decode 契约。trial #2 验证这 3 步关注点确实不同，不可合并 |
| step 5 + step 6 | 拆 2 步 | **保持拆分** | step 5 是"代码"维度自检，step 6 是"流水线"维度自检；混在一起会糊化思考层级 |

### C. .claude/rules/ 新增条目候选

trial #2 学到的「通用知识」，**0 反悔不代表无新沉淀** —— 反悔为零本身就是一个值得沉淀的方法论：

| 候选规则 | 主题 | 必要性 | 决策 |
|---|---|---|---|
| `feature-pipeline-step0-checklist.md` | spec 红队 27 条必做项类型化 | ⭐⭐ | ⏸ 暂不抽。trial #2 单点不足以归纳；trial #3 再看是否有类型化模式 |
| `swift-decode-five-path-fallback.md` | 5 路 decode fallback 通用模式 | ⭐ | ❌ 不抽。仅本里程碑用，第 3 处出现时再抽（与 step 5.C 一致） |
| `optimistic-update-with-generation-token.md` | 乐观更新 + 代际 token + 失败回滚 | ⭐⭐ | ⏸ 暂不抽。FollowList + Blocklist 2 处形态略不同，第 3 处再抽 |
| **`feature-pipeline-zero-revert-causes.md`** | **"反悔为零的潜在原因分析"作为流水线收尾自检** | ⭐⭐⭐ | ✅ **抽**——这是 trial #2 独特发现；trial #1 反悔 4 次时未触发，trial #2 0 反悔不代表"流水线无效"，要追"为什么这次零反悔"避免下次倒退 |

→ 本次抽 1 条：`.claude/rules/feature-pipeline-zero-revert-self-check.md`（见 D 节）

### D. 流水线本身反思

| 维度 | 评价 | 备注 |
|---|---|---|
| **价值高** | step 0 红队外审 27 条 | trial #2 把 trial #1 的 step 3 反悔 4 次大部分前移到 step 0 |
| **价值高** | step 1c Fakes 异常 ↔ spec 反向 对应表 | 5 路 decode fallback 单测就是这表逼出来的 |
| **价值中** | step 5 代码位置 review | 物理/语义一致性检查机械但有用；"第 3 处出现时抽"原则继续验证 |
| **价值低** | step 6 自身（元复盘） | 本次单 trial 沉淀价值边际递减；trial #3 后再看是否能改为"trial N 次后才做一次" |
| **失败/教训** | 无明显失败 | 但需警惕：0 反悔可能掩盖了某些边界态未触发（如分页 5 页之后、空号 + 飞行模式叠加），靠 logger 长期观察补 |
| **流程灵活度** | 适中 | trial #1 修订的"step 1b 无设计稿可跳过"分支本次未触发（有设计稿），但分支本身正确 |

### E. trial 化反思（trial #2 相较 trial #1）

| 维度 | trial #1 (Cycle 朋友圈) | trial #2 (黑名单) | 改进点 |
|---|---|---|---|
| step 3 反悔次数 | 4 | 0 | step 0 红队 + step 1c 5 路 decode 单测前置吸收了反悔 |
| step 0 红队意见数 | ? | 27 | trial #2 更彻底 |
| step 1a 单测数 | ? | 23 | 含 8 个不变量直测 |
| 真机验收一次过？ | 否 | 是 | ✅ |
| 沉淀 rules 数 | 1 (`async-state-fallback.md`) | 1 (`feature-pipeline-zero-revert-self-check.md`) | 持续沉淀 |

### F. 给下一里程碑（trial #3）的建议

1. **step 0 红队评审标准化**：把 27 条意见的分类（🔴 critical / 🟠 important / 🟡 nice-to-have / 🟢 minor）作为 spec 模板固定结构
2. **step 1c 提早**：可与 step 1a 并行（protocol 定义同时定 Codable models）
3. **0 反悔自检清单**：见 `feature-pipeline-zero-revert-self-check.md`
4. **流水线 retrospective 减负**：trial #3 step 6 可缩减为"差异表 + rules 沉淀"两节，跳过元复盘

### 验收门
- [x] 各验收门有效性逐项核对（A 节）
- [x] 应删 / 改 / 合 / 拆的步骤建议（B 节）
- [x] `.claude/rules/` 新增条目清单（C 节）
- [x] 流水线本身反思（D 节）+ trial 间对比（E 节）+ 下次建议（F 节）

**step 6 验收门通过**。

### 步骤完成时间
- 2026-06-25 — step 6 retrospective 完成 + 沉淀 1 条 rule

---

## 文档版本

| 时间 | 版本 |
|---|---|
| 2026-06-24 22:00 | v1 初稿，spec step 0 closed，step 1a 启动 |
| 2026-06-25 | v2 流水线全程通过：step 3 + 4 真机零反悔签字 / step 5 代码位置一致 / step 6 沉淀 1 条 rule |
