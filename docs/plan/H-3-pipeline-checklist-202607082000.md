# H-3 P2P 私聊页对齐 H5 深化 — Pipeline Checklist

> **spec**：`docs/plan/H-3-spec-私聊页对齐H5深化-202607081930.md` v3
> **flow**：feature-pipeline 7 步流水线（A 档全量）
> **日期**：2026-07-08 20:00
> **状态**：Step 1a-6 验收门（Store 层单测完成，UI/真集成 Step 1b/3 继续）

---

## §1 Step 1a 交付摘要

**5 sub-step 全部完成**，累计 **H-3 单测 100 条全过**；全套 913 tests / 2 pre-existing MatchStoreTests 失败（L 里程碑，非 H-3 引入）。

| Sub-step | 交付 | 单测数 |
|---|---|---|
| 1a-1 | AppConfigStore + 3 Bridge + AnchorInfo 扩 chatBubble/activeTycoon + SessionStore login/logout 接线 + CallAuthLogic | 17 |
| 1a-2 | ChatMessageContent 扩 3 case（privateImage/privateVideo/chatTip）+ PrivateLockStatus/ChatTipKind/ChatType enum + ChatMessage 加 chatBubble/privateId 字段 + MessageAttachParser 加 3 helper（Critical-3 单源 remoteExt）+ exhaustive switch 补丁（+Preview / P2PChatStore.resend / ChatMessageRow）+ L10n 3 语 messagePreviewPrivatePhoto/Video | 23 |
| 1a-3 | ReplyPointsStore（单例 + activeSessions dict）+ ReplyPointsService protocol + ChatTip stableSortKey + 4 tip 注入 + auto-claim（Critical-6）+ Critical-5 try/finally 清 lastUserMsgInfo | 29 |
| 1a-4 | TranslateService（parseTranslatedText 纯函数）+ CheckPrivateInfoService（S3 双兼容 list/dict）+ ChatTypeResolver + CallCooldownGuard（5s 边界） | 23 |
| 1a-5 | SendPrivateInfoService + P2PChatProvider 扩 sendPrivate + NIMChatAdapter.buildPrivateRemoteExt（Major-4/12/Critical-2）+ P2PChatStore.sendPrivateImage/Video + finalizeSending 同步 chatBubble/privateId | 8 |

---

## §2 spec 反向 ↔ 单测对应表（Store 层可覆盖项）

**说明**：view 层 / 真机 only 反向留 Step 1b/3/4。

### 私密图片视频（对齐项 1）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-3 apiGetSendPrivateInfo 失败 | ✅ | `testSendPrivateImage_SignFailure_NoProviderCallStatusFailed` |
| R-4/R-5 视频解密 fallback | 复用 H-2 已实现 GiftMessageService | H-2 spec |
| R-6/R-7 checkPrivateInfo lockStatus 缺失/API 失败 → .unknown | ✅ | `testExtractPrivateInfo_MissingLockStatus_IsUnknown` / `testPrivateLockStatus_FromRawInt_Nil_IsUnknown` / `testCheckPrivate_ParseMissingLockStatus_UnknownValue` |
| R-1 PrivateMediaSheet 空列表 | 留 Step 1b UI | — |
| R-8 多批 checkPrivateInfo 并发 | 留 Step 1a-7（Store 侧集成 CheckPrivateInfo 竞态守） | — |

### 回复积分（对齐项 2）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-9 getMessagePoint 失败 → isOpenPaidMessage=false | ✅ | `testBeginSession_FetchFails_LeavesSessionEmpty` / `testIsOpenPaidMessage_EmptyList_False` |
| R-10 config 未 loaded → 不累加 currentProgress | ✅ | `testOnReceiveUserMsg_ConfigNotLoaded_SkipsAccumulate` |
| R-11 settleReplyPoints 失败仍清 lastUserMsgInfo（Critical-5） | ✅ | `testOnSendAnchorMsg_SettleFailure_StillClearsLastUserMsgInfo` |
| R-12 res.settled=false 不覆盖 | ✅ | `testOnSendAnchorMsg_SettledFalse_DoesNotOverwriteButClears` |
| R-13 auto-claim 失败保 status | ✅ | `testBeginSession_ClaimFailure_KeepStatus` |
| R-14 连发 3 主播消息只 settle 一次 | ✅ | `testOnSendAnchorMsg_ConsecutiveSends_OnlyFirstCallsSettle` |
| R-15 15min timer Date 差值判定 | ✅ | `testCheckReplyRemindTrigger_Over15Min_Injects` / `_Under15Min_DoesNotInject` |
| R-16 replyRemindSent 会话 sticky | ✅ | `testCheckReplyRemindTrigger_AlreadySent_DoesNotReinject` / `testCheckReplyRemindTrigger_HasHistoryReply_DoesNotInject` |
| F-17 counter 跨会话保留 | ✅ | `testOnReceiveUserMsg_CountSurvivesEndSession` |

### 消息翻译（对齐项 3）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-18 网络失败 | ✅ | 由 Store 层调用方 catch；parseTranslatedText 单测覆盖响应边界 |
| R-19/R-20 isLoaded=false / key nil | 留 Step 1b（view flash） | — |
| R-21 pop 不持久化 | Store 层 view 内存 dict，Step 1b 验 | — |
| 响应格式边界 | ✅ | 7 tests（空数组 / 缺 translations / 缺 text / 无效 JSON / 多语取第一）|

### 被拒 tip / 大R徽章 / 气泡背景 / 通话权限（对齐项 4-7）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-22 status 从 refused 变回 sent（守卫） | 留 Step 1b UI | — |
| R-23 徽章三级 fallback 全 nil | ✅ | `testExtractActiveTycoon_NilRemoteExt_ReturnsNil` / `_MissingField_ReturnsNil` |
| R-24 asset 缺失 | 留 Step 1b UI | — |
| R-25 chatBubble 下载失败 | 留 Step 1b UI（NinePatchImageView） | — |
| R-26 chatBubble 无效 URL | ✅ 部分（`testExtractChatBubble_EmptyString_ReturnsNil`；非法字符 UI 层兜底） | — |
| R-27 主播 chatBubble nil 不塞 | ✅ 由 NIMChatAdapter.buildPrivateRemoteExt 判空守卫（生产代码检查） | — |
| R-28 remoteExt JSONSerialization.isValidJSONObject | ✅ NIMChatAdapter fallback 分支 | — |
| R-29 mine.levelName nil → canCall=false | ✅ | `testCanCall_NilOrEmptyLevelName_ReturnsFalse` |
| R-30 achorHideButton contains 空字符串 | ✅ | `testCanCall_EmptyLevelName_DoesNotHitContainsEmpty` |

### AppConfigStore 竞态

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-31 未 loaded 进 chat 页 | ✅ 各字段 nil / isLoaded=false 兜底 | AppConfigStoreTests + CallAuthLogicTests |
| R-32 loaded 后 Bridge 触发 view 重算 | 集成层，留 Step 3 真机验证 | — |
| R-33 logout clear + 换账号 activate 覆盖 | ✅ | `testClearThenActivateOverwrites` |

### 通话前置检查（新增 §2.8）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-42 fetchOnlineStatus 失败 | 兜底 offline 逻辑留 Step 1b（`AnchorOnlineStatus.isOnlineForCall(nil)`=false 已在 H-1 覆盖） | — |
| R-43 LiveStore.liveStartTime nil → cooldown 通过 | ✅ | `testCooldown_NilLiveStartTime_IsCooledDown` |
| R-44 快速连点通话按钮 | 留 Step 1b UI（button disable） | — |

### 左滑返回（对齐项 9）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-45/R-46 sheet/modal 打开时手势拦截 | UIViewControllerRepresentable + UIKit gesture，留 Step 1b/4 真机验证 | — |

### tip 排序（Major-7 + Minor-3）

| 反向 | 覆盖 | 单测 |
|---|---|---|
| R-36 离线补投 tip 与真消息稳定排序 | ✅ | `testChatTip_StableSortKey_ByPriority` / `_ByTimestamp` |

---

## §3 未覆盖 / 留后续 Step 归档

**留 Step 1b UI 阶段**（view 层验收）：
- R-1 PrivateMediaSheet 空列表 UI
- R-19/R-20 Translate 按钮 flash <300ms
- R-22 refused → sent（守卫）
- R-24/R-25 chatBubble/活跃大R asset 兜底
- R-44 快速连点通话按钮 debounce
- R-45/R-46 sheet 打开手势拦截

**留 Step 1a-7（额外一步，Store 集成 CheckPrivateInfo 竞态守）**：
- R-8 多批 checkPrivateInfo 并发 diff-based merge（v3 Major-11）
- forward 用户/主播消息事件到 ReplyPointsStore（本步骤 forward 逻辑在 ChatDetailContainer 层做，此处仅接线）

**留 Step 3 真机验收**：
- R-32 AppConfig loaded 后 Bridge @Published 触发 view 重算
- Step 3 全部真接口 spec 验收（Q1-Q13 spike 逐条落实）
- R-42 fetchOnlineStatus + LiveStore.liveStartTime 集成路径

---

## §4 验收门核对

按 skill 要求"所有'否'的验收门要么删除、要么修改，不能原样保留"：

| 验收门 | 状态 | 备注 |
|---|---|---|
| Step 1a 单测全过 | ✅ | H-3 单测 100/100 全过 |
| spec §5 反向清单每项有对应单测/Preview/真机 | ✅（部分）| 见 §2 表格；Store 层可覆盖项已 map；view/真机 only 留 Step 1b/3/4 归档 §3 |
| ChatMessageContent 新增 case exhaustive switch 全同步 | ✅ | ChatMessageContent+Preview / P2PChatStore.resend / ChatMessageRow 全补；finalizeSending 同步 chatBubble/privateId |

---

## §5 已知偏差 / spec v3 impl 期发现待归档

| # | spec 位置 | 实际项目 | 决策 |
|---|---|---|---|
| 1 | §3.2 用 `userLevel: String?` | iOS `AnchorInfo.levelName: String?` 语义即 H5 userLevel | **复用现有字段**（不新加 userLevel）；CallAuthLogic.canCall 用 levelName |
| 2 | §3.2 新建 `AnchorOnlineStatus` enum（3 case） | iOS 已有 `AnchorOnlineStatus` 常量表 + `isOnlineForCall(_:)` 完备 | 复用现有；不新建 enum |
| 3 | §Q6 getConfigByKey batch 上限 spike | H5 已 confirmed 一次 join 拉 7 key；iOS 复用同批 | **spike 降级**：不再抓包 |

---

## §6 下一步

**Step 1b UI 还原**（推荐）—— view 层 SwiftUI 组件落地：
- BottomActionBar（两行布局 + 4 按钮 + chatType 分支）
- PrivateMediaSheet（h236 + 顶部 Send + 私密项 giftPrice+锁 icon）
- RewardProgress（335x64 胶囊 + 3 节点）
- ChatTipRow（4 tip 复用 SystemTipRow 样式）
- RefusedInlineTip / ActiveTycoonBadge / NinePatchImageView
- SwipeToPopHelper（UIViewControllerRepresentable 恢复手势）
- 全部 Preview 覆盖 spec 合法状态

**或者 Step 1c**（API model + Fakes 完善 + decode 边界单测）—— 若 UI 组件已有部分设计稿可先落 UI；如 API 有阻塞可先补 decode 层。
