# F-1 · 派对房 PartyBattle PK 玩法 · Spec

> **版本**：v1 · 2026-07-14 18:08
> **里程碑**：F 派对房完整玩法 · F-1 PartyBattle PK 子项
> **档位**：A 档（feature-pipeline 全套 7 步）
> **前置文档**：`/Users/joe/.claude/plans/h5-party-pk-wondrous-cloud.md`（启动 plan，已批准）
> **蓝本**：H5 用户端 Battle Team（`livechat-h5/src/stores/modules/partyBattle.ts` 等）+ 安卓 `PartyBattleController.kt`（**归档缺主态细节，需用户查源码补齐**）

---

## §0 一图看全

### 0.1 决策 6 条
| # | 决策 | 落点 |
|---|---|---|
| 1 | 独立 PartyBattle 系统，不硬抽 PKHost 协议 | `Sources/Party/Battle/` |
| 2 | 主态 + 客态双角色（主播可作房主发起，也可去别人房观战/切队/上麦）| PartyBattleStore 无角色分支，UI 按 `store.canStartPk` 差异化 |
| 3 | RTC 不加多频道（同频道红蓝阵营）| `PartyRTCEngine` 保持不变；只加麦位↔阵营映射 |
| 4 | 接口走 bagshop 域 | `PartyAPIClient` (sapi 域，已就绪) |
| 5 | IM 主态契约按安卓 / 客态 payload 按 H5 用户端；首次真机 log 校对字段名 | `PartyBattleMessageRouter` |
| 6 | 分 3 milestone（F-1a 主态最小闭环 / F-1b 客态观战+观众能力 / F-1c 强制结束+审核+异常）| 每 milestone 1 周真机验收 |

### 0.2 不做项（明示边界）
- **F 里程碑其他子项** 全部不做：LuckyNumber / 半屏游戏 / 房币 / 麦时统计 / PartyCall 抢占 / 音乐播放
- **G 直播 PK 现有代码** 不 touch：`Sources/PK/*` / `Sources/Live/LiveRoomView.swift` PK 挂载 / `Sources/Agora/AgoraManager.joinPKOpposite` 全部保持
- **观众上麦 UI 独立入口** —— H5 用户端也未接入独立 UI，走现有派对房排麦复用（本次不做独立 applyMic UI）
- **PK 期与其他 F 期能力互斥**（PK 中切模板 / 加锁 / 变更 MC Seat）—— 因 F 其他子项本轮不做，暂无冲突；F-1c 若真机撞上则回退到"PK 中禁用"守卫

### 0.3 范围三圈（内圈直接做 / 中圈占位 / 外圈不做）
| 圈 | 内容 | 依据 |
|---|---|---|
| **内圈（本次做）** | PartyBattleStore 5 态状态机 · 10 个 REST 端点 · attachType 1100-1112 分发 · 10 个 Battle UI · PartyRoomView 布局改造 · 全局开关拉取 · 首次真机 IM payload 校对 | 本 spec 主体 |
| **中圈（占位）** | 埋点 `b_battle_team_start`（H5 已上报）· 神策自定义事件全项 —— 阶段 J 埋点里程碑统一收敛，本次留 `AppLogger` 骨架但**不**接入神策 SDK | J 里程碑范围 |
| **外圈（不做）** | 独立 applyMic UI · Battle 期与其他 F 子项互斥守卫 · pk-activity-h5 活动榜单页 · attachType 1104/1107/1108/1111（H5 未消费）| plan §"不做项" |

**preflight**（cross-scene-component-reuse-preflight）：本次涉及复用的已有 View：
- `PartyRoomView` — 自持 `PartyRoomChatManager` + `PartyStore` shared，是本次改造的**宿主 view** 而非"跨场景复用"，无 preflight 冲突
- `PartyRoomBigSeatCell` / `PartyRoomAudioSeatCell` — 麦位组件，本次要加 PK 期红蓝色边 + giftValueCount 替换逻辑，属**扩展现有组件**而非跨场景复用
- `CachedAsyncImage` / `AvatarView` — 公共组件，结算 MVP 卡直接复用（无 preflight 风险）

### 0.4 3 个真机 milestone
- **F-1a** 基建+主态最小闭环 · 房主发起 → SELECTING → RUNNING → ENDED → 冷却
- **F-1b** 客态观战 + 观众端能力 · 换账号进别人房 · 切队 · 观众上麦（复用现有排麦）· 送礼影响分数
- **F-1c** 强制结束 + 审核申请 + 异常路径

---

## §1 H5/安卓代码二次校验清单 · 【强制前置】

按 CLAUDE.md 铁律 + feature-pipeline skill 铁律，第一节必做。**信源码 > 信文档**。凡冲突以本节为准。

### 1.1 H5 用户端 partyBattle.ts 源码级校验（702 行）

| 校验项 | H5 源码结论 | 蓝本文档口径 | 冲突/差异 |
|---|---|---|---|
| status 5 态数值 | `1=SELECTING / 2=RUNNING / 3=ENDED / 4=FORCE_ENDED / 5=COOLDOWN`（`api/partyBattle/index.ts:61`）| plan §"状态机 5 态" | 无冲突 |
| **status 4 vs 5 归类** | 前端 `isEnded` getter 只匹配 `===3`，**未** 覆盖 4/5；4/5 分别是"强制结束"/"冷却"独立态 | plan 里 4=COOLDOWN / 5=FORCE_ENDED | **冲突！plan 写反了**。实际 4=FORCE_ENDED / 5=COOLDOWN，但**store getter 都不消费这两个数值**，仅靠 `showSettlement` 和 `cooldownLeftSec > 0` 派生显示 |
| cooldown 兜底优先级 | `settlement.cooldownLeftSec > store.cooldownDurationSec > COOLDOWN_SEC_FALLBACK(60)`（partyBattle.ts:22, 553-556）| plan 未指定 | 补齐 |
| 200ms 聚合语义 | trailing 而非 leading，**已有 flush 定时器时不重置**（partyBattle.ts:472-473）—— 首条设 200ms 后 flush，中间到的合并 payload 字段，200ms 到集中 commit | plan §"200ms trailing 聚合" | 补齐语义细节 |
| cooldown ticker 生命周期 | **模块作用域** `let cooldownTimer`（partyBattle.ts:28），不是 store state，独立 View 生命周期；重复调用安全 | plan §"cooldown 独立 ticker" | 一致 |
| **onSelectingStart 副作用** | **侵入外部 partyStore 清麦位 `giftValueCount = 0`**（partyBattle.ts:335-351）；只清红蓝队参战 uid，中立位不清 | **plan 未提** | **补 spec §3.4.1，iOS 必须显式实现同款外部 side effect** |
| onTeamMemberChange preservePersonal | payload 中 personalScore/personalGems 缺失时 **按 uid 从旧 members 回填**（partyBattle.ts:366-385）；payload 带值优先（`if (merged.personalScore == null)`）| plan §"personalScore 按 uid 回填" | 补齐"payload 带值优先"细节 |
| onEnd 分类字段 | `isFullSettlement = settlement && typeof settlement.durationSec === 'number'`（partyBattle.ts:552）—— IM 1109 stub 无 durationSec，API settlement 必有 | plan 未指定 | 补齐 |
| onEnd 本地路径 | `onEnd(null)` 不触发 fetchSettlement，只写冷却兜底；由 tickLeft 归零单独调 fetchSettlement（partyBattle.ts:570）| plan 未指定 | 补齐（防重复请求）|
| fetchSettlement 错误处理 | **静默 return null**（无 trackLog，partyBattle.ts:612-614）| plan §"错误处理" | 补齐 |
| **tickLeft 是纯 store action** | 不是 useIntervalFn；由外部 view 用 setInterval / useIntervalFn 每秒调（partyBattle.ts:616 前无 setInterval 挂载）| plan §"tickLeft" | iOS 侧对应"View 层 `.onReceive(Timer.publish(every:1))` 调 store.tickLeft()" |
| tickLeft SELECTING 归零 | 只传 `{durationSec: this.durationSec}`（partyBattle.ts:621），走 onRunningStart 里 `state 已存在` 分支只 set status=2 + leftSec | plan 未指定 | 补齐 |
| tickLeft RUNNING 归零 | 三步：`onEnd(null)` → `refresh(roomId)` → `fetchSettlement().then(覆盖 cooldownLeftSec)`（partyBattle.ts:623-644）| plan 未指定 | 补齐完整链路 |
| **1103 vs tickLeft SELECTING 归零 race** | 本地先 `onRunningStart({durationSec})` → 神策上报；后端 1103 到 → `onRunningStart(payload)` → **神策再次上报 b_battle_team_start**。H5 未去重 | plan 未提 | **iOS 侧 spec §7.3 讨论：是否加 pkId+status 去重 or 沿用 H5 双上报** |
| gems fallback getter | 红蓝**同时** `!= null` 才用 gems；否则一起回落 raw score；`Number()` 兜底（partyBattle.ts:84-98）| plan §"gems vs score 双口径" | 一致 |
| gems 类型 | `number \| string`（Long/BigDecimal 序列化）—— iOS 侧 Codable 必须双兼容 | plan 未提 | **spec §4.3 明示 iOS Codable 用 StringOrDouble 自定义 wrapper** |
| **state.roomId=0 占位** | onInitiateSuccess 时 `state.roomId=0`（partyBattle.ts:135），其他 action 需 `partyStore.currentPartyInfo.id` 兜底（`state.roomId > 0 ? state.roomId : fallbackId`）| plan 未提 | **spec §4.2 明示 iOS PartyBattleStore 用 `PartyStore.shared.roomInfo?.id` 兜底** |
| reset 清理 | 14 字段清理 + 2 字段跨场保留（`cooldownDurationSec / totalSwitch`），含 leaderboard 定时器（partyBattle.ts:680-700）| plan 未指定 | 补齐完整 checklist |
| 埋点 | 仅 `onRunningStart` 上报 `b_battle_team_start`（partyBattle.ts:438-446），其他 action 无 sensors track | plan 未提 | spec §11 埋点占位 |

### 1.2 H5 IM 双路由校验

| 校验项 | 源码结论 | 冲突/差异 |
|---|---|---|
| 主路由 payload 形态 | **扁平**：`ext = { attachType: 11xx, data: <payload> }`（party.js:507-509）| 一致 |
| 兜底路由 payload 形态 | **嵌套**：`customParser.data = { type: 11xx, payload: <payload>, pkId }`（session.js:680-692）| 差异 |
| 兜底路由触发条件 | 只在 `mainBusinessType ∈ {FULL_PARTY, SMALL_PARTY}`；Party 房内 chatroom 实例已被 `usePartyHooks.registerChatroomListeners` 挂 party 主监听，兜底几乎不触发 | 关键：实际生产 100% 走主路由 |
| 1110 兜底路由不处理 | party.js 有（按 kind 分公屏），session.js 无 | 补齐 |
| 主路由 default 分支 | `console.warn('[partyBattle] unhandled innerType in party route', innerType)`（party.js:579-581）| iOS 侧对应 AppLogger warning |
| 未覆盖 attachType | 1104 / 1107 / 1108 / 1111 主路由/兜底路由均无 case | iOS enum 保留占位 + fallback log |
| **1105 payload 无 Top3** | 需要 refresh /state 补拉 Top3（partyBattle.ts:508-512）| **spec §5 明示 iOS 端 1105 处理必须触发 refresh** |
| 1102 pushApply 内部不读 pkId | payload 无 pkId 也 OK（兜底路由拼 pkId 无副作用）| 补齐 |
| 1112 无 payload | party.js / session.js 都是无参调用 `onCooldownEnd()` | 一致 |

### 1.3 iOS 侧现有基建校验

| 校验项 | iOS 现状 | F-1 是否新增 |
|---|---|---|
| sapi 域客户端 | `PartyAPIClient.shared.post(path:body:)` 支持 sapi 域 | 无 |
| BAGSHOP_TOKEN 24h 自动交换 | `SapiTokenStore` 已完整实现 + 401 auto-retry | 无 |
| AES 加解密 (sapi 独立 key/iv) | `CryptoUtil` 参数化 + `AppConfig.sapiAesKey/IV` | 无 |
| 权限判定 `selfRole` | `store.selfRole == .owner / .admin / .audience` 已就绪 | 无 |
| roomTempId Int 兜底 | `store.roomInfo?.roomTempIdInt` 已就绪 | 无 |
| 全局开关拉取 | `AppConfigService.fetch(keys:)` → `/api/index/getConfigByKey` | 无 |
| **battle 端点 (10 个)** | 全无 | **F-1 新增** |
| **battle Codable 模型** | 全无 | **F-1 新增** |
| **PartyBattleStore + Router** | 全无 | **F-1 新增** |
| **10 个 Battle UI** | 全无 | **F-1 新增** |
| `PartyAttachType` 1100-1112 case | 全在降噪表（`PartyKnownButUnhandledAttachType.codes`）| **F-1 移出降噪表 + 增补 case** |
| **`PartyRoomView.handlePkTap` / `toolMenu.startPk`** | 空日志 TODO 占位（`:259` / `:1133`）| **F-1 wire 到 store** |
| `isPlatformAdmin` 独立 getter | 折进 `.admin`，`PartyRoomToolsSheet.swift:31` wire 未接通 | **F-1 内部不需要独立 getter**（`.admin` 语义已涵盖）；如未来需要分流再抽 |

### 1.4 安卓 PartyBattleController 校验 —— 归档缺失

**归档 `docs/plan/安卓主播端梳理/02-04-派对房.md` 只有 1 句话引用**（`第 58 行 "PartyBattleController/Manager + battle/*"`），无主态字段/接口/枚举/错误码细节。以下 8 项需**用户去安卓源码补齐**（写在 §12 待用户确认清单）：

- A1 谁能发起 PK 的具体判定
- A2 approveApply 返回 payload + 拒绝时是否触发 IM 通知
- A3 applications 接口分页语义
- A4 startNow 权限校验后端错误码
- A5 forceEnd 冷却语义（endedEarly 字段的作用）
- A6 1102 到达时接收范围
- A7 1101 触发时机（SELECTING vs RUNNING）
- A8 spec §12 全部 iOS 需要的安卓特有决策点

### 1.5 死代码/废弃字段排查

- H5 `state.status=4/5` 仅在 API `/state` 响应 raw 中存在，前端 getter 不消费 → **iOS 侧保留 raw enum 值定义，但状态机迁移图不含 4/5 作为独立态**（用 `showSettlement` + `cooldownLeftSec > 0` 派生显示）
- H5 `onLeaderboardUpdate` 老版 `team + teamScore` 兼容（partyBattle.ts:466-469）—— **iOS 侧保留兼容分支**（灰度期后端可能双版本并存）
- H5 `apiPartyBattleSwitchTeam` / `apiPartyBattleApplyMic` **接口存在但 UI 未接入**（H5 用户端未做独立 UI）—— **iOS 侧同步暂不接**，走 `apiPartyBattle{Start,ForceEnd,Settlement,Applications,ApproveApply,StartNow,State,Templates}` 8 个即可
- attachType `1104/1107/1108/1111` H5 主/兜底路由均无 case —— **iOS 侧 enum 保留 case + `.unhandled` fallback log**

---

## §2 业务概念词表

**不锁 protocol 名，仅业务语义**（对齐 feature-pipeline §Step 0）。

| 中文词 | 业务语义 | 对应 H5 字段 |
|---|---|---|
| PK 场（一场对战）| 从发起到结算的完整业务周期 | `pkId` |
| 选队阶段 | 房主发起后进入的选边窗口，60s 内可自由切队；房主可"立即开战"跳过 | `status=1` SELECTING |
| 对战阶段 | 分数累积、皇冠竞争、送礼影响分数 | `status=2` RUNNING |
| 结算阶段 | 展示胜方 / VS 大比分 / 送礼 MVP / 收礼 MVP | 由 `showSettlement=true` 表征，非 status 独立态 |
| 冷却阶段 | 结算完成后禁止重开 PK 的窗口（默认 60s，模板可配）| `cooldownLeftSec > 0` |
| 强制结束 | 房主/房管在 RUNNING 中主动结束；结算 `endedEarly=true` | `forceEnd` action |
| 皇冠持有者 | 每队送礼最多的用户，麦位显示皇冠 icon | `redCrownUid` / `blueCrownUid` |
| 团队成员 | 参战麦位用户（红蓝任一）+ 中立观众 | `redTeam.members` / `blueTeam.members` / `neutral.members` |
| 个人分数 (raw) | 用户在 PK 中收到的原始钻石数 | `personalScore` |
| 个人分数 (折算) | 按后台配置折算后的展示口径 gems | `personalGems` |
| 团队总分 (raw) | 队伍原始钻石累积 | `redScore` / `blueScore` |
| 团队总分 (折算) | 队伍折算 gems 累积（进度条/胜负判定优先用）| `redGems` / `blueGems` |
| 上麦申请 | 观众请求上麦并选边（H5 未做独立 UI，走现有排麦复用）| `applications` |
| 全局功能开关 | 后台 sys_config 配的"PK 功能是否启用" | `totalSwitch = 0/1` |
| 房型门槛 | 只有 `roomTempId=1`（三视频模板）的房间可发起 PK | `roomTempIdInt == 1` |
| PK 权限门槛 | 只有房主/房管/平台管理员可发起 PK | `selfRole == .owner \|\| .admin` |
| 阵营映射 | 红队 slot 0-4 → 麦位 4-8 · 蓝队 slot 0-4 → 麦位 9-13 | `buildTeamSlots` |

---

## §3 状态机 spec

### 3.1 主状态机（PartyBattleStore.status）

**枚举定义**：
```swift
enum PartyBattleStatus: Int, Codable {
    case selecting = 1
    case running   = 2
    case ended     = 3
    case forceEnded = 4   // 后端下发但前端 getter 不消费；iOS 保留 raw 值，UI 判定走 showSettlement
    case cooldown  = 5    // 同上；UI 判定走 cooldownLeftSec > 0
}
```

**iOS 派生 getter**：
```swift
var isSelecting: Bool  { state?.status == .selecting }
var isRunning: Bool    { state?.status == .running }
var isEnded: Bool      { state?.status == .ended }
var isCoolingDown: Bool { cooldownLeftSec > 0 }
var isFunctionEnabled: Bool { totalSwitch == 1 }
```

### 3.2 状态迁移图

```
                ┌─────────── loadGlobalConfig ────────────┐
                │                                          │
                ▼                                          │
              [idle]                                       │
              (state=nil,                                  │
               totalSwitch loaded)                         │
                │                                          │
     ┌──────────┼───────────────┬──────────────┐         │
     │          │               │              │          │
房主 startPK   IM 1100        refresh /state  refresh /state
 (主态)        (客态)          发现 status=1   发现 status=4/5
     │          │               │              │          │
     ▼          ▼               ▼              ▼          │
 onInitiate  onSelectingStart  onSelecting   直接进      │
 Success                       Start          冷却或结算  │
     │          │               │              │          │
     └──────┬───┴───────┬───────┘              │          │
            │           │                      │          │
            ▼           ▼                      ▼          │
        [selecting] leftSec 秒级递减    [showSettlement]  │
            │                          + cooldownLeftSec  │
            │  IM 1103 / tickLeft 归零      > 0           │
            │  / startNow                                 │
            ▼                                             │
        [running]  leftSec 秒级递减                      │
            │                                             │
            │  IM 1105/1106 分数/皇冠更新                 │
            │                                             │
            │  IM 1109 stub / tickLeft 归零 / forceEnd    │
            ▼                                             │
        onEnd(stub | full | null)                        │
            │                                             │
            ▼                                             │
        [ended] + showSettlement=true                    │
        + cooldownLeftSec > 0                            │
        + startCooldownTicker                            │
            │                                             │
            │  cooldownLeftSec 秒级递减                   │
            │  IM 1112 / ticker 归零                      │
            ▼                                             │
        onCooldownEnd → cooldownLeftSec=0 + stopTicker   │
            │                                             │
            └────── 可重新发起 ──────────────────────────┘
```

### 3.3 5 态非法迁移守卫

| From \ To | selecting | running | ended | forceEnded | cooldown | idle |
|---|---|---|---|---|---|---|
| idle | ✅ (onSelectingStart / onInitiateSuccess) | ✅ (客态直接进 RUNNING 房 / refresh) | ✅ (刷 /state 时已结束) | ✅ | ✅ | — |
| selecting | ↔ (只允许 setStatus 校验) | ✅ (onRunningStart / tickLeft) | ✅ (forceEnd 从 selecting？H5 未验证，spec §12 待确认) | 同上 | ❌ (直接跳过 running 到 cooldown 非法) | ❌ |
| running | ❌ (不允许倒退) | ↔ | ✅ (onEnd) | ✅ | ❌ (先结算再冷却) | ❌ |
| ended | ❌ | ❌ | ↔ | ❌ (不能从自然结束改为强制)| ✅ (自然进入冷却)| ✅ (onCooldownEnd 后重发) |
| forceEnded | ❌ | ❌ | ❌ (endedEarly=true 已区分) | ↔ | ✅ | ✅ |
| cooldown | ✅ (重开一场 PK) | ❌ | ❌ | ❌ | ↔ | ✅ (onCooldownEnd) |

**非法迁移**：AppLogger.party.error + 不 apply + trackLog（sink 到未来埋点里程碑）。

### 3.4 关键副作用清单

#### 3.4.1 onSelectingStart 侵入外部 PartyStore（**必做**）

```
IM 1100 → onSelectingStart(payload)
  1. self._resetForNewBattle()  // 清 lastSettlement / showSettlement / applications / cooldown / forceEnding
  2. 更新 self.state = {...payload, status=1, redScore=0, blueScore=0, redGems=0, blueGems=0, redTop=[], ...}
  3. **侵入 PartyStore.shared**：遍历 partyStore.seatList，将 seat.userId 命中
     (redTeam.members ∪ blueTeam.members).uids 的 seat.giftValueCount = 0
     ⚠️ 中立位不清；只清参战麦位
```

**iOS 实现**：
```swift
@MainActor
func onSelectingStart(_ payload: BattleSelectingStartPayload) async {
    _resetForNewBattle()
    // 构造 state（略）
    // 侵入清麦位
    let battlingUids = Set(
        (payload.redTeam?.members ?? [])
            .compactMap { $0.uid }
        + (payload.blueTeam?.members ?? [])
            .compactMap { $0.uid }
    )
    PartyStore.shared.clearGiftValueCount(uids: battlingUids)  // 新增 API
}
```

#### 3.4.2 onTeamMemberChange preservePersonal

```
IM 1101 → onTeamMemberChange(payload)
  对 payload 的 redTeam.members / blueTeam.members / neutral.members 三个数组各自：
  - 若数组存在（`payload.xxxTeam != nil`）
  - 构建 oldMap: [String(uid): oldMember] 从 self.state.xxxTeam.members
  - 新数组每个 member.personalScore == nil ? oldMap[uid].personalScore ?? 0 : payload 值
  - 新数组每个 member.personalGems 同理
  - self.state.xxxTeam.members = 新数组
```

**iOS 关键**：uid 类型统一（后端 Long 序列化可能是 Int64 或 String） —— **Codable 定义时用 String 统一** + `stringUid = String(uid)` 兜底比较。

#### 3.4.3 tickLeft 三段路径

```swift
@MainActor
func tickLeft() {
    guard leftSec > 0 else { return }
    leftSec -= 1
    guard leftSec == 0 else { return }
    switch state?.status {
    case .selecting:
        // SELECTING 归零 → 本地兜底进 RUNNING
        onRunningStart(BattleRunningStartPayload(durationSec: durationSec))
    case .running:
        // RUNNING 归零 → 三步
        onEnd(nil)              // 1. 本地切 ended + cooldown 兜底 + showSettlement=true
        let rid = state?.roomId ?? 0 > 0 ? state!.roomId : (PartyStore.shared.roomInfo?.id ?? 0)
        if rid > 0 {
            Task { try? await refresh(roomId: rid) }
        }
        Task {
            if let s = try? await fetchSettlement() {
                let cd = s.cooldownLeftSec
                if cd > 0 { self.cooldownLeftSec = cd }
            }
        }
    default:
        break
    }
}
```

**调用点**（View 层）：
```swift
// PartyBattleHUDContainer.swift（新增）
.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
    guard store.isSelecting || store.isRunning else { return }
    store.tickLeft()
}
```

#### 3.4.4 200ms trailing 聚合（1105）

```swift
private var pendingLeaderboardPayload: BattleLeaderboardMerged?
private var leaderboardFlushTask: Task<Void, Never>?
private let LEADERBOARD_AGGREGATE_MS = 200

@MainActor
func onLeaderboardUpdate(_ payload: BattleLeaderboardPayload) {
    if pendingLeaderboardPayload == nil {
        pendingLeaderboardPayload = BattleLeaderboardMerged()
    }
    // 字段级合并到 pending
    if let rs = payload.redScore { pendingLeaderboardPayload!.redScore = rs }
    if let bs = payload.blueScore { pendingLeaderboardPayload!.blueScore = bs }
    if let rg = payload.redGems { pendingLeaderboardPayload!.redGems = rg }
    if let bg = payload.blueGems { pendingLeaderboardPayload!.blueGems = bg }
    // 老版兼容
    if payload.team == 1, let ts = payload.teamScore { pendingLeaderboardPayload!.redScore = ts }
    else if payload.team == 2, let ts = payload.teamScore { pendingLeaderboardPayload!.blueScore = ts }

    // 已有 flush task 时不重置
    guard leaderboardFlushTask == nil else { return }
    leaderboardFlushTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(LEADERBOARD_AGGREGATE_MS) * 1_000_000)
        let merged = pendingLeaderboardPayload
        pendingLeaderboardPayload = nil
        leaderboardFlushTask = nil
        if let m = merged { applyLeaderboardUpdate(m) }
    }
}
```

**边界**：`reset()` 时 `leaderboardFlushTask?.cancel()` + `pendingLeaderboardPayload = nil`。

#### 3.4.5 cooldown ticker

```swift
private var cooldownTimer: Timer?

@MainActor
func startCooldownTicker() {
    guard cooldownTimer == nil else { return }
    guard cooldownLeftSec > 0 else { return }
    cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in
            guard let self else { return }
            if self.cooldownLeftSec > 0 { self.cooldownLeftSec -= 1 }
            if self.cooldownLeftSec <= 0 { self.stopCooldownTicker() }
        }
    }
}

func stopCooldownTicker() {
    cooldownTimer?.invalidate()
    cooldownTimer = nil
}
```

**关键**：Timer 属于 store 级属性，独立 View 生命周期。

### 3.5 全局开关 loadGlobalConfig

- **API**: `AppConfigService.fetch(keys: ["party_room_battle_config"])`
- **格式**: 后端 sys_config 表返 Java Map.toString 风格 string（如 `{totalSwitch=1, ...}`），非标准 JSON
- **兜底解析**：iOS 侧新增 `PartyBattleGlobalConfigParser`（正则解析 `totalSwitch=(0|1)` + 其他键 key=value）
- **默认值**: `totalSwitch = 1`（避免入口闪烁）
- **触发时机**: `PartyStore` 进房 (`enterRoom` 成功) 后一次调用；跨房间保留

---

## §4 数据模型 spec

### 4.1 主 state 结构

```swift
// PartyBattleModels.swift

struct PartyBattleState: Codable, Equatable {
    var pkId: String
    var battleId: Int
    var roomId: Int64                 // 后端 Long，可能是占位 0
    var status: PartyBattleStatus     // 1-5
    var templateId: Int?
    var templateName: String?
    var selectingDurationSec: Int
    var durationSec: Int
    var leftSec: Int
    var hostUid: Int64
    var hostRole: Int                 // 1 / 2
    var currentUserTeam: Int?         // 1=红 2=蓝 3=中立 nil=未站队
    var redTeam: BattleTeam
    var blueTeam: BattleTeam
    var neutral: BattleTeam
    var redTop: [BattleTopMember]
    var blueTop: [BattleTopMember]
    var redCrownUid: Int64?
    var blueCrownUid: Int64?
    var redScore: DoubleOrString      // 可能是 String（Long/BigDecimal 序列化）
    var blueScore: DoubleOrString
    var redGems: DoubleOrString?
    var blueGems: DoubleOrString?
    var winnerTeam: Int?              // 1/2/3
    var cooldownLeftSec: Int
    // 其他字段按需
}

struct BattleTeam: Codable, Equatable {
    var count: Int
    var members: [BattleMember]
}

struct BattleMember: Codable, Equatable, Identifiable {
    var id: String { String(uid) }
    let uid: Int64                    // ⚠️ Codable 需支持 String/Int64 双兼容
    let nickname: String?
    let avatar: String?
    var personalScore: DoubleOrString?
    var personalGems: DoubleOrString?
    var isCrownHolder: Bool?
}

struct BattleTopMember: Codable, Equatable {
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let contribution: DoubleOrString?
}
```

### 4.2 store 顶层字段（vs H5 partyBattle.ts state 一致）

```swift
@MainActor
final class PartyBattleStore: ObservableObject {
    static let shared = PartyBattleStore()

    @Published private(set) var state: PartyBattleState?
    @Published private(set) var pkId: String = ""
    @Published private(set) var selectingDurationSec: Int = 0
    @Published private(set) var durationSec: Int = 0
    @Published private(set) var leftSec: Int = 0
    @Published private(set) var templateName: String = ""
    @Published private(set) var cooldownLeftSec: Int = 0
    @Published private(set) var cooldownDurationSec: Int = 60   // COOLDOWN_SEC_FALLBACK
    @Published private(set) var lastSettlement: PartyBattleSettlementResp?
    @Published private(set) var showSettlement: Bool = false
    @Published private(set) var forceEnding: Bool = false
    @Published private(set) var applications: [PartyBattleApplication] = []
    @Published private(set) var totalSwitch: Int = 1

    // module-scope 等价（module 就是 store 单例）
    private var cooldownTimer: Timer?
    private var pendingLeaderboardPayload: BattleLeaderboardMerged?
    private var leaderboardFlushTask: Task<Void, Never>?
}
```

**关键坑**：`state.roomId` onInitiate 时为 0 占位 → **所有 action 访问 roomId 时都用 fallback**：`state?.roomId ?? 0 > 0 ? state!.roomId : (PartyStore.shared.roomInfo?.id ?? 0)`。iOS 端**新增 PartyBattleStore.effectiveRoomId 派生 getter** 集中化。

### 4.3 DoubleOrString wrapper（关键）

后端 Long / BigDecimal 序列化 iOS 端 Codable 需支持 String/Int/Double 三兼容。

```swift
enum DoubleOrString: Codable, Equatable {
    case double(Double)
    case string(String)
    case none

    var doubleValue: Double {
        switch self {
        case .double(let d): return d
        case .string(let s): return Double(s) ?? 0
        case .none: return 0
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let i = try? c.decode(Int64.self) { self = .double(Double(i)); return }
        if let s = try? c.decode(String.self), !s.isEmpty {
            self = .string(s); return
        }
        self = .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .none: try c.encodeNil()
        }
    }
}
```

**gems fallback getter iOS 版**（对应 partyBattle.ts:84-98）：
```swift
extension PartyBattleStore {
    var redScoreDisplay: Double {
        let bothGems = state?.redGems != nil && state?.blueGems != nil
        return bothGems ? (state?.redGems?.doubleValue ?? 0)
                       : (state?.redScore.doubleValue ?? 0)
    }
    var blueScoreDisplay: Double {
        let bothGems = state?.redGems != nil && state?.blueGems != nil
        return bothGems ? (state?.blueGems?.doubleValue ?? 0)
                       : (state?.blueScore.doubleValue ?? 0)
    }
}
```

### 4.4 uid 类型策略

**问题**：H5 `state.redTeam.members[].uid` 可能是 Int / String（Long 序列化差异）；PartyRoomSeat.userId 是 String。

**iOS 决策**：
- Codable model 内 `uid: Int64`（用 `Int64OrString` 自定义 wrapper decode）
- 内部比较统一转 String（`String(uid)`）
- 与 PartyRoomSeat.userId 比较：`seat.userId == String(member.uid)`

对齐 `.claude/rules/ios-decode-userid-compat.md` 铁律。

### 4.5 API 请求/响应模型（10 个端点）

见附录 D（因篇幅原因单独列）。核心：

- **每个请求**：`Encodable` 结构体（roomId / pkId 用 String 传，防精度）
- **每个响应**：包在 `PartyAPIClient` envelope 里，`result` 字段是加密 hex，自动解密后 `Decodable`
- **响应可 nil**（`apiPartyBattleStart` / `apiPartyBattleState` 类型显式 `| null`）—— Swift 端 `Optional<...>`

### 4.6 IM Payload 模型（12 个 attachType）

见附录 E。所有 payload 支持**扁平形态**（`ext.data.xxx`），首次真机 log 抓 dataKeys 校对字段名。如出现嵌套形态（`ext.data.payload.xxx`）→ Router 补 fallback 分支。

---

## §5 事件路由 spec

### 5.1 attachType 1100-1112 → action 映射

| Raw | 常量 | Router 分发到 | payload 特殊处理 |
|---|---|---|---|
| 1100 | `.battleSelectingStart` | `store.onSelectingStart(payload)` + 公屏 `msgType='battleSelecting'` | 走扁平 payload |
| 1101 | `.battleTeamMemberChange` | `store.onTeamMemberChange(payload)` | payload 无 personalScore，store 内 preservePersonal 回填 |
| 1102 | `.battleApplyReceived` | `store.pushApply(payload)`（观众也收到但无 UI 入口）| — |
| 1103 | `.battleRunningStart` | `store.onRunningStart(payload)` | — |
| 1104 | `.battleReserved1104` | `AppLogger.party.warning("unhandled 1104")` | 保留占位 |
| 1105 | `.battleLeaderboardUpdate` | `store.onLeaderboardUpdate(payload)` | 200ms 聚合入口 |
| 1106 | `.battleCrownHolderUpdate` | `store.onCrownHolderUpdate(payload)` | — |
| 1107 | `.battleReserved1107` | `AppLogger.party.warning("unhandled 1107")` | 保留占位；疑似"申请状态变更"|
| 1108 | `.battleReserved1108` | `AppLogger.party.warning("unhandled 1108")` | 保留占位 |
| 1109 | `.battleEnd` | `store.onEnd(payload)` | payload 分 stub / full（durationSec 是否存在判定）|
| 1110 | `.battleBroadcast` | 走公屏 `addPartyChatRecordsMsg` 按 kind 分发 | `victory / force_ended / mvp` 各带字段；`selecting_started` 忽略 |
| 1111 | `.battleReserved1111` | `AppLogger.party.warning("unhandled 1111")` | 保留占位 |
| 1112 | `.battleCooldownEnd` | `store.onCooldownEnd()` | 无 payload |

### 5.2 Router 位置

**新增 `Sources/Party/Battle/Router/PartyBattleMessageRouter.swift`**，被现有 `PartyMessageRouter` 内部调用：

```swift
// Sources/Party/NIM/PartyMessageRouter.swift（修改）
static func route(attachType: PartyAttachType, payload: [String: Any]) {
    switch attachType {
    // ... 现有 case
    case .battleSelectingStart, .battleTeamMemberChange, .battleApplyReceived,
         .battleRunningStart, .battleLeaderboardUpdate, .battleCrownHolderUpdate,
         .battleEnd, .battleBroadcast, .battleCooldownEnd,
         .battleReserved1104, .battleReserved1107, .battleReserved1108, .battleReserved1111:
        PartyBattleMessageRouter.dispatch(attachType: attachType, payload: payload)
    }
}
```

### 5.3 首次真机 log 校对

按 `.claude/rules/im-payload-real-log-over-code-assumption.md` 铁律，F-1 实施时首次开 PK **必须抓一次真机 log** 校对 3 点：
1. `attachType` 数值命中 case
2. `dataKeys` 与 spec §5 payload 定义一致（gap 用 CodingKey 别名兜底）
3. `scopeId` = `PartyRoomChatManager.currentChatroomId`（用于 Center enqueue 场景一致性）

**建议在 `PartyBattleMessageRouter.dispatch` 起始处一次性 log**（不加 verbose 开关，一次真机接入后可删）：
```swift
AppLogger.party.info("[battle] recv attachType=\(attachType.rawValue) dataKeys=\(payload.keys.sorted().joined(separator: ",")) scopeId=\(scopeId)")
```

---

## §6 UI spec

### 6.1 新增 10 个 SwiftUI 组件

| 组件 | 触发 | 依赖 store getter | 关键交互 |
|---|---|---|---|
| **PartyBattleInitiatePopup** | 房主/房管点 startPk 入口，非 running 非 cooldown | `store.templates` (from apiPartyBattleTemplates) | 模板 chip 单选 + 时长 3/5/10 chip 单选 + 站队 R/B/N toggle + Confirm → apiPartyBattleStart |
| **PartyBattleSelectingPanel** | `store.isSelecting` 时挂在 PartyRoomView 顶部 overlay | `store.leftSec / redScore / blueScore` | mm:ss 倒计时 + 顶部血条（红蓝渐变，clamp 20-80%）|
| **PartyBattleSelectingStartStrip** | `store.isSelecting && store.canManage` 时挂底部 overlay | `store.leftSec / canManage` | 房主看 "Start 47s" 按钮 → apiPartyBattleStartNow；观众看倒计时 |
| **PartyBattleRunningHud** | `store.isRunning` 时挂 PartyRoomView 顶部 overlay | `store.redScoreDisplay / blueScoreDisplay / leftSec / redCrownUid / blueCrownUid / currentUserTeam` | 红蓝头像 + 分数 K/M 格式化 + 领先方 tag + clamp(20,80) 进度条 + 倒计时 |
| **PartyBattleHostBottomMarquee** | `store.isRunning` 时挂底部 overlay | `store.state?.redTop / blueTop` | 红蓝各 Top3 头像 grid + Padding + 队伍色边框 |
| **PartyBattleEndedSettlement** | `store.showSettlement == true` 时 sheet 弹出 | `store.lastSettlement` | Win Team 大文字 + Battle Time + VS 大比分 + 送礼 MVP 卡 + 收礼 MVP 卡 + 关闭 + Rules 入口；endedEarly=true 显示 "Force Ended" 副标题 |
| **PartyBattleForceEndConfirm** | 房主点入口时 `store.isRunning` 触发 | `store.forceEnding` | 二次确认文案 + Confirm → `store.forceEnd()` |
| **PartyBattleCooldownToast** | 房主点入口时 `store.isCoolingDown` 触发 | `store.cooldownLeftSec` | 显示"冷却 XXs 后可重开" toast（2s 自清）|
| **PartyBattleRulesPopup** | `?` 按钮 tap | 无 | 规则弹窗（内容 Localizable，首版可硬编码占位）|
| **PartyBattleGiftPanelTabs** | 送礼面板打开且 `store.isSelecting \|\| store.isRunning` | `store.state?.redTeam / blueTeam` | 红蓝 Tab 切换 → 礼物面板目标麦位切换（复用现有礼物送礼链路）|

**preflight**（sf-symbol-usage-preflight）：本次涉及 icon 建议用工程已用的：`crown.fill` / `bolt.fill` / `flame.fill` / `xmark` / `clock` — 均为高置信度 SF Symbol。新增未验证 icon 需 SF Symbols.app 验证。

### 6.2 PartyRoomView 布局改造

**入口 wire**（`Sources/Party/UI/PartyRoomView.swift`）：

```swift
// PartyRoomView.swift:259 修改
private func handlePkTap() {
    guard store.canStartPk else {
        AppLogger.party.warning("[PartyRoom] pk tapped but !canStartPk")
        return
    }
    if battleStore.isRunning { showForceEndConfirm = true }
    else if battleStore.isCoolingDown { showCooldownToast = true }
    else { showInitiatePopup = true }
}

// PartyRoomView.swift:1133 toolMenu.startPk 同上 wire
```

**布局叠加**（`body` 内新增 modifier）：

```swift
.overlay(alignment: .top) {
    if battleStore.isSelecting { PartyBattleSelectingPanel(store: battleStore) }
    else if battleStore.isRunning { PartyBattleRunningHud(store: battleStore) }
}
.overlay(alignment: .bottom) {
    if battleStore.isSelecting && store.canManage {
        PartyBattleSelectingStartStrip(store: battleStore)
    } else if battleStore.isRunning {
        PartyBattleHostBottomMarquee(store: battleStore)
    }
}
.sheet(isPresented: $showInitiatePopup) { PartyBattleInitiatePopup(store: battleStore) }
.sheet(isPresented: $battleStore.showSettlementBinding) {
    PartyBattleEndedSettlement(store: battleStore, settlement: battleStore.lastSettlement)
}
```

**麦位 replace 逻辑**（`bigSeatRow` / `audioSeatRow` 内）：

```swift
// SELECTING 阶段视频位 replace
if battleStore.isSelecting {
    PkSelectingVideoTripleView(bigSeats: bigSeats, battleStore: battleStore)
} else if battleStore.isRunning {
    // RUNNING 保留原三视频布局，加红蓝色边
    threeVideoSeatRow(bigSeats: bigSeats, pkTeamClass: battleStore.pkVideoSlotTeamClass)
} else {
    bigSeatRow  // 原逻辑
}
```

**audio-wrap.vue 麦位 giftValueCount 替换逻辑**（`Sources/Party/UI/Components/PartyRoomAudioSeatCell.swift` 扩展）：

```swift
var displayGiftCount: String {
    guard battleStore.isRunning else { return seat.giftValueCount.compactFormatted }
    // PK RUNNING 时按 uid 从 battleStore.redMembers / blueMembers 找
    let uidStr = seat.userId
    let member = (battleStore.state?.redTeam.members ?? [])
        + (battleStore.state?.blueTeam.members ?? [])
    guard let m = member.first(where: { String($0.uid) == uidStr }) else {
        return seat.giftValueCount.compactFormatted
    }
    let display = m.personalGems?.doubleValue ?? m.personalScore?.doubleValue ?? 0
    return display.compactFormatted
}
```

### 6.3 阵营映射（buildTeamSlots）

```swift
// PartyBattleSeatLayout.swift（新增）
struct PartyBattleSeatLayout {
    static func redSlotSeatIndex(_ slotIdx: Int) -> Int { 4 + slotIdx }   // slot 0..4 → seatIndex 4..8
    static func blueSlotSeatIndex(_ slotIdx: Int) -> Int { 9 + slotIdx }  // slot 0..4 → seatIndex 9..13
}
```

### 6.4 K/M 差值格式化

```swift
extension Double {
    var compactFormatted: String {
        let n = self
        if n >= 1_000_000 {
            let m = n / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(m))M" : String(format: "%.2fM", m)
        }
        if n >= 1_000 {
            let k = n / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))K" : String(format: "%.2fK", k)
        }
        return n.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(n))" : String(format: "%.2f", n)
    }
}
```

对齐 H5 `audienceHud.vue:74-82`。

---

## §7 复用判断

### 7.1 就绪复用（无新增）

| 现有模块 | 复用方式 | 定位 |
|---|---|---|
| `PartyAPIClient` | `.post(path:body:)` 加 battle 端点 | `Sources/Networking/PartyAPIClient.swift` |
| `SapiTokenStore` | 自动前置 401 auto-retry | `Sources/Networking/SapiTokenStore.swift` |
| `AppConfigService.fetch` | 全局开关拉取 | `Sources/Networking/AppConfigService.swift` |
| `PartyStore.selfRole` / `roomTempIdInt` / `selfSeat` | 权限门槛 | `Sources/Party/PartyStore.swift` |
| `PartyMessageRouter` | 增补 12 个 attachType case | `Sources/Party/NIM/PartyMessageRouter.swift` |
| `PartyAttachType` enum | 增补 case 移出降噪表 | `Sources/Party/Models/PartyAttachType.swift` |
| `CachedAsyncImage` / `AvatarView` | 结算 MVP 卡头像 | `Sources/Core/` |
| `AppLogger.party` | 全部 log | `Sources/Core/AppLogger.swift` |

### 7.2 F-1 全量新增（本次工作战场）

| 新增文件 | 用途 |
|---|---|
| `Sources/Party/Battle/PartyBattleStore.swift` | 状态机主 store |
| `Sources/Party/Battle/PartyBattleService.swift` | 10 REST 端点 |
| `Sources/Party/Battle/PartyBattleModels.swift` | Codable / DoubleOrString / Int64OrString / 12 payload |
| `Sources/Party/Battle/PartyBattleContext.swift` | 会话内存态 |
| `Sources/Party/Battle/PartyBattleServiceError.swift` | 错误映射 |
| `Sources/Party/Battle/Router/PartyBattleMessageRouter.swift` | attachType → action |
| `Sources/Party/Battle/Config/PartyBattleGlobalConfigParser.swift` | Java Map.toString 兜底解析 |
| `Sources/Party/Battle/UI/PartyBattleInitiatePopup.swift` | 发起弹窗 |
| `Sources/Party/Battle/UI/PartyBattleSelectingPanel.swift` | SELECTING 顶部 |
| `Sources/Party/Battle/UI/PartyBattleSelectingStartStrip.swift` | 房主底部条 |
| `Sources/Party/Battle/UI/PartyBattleRunningHud.swift` | RUNNING HUD |
| `Sources/Party/Battle/UI/PartyBattleHostBottomMarquee.swift` | RUNNING 底部 Top3 |
| `Sources/Party/Battle/UI/PartyBattleEndedSettlement.swift` | 结算弹窗 |
| `Sources/Party/Battle/UI/PartyBattleForceEndConfirm.swift` | 强制结束确认 |
| `Sources/Party/Battle/UI/PartyBattleCooldownToast.swift` | 冷却 toast |
| `Sources/Party/Battle/UI/PartyBattleRulesPopup.swift` | 规则弹窗 |
| `Sources/Party/Battle/UI/PartyBattleGiftPanelTabs.swift` | 送礼面板红蓝 Tab |
| `Sources/Party/Battle/UI/PkSelectingVideoTripleView.swift` | SELECTING 三视频位布局 |
| `Sources/Party/Battle/UI/PartyBattleSeatLayout.swift` | 阵营↔麦位映射 |
| `HilyTests/PartyBattleStoreTests.swift` | 状态机 + 200ms 聚合 + cooldown ticker + gems fallback |
| `HilyTests/PartyBattleModelsTests.swift` | Codable 双兼容 + DoubleOrString / Int64OrString |
| `HilyTests/PartyBattleRouterTests.swift` | 12 attachType 分发正确性 |

### 7.3 关键 gotchas（对齐 rules）

| gotcha | 应对 rule |
|---|---|
| **uid Long 序列化 String/Int 双兼容** | `.claude/rules/ios-decode-userid-compat.md` |
| **payload 字段名首次真机 log 校对** | `.claude/rules/im-payload-real-log-over-code-assumption.md` |
| **method+path 精确对齐 H5** | `.claude/rules/api-http-method-strict.md` |
| **SwiftUI body 复杂度控制** | `.claude/rules/swiftui-body-type-check-timeout.md` |
| **Store publisher 订阅隔离**（keep-alive） | `.claude/rules/swiftui-keepalive-publisher-isolation.md` |
| **Preview 改 init 扫全 3 处** | `.claude/rules/view-init-change-preview-sync.md` |
| **Button.plain heart-area contentShape** | `.claude/rules/swiftui-button-plain-hitarea.md` |

---

## §8 反向清单 + 验收（正向 + 反向 + 边界）

### 8.1 正向清单 F

| # | 场景 | 测试类型 |
|---|---|---|
| F-01 | 房主开 PK → InitiatePopup → 选模板/时长/站队 → Confirm → status=1 SELECTING | 单测 + Preview + 真机 |
| F-02 | SELECTING 60s 倒计时 UI 递减 | 单测 + Preview + 真机 |
| F-03 | 房主 Start Now → apiPartyBattleStartNow → 立即进 RUNNING | 单测 + 真机 |
| F-04 | RUNNING 期送礼 → 分数刷新（gems 口径） | Preview + 真机 |
| F-05 | 1105 200ms 聚合：连续 3 条 → UI 一次 commit 无跳变 | 单测 + 真机 |
| F-06 | 1106 皇冠转移 → 麦位皇冠 icon 立即刷新 | 单测 + 真机 |
| F-07 | RUNNING 自然结束 → onEnd → EndedSettlement 弹出 | 单测 + Preview + 真机 |
| F-08 | 结算显示 Win Team + VS 大比分 + 送礼/收礼 MVP | Preview + 真机 |
| F-09 | 冷却 60s → 房主再点入口弹 CooldownToast | 单测 + 真机 |
| F-10 | 冷却归零 → 可重新发起 | 真机 |
| F-11 | 客态观战 HUD 正常显示 | 真机 |
| F-12 | 客态 SELECTING 期切队（如在麦） | 真机 |
| F-13 | 客态送礼影响所选队伍分数 | 真机 |
| F-14 | 房主 RUNNING 强制结束 → ForceEndConfirm → endedEarly=true | 单测 + 真机 |
| F-15 | 房主收 1102 上麦申请 → 打开申请 sheet（复用现有排麦） | 真机 |
| F-16 | approveApply 通过 → 观众上麦成功 | 真机 |
| F-17 | 全局开关关闭 → PK 入口不显示 | 单测 + 真机 |
| F-18 | roomTempId != 1 → PK 入口不显示 | 单测 + 真机 |

### 8.2 反向 / 边界清单 R

| # | 场景 | 应对策略 | 测试类型 |
|---|---|---|---|
| R-01 | 全局开关拉取失败 | 保留默认 totalSwitch=1 + trackLog | 单测 |
| R-02 | apiPartyBattleStart 失败 → toast + 状态保持 idle | UI toast + AppLogger.error | 单测 + Preview |
| R-03 | apiPartyBattleTemplates 失败 → InitiatePopup 空态 | UI empty state | Preview |
| R-04 | 客态首次进 RUNNING 房 state=nil | onRunningStart 构造默认 state | 单测 |
| R-05 | 1101 payload 无 personalScore | preservePersonal 按 uid 回填 | 单测 |
| R-06 | 1105 只带单侧 gems（灰度期） | 双口径 fallback 回落 raw score | 单测 |
| R-07 | 1109 stub payload (无 durationSec) | onEnd 走 stub 分支 → fetchSettlement 补齐 | 单测 |
| R-08 | tickLeft 归零 + IM 1109 race | 两条链路都容忍，最后一个到的赢 | 单测 |
| R-09 | tickLeft 归零 + IM 1103 race | 神策双上报（沿用 H5 行为，spec §12 A9 待用户决策）| 单测（若决策去重则加）|
| R-10 | onSelectingStart 侵入 partyStore 清 giftValueCount | 只清参战 uid，中立位不清 | 单测 |
| R-11 | reset() 时 leaderboardFlushTask 未 cancel | 清 pending + cancel task | 单测 |
| R-12 | state.roomId=0 占位时 refresh 调用 | fallback PartyStore.roomInfo.id | 单测 |
| R-13 | uid Codable String 序列化 | Int64OrString wrapper | 单测 |
| R-14 | redGems 序列化为 String | DoubleOrString wrapper | 单测 |
| R-15 | attachType 1104/1107/1108/1111 收到 | AppLogger.warning + 不 crash | 单测 |
| R-16 | 双路由 payload 形态（扁平 vs 嵌套） | 首版只做扁平，真机 log 校对；如出现嵌套加 fallback | 真机 |
| R-17 | approveApply 后 RUNNING 无 IM 通知 | 主动 refresh 拉最新 members | 单测 |
| R-18 | Preview 各种 state 空/加载/错误 | Preview 全覆盖 | Preview |
| R-19 | 退房 reset() 完整清 14 字段 | reset 清理 | 单测 |
| R-20 | 冷启动直接落 PK 房 | refresh /state → 恢复正确态 | 真机 |
| R-21 | 断网重连 IM 消息丢失 | refresh /state 兜底 | 真机 |
| R-22 | 网络切换 (Wi-Fi ↔ 4G) | 走进/换房 watch 触发 refresh | 真机 |
| R-23 | PK 中切模板 / 加锁 / MC Seat | F 期其他子项本轮不做，暂无冲突；如撞上加 disable 守卫 | 真机 |
| R-24 | 冷却期收到 1100 SELECTING 消息 | store 允许 idle→selecting，同时 stopCooldownTicker | 单测 |

### 8.3 「反向 → 测试」对应表（feature-pipeline step 1c 验收门）

| 反向 R-# | 对应单测 | 对应 Preview | 对应真机 |
|---|---|---|---|
| R-01 | `PartyBattleStoreTests.testLoadGlobalConfigFailFallback` | — | — |
| R-02 | `PartyBattleStoreTests.testStartApiFailToastKeepIdle` | `PartyBattleInitiatePopup_Previews.error` | ✅ F-1a |
| R-03 | `PartyBattleServiceTests.testTemplatesEmptyResult` | `PartyBattleInitiatePopup_Previews.emptyTemplates` | — |
| R-04 | `PartyBattleStoreTests.testGuestEnterRunningStateNilBuildsDefault` | — | ✅ F-1b |
| R-05 | `PartyBattleStoreTests.testTeamMemberChangePreservePersonal` | — | — |
| R-06 | `PartyBattleStoreTests.testGemsFallbackSingleSide` | — | — |
| R-07 | `PartyBattleStoreTests.testEndStubFetchSettlement` | — | ✅ F-1a |
| R-08 | `PartyBattleStoreTests.testTickLeftRunningRaceWithIm1109` | — | — |
| R-09 | `PartyBattleStoreTests.testTickLeftSelectingRaceWithIm1103` | — | — |
| R-10 | `PartyBattleStoreTests.testSelectingStartClearsPartyStoreGiftCount` | — | — |
| R-11 | `PartyBattleStoreTests.testResetCancelsLeaderboardFlushTask` | — | — |
| R-12 | `PartyBattleStoreTests.testRoomIdFallbackToPartyStore` | — | — |
| R-13 | `PartyBattleModelsTests.testUidStringOrInt64Decode` | — | — |
| R-14 | `PartyBattleModelsTests.testDoubleOrStringDecode` | — | — |
| R-15 | `PartyBattleRouterTests.testUnhandledAttachTypeReserved` | — | — |
| R-16 | — | — | ✅ F-1a 真机 log |
| R-17 | `PartyBattleStoreTests.testApproveApplyRunningTriggersRefresh` | — | ✅ F-1c |
| R-18 | — | 各组件 3 状态 Preview | — |
| R-19 | `PartyBattleStoreTests.testResetClearsAllFields` | — | — |
| R-20 | — | — | ✅ F-1a |
| R-21 | — | — | ✅ F-1a |
| R-22 | — | — | ✅ F-1c |
| R-23 | — | — | ✅ F-1c |
| R-24 | `PartyBattleStoreTests.testCooldownToSelectingSanity` | — | — |

---

## §9 3 个真机 milestone DoD

### 9.1 F-1a 基建 + 主态最小闭环

**目标**：数据层 + IM 路由 + 房主发起+SELECTING+RUNNING+ENDED+冷却 5 态状态机跑通

**Steps**：
1. `PartyBattleModels` / `PartyBattleService` / `PartyBattleServiceError` / `PartyBattleGlobalConfigParser` 齐备（单测通）
2. `PartyBattleStore` 主状态机 + 5 态迁移 + 200ms 聚合 + cooldown ticker + tickLeft 三段（单测覆盖 §8.3 中 R-04/05/06/07/08/09/10/11/12/13/14/19/24）
3. `PartyAttachType` 增补 1100-1112 case，从降噪表移出
4. `PartyBattleMessageRouter` 12 case 分发（单测覆盖 R-15）
5. `PartyMessageRouter` 补 case 转发 battle router
6. `PartyBattleInitiatePopup` + `SelectingPanel` + `SelectingStartStrip` + `RunningHud` + `HostBottomMarquee` + `EndedSettlement` + `ForceEndConfirm` + `CooldownToast` + `RulesPopup` UI 骨架 + Preview 三态覆盖
7. `PartyRoomView.handlePkTap` / `toolMenu.startPk` wire 到 store
8. 布局 overlay + 麦位 replace 逻辑

**真机 DoD**：
- [ ] iPhone 15/13 双机 · 一台创房主，一台观众
- [ ] 主态：房主开 PK → InitiatePopup 3 时长档 + 3 站队选项 → Confirm → status=1 SELECTING（F-01/02/03）
- [ ] SELECTING 60s 倒计时 UI 正常，房主可 "Start Now"（F-03）
- [ ] status=2 RUNNING，客态送礼 → 主态 HUD 分数刷新（gems 口径正确、200ms 聚合无跳变）（F-04/05）
- [ ] status=3 ENDED，EndedSettlement 显示 Win Team / 大比分 / 双 MVP（F-07/08）
- [ ] status=4/5 冷却 → CooldownToast 弹出（F-09）
- [ ] status 归 idle 可重新发起（F-10）
- [ ] IM 1100/1103/1105/1109/1112 真机 log 抓 dataKeys 校对 payload 字段（R-16）
- [ ] 冷启动直接落 PK 房 refresh 恢复（R-20）
- [ ] 断网重连 refresh 兜底（R-21）

**§12 收敛必答清单**（F-1a 完工前逐项闭合）：
- [ ] **A3** 抓 `approveApply(approve=false)` 后 IM 1102/1108 是否 fire；如仅前端消费，UI 层不 sink 观众端拒绝 IM
- [ ] **A4** 抓 `applications` response 是否含分页字段；无分页则 iOS 一次拉全量
- [ ] **A5** 非房主/房管调用 `startNow` 的 response code；沿用 `PartyBattleServiceError.notAuthorized` 或增补
- [ ] **A6** `forceEnd` 后 `settlement.durationSec` / `endedEarly` / `cooldownLeftSec` 字段值；确认 `endedEarly=true` 是否为强制结束唯一区分依据
- [ ] **A8** RUNNING 期观众申请上麦通过后是否发 1101；确认状态机 §3.2 "RUNNING 中途切队"路径生产可用

### 9.2 F-1b 客态观战 + 观众端能力

**Steps**：
1. `PartyBattleGiftPanelTabs`（红蓝 Tab 切换目标麦位）
2. `PartyRoomAudioSeatCell` 扩展 displayGiftCount 逻辑（PK 期麦位钻石数显示切换）
3. `PkSelectingVideoTripleView` 三视频位布局（SELECTING）
4. `PartyBattleSeatLayout` 阵营↔麦位映射
5. 客态送礼影响红/蓝分数（走现有 GiftPanelStore 链路，无需改）
6. 客态观众端 1102 upsert 但无独立 UI（sink 到未来 F 期 applyMic UI）

**真机 DoD**：
- [ ] 主播换账号进别人房，看到 HUD 正常（F-11）
- [ ] SELECTING 时主播在麦，点切队 → apiPartyBattleSwitchTeam → 麦位红蓝色边切换（F-12）
- [ ] 送礼影响正确阵营分数（F-13）
- [ ] 1101 到达 personalScore 按 uid 回填正确（R-05）
- [ ] 1106 皇冠转移 UI 立即刷新（F-06）
- [ ] 客态首次进 RUNNING 房 state=nil 构造默认（R-04）

### 9.3 F-1c 强制结束 + 审核申请 + 异常路径

**Steps**：
1. 房主接收 1102 上麦申请 → sink 到现有排麦入口
2. 房主强制结束流程 ForceEndConfirm → apiPartyBattleForceEnd → apiPartyBattleSettlement → onEnd
3. 全局开关 fallback / totalSwitch 关闭时 PK 入口不显示
4. roomTempId != 1 时 PK 入口不显示
5. 网络切换 / 断网重连场景守卫

**真机 DoD**：
- [ ] 房主收 1102 上麦申请 → approve/reject 各测（F-15/16, R-17）
- [ ] RUNNING 中房主强制结束 → endedEarly=true（F-14）
- [ ] 全局开关关闭 → PK 入口不显示（F-17, R-01）
- [ ] roomTempId != 1 时 PK 入口不显示（F-18）
- [ ] 网络切换 (Wi-Fi ↔ 4G) PK 状态自动 refresh（R-22）
- [ ] PK 中切模板 / 加锁 / MC Seat 变更（如撞上确认互斥）（R-23）

---

## §10 埋点 / 日志规范

### 10.1 埋点

- 本次占位 `AppLogger` 骨架，**不接入神策 SDK**（等 J 里程碑埋点统一收敛）
- `PartyBattleStore.onRunningStart` 内埋点位点：
  ```swift
  AppLogger.party.info("[battle-track] event=b_battle_team_start roomid=\(effectiveRoomId) hostid=\(hostUid)")
  // TODO(J): 接入神策 SDK
  ```

### 10.2 日志规范

- 全部 log 走 `AppLogger.party`（现有 `os.Logger` 子系统）
- 关键节点必打：
  - Router `dispatch` 起始（attachType + dataKeys + scopeId）
  - Store 每个 action 完成（前后 status / leftSec / cooldownLeftSec）
  - API 失败（endpoint + businessCode + description）
- 生产不留裸 `print`（对齐 CLAUDE.md 铁律）

---

## §11 反悔归类（首次填空，step 3 更新）

| # | 假设 | 实际 | 反悔方向 | 修复 |
|---|---|---|---|---|
| — | 首次起草，未反悔 | — | — | — |

（step 3 真机验收暴露反悔后回来填。5 方向：spec 漏 case / 状态机错 / View 结构错 / 通用知识缺失 / 范围扩展）

---

## §12 待用户确认清单收敛（v2 · 2026-07-17 用户端 vs 主播端差异文档填充）

**依据**：三份新差异审计文档已明确"NIM 1100-1112 两端同套 + 权限矩阵完全一致"，A1/A2/A7 已可直接闭合；剩余项归入 F-1a milestone 真机 log 校对边做边收敛。

### A. 主态权限 —— ✅ 已确认

- **A1 已确认**（依据 `party-room-user-vs-anchor-comparison.md` §1 权限矩阵）：
  - 发起 PK：房主（`.owner`）+ 房管（`.admin`），两端行为一致（h5 `header-wrap.vue:34-38 canStartPk` + `partyBattle.ts:553-569`；android `PartyRoomToolsDialog.kt:36`）
  - 平台管理员（`isPlatformAdmin`）在 H5 用户端 `computedRoomRoleType` 内提权等同房主；本工程 `PartyRoomInfo.isPlatformAdmin` 已就绪但当前折进 `.admin` 语义（`PartyRoomToolsSheet.swift:31` wire 未接通）
  - **iOS 决策**：F-1 内部 `store.selfRole == .owner || store.selfRole == .admin` 即为"可发起/可审批"判定；`isPlatformAdmin` 独立分流本次不做（未来需要再抽独立 getter）

- **A2 已确认**（依据同 A1）：审核 PK 上麦申请权限 == 发起 PK 权限（房主/房管/超管一致）。iOS `PartyBattleApplicationsSheet` 显示门槛：`selfRole == .owner || .admin`；IM 接收侧无 role gating（见 A7）

### B. 主态 API 契约 —— 归入 F-1a milestone 真机 log 校对

以下 4 项归档缺失（安卓源码归档只提到 controller 名字未展开）；F-1a 首次跑通主态最小闭环时抓真机 log 逐项确认。**F-1a milestone DoD §9.1 已增补对应验收项**：

- **A3 approveApply 拒绝时是否触发 IM 通知** → F-1a milestone 抓 `approveApply(approve=false)` 后 IM chatroom 1102/1108 是否 fire；如仅前端消费，UI 层不 sink 观众端 IM
- **A4 applications 分页语义** → F-1a milestone 抓 `applications` response 是否含 `pageSize/offset`；如无分页，iOS 一次拉全量，`ApplicationsResp.list` 直接 upsert 到 `store.pendingApplications`
- **A5 startNow 权限校验错误码** → F-1a milestone 抓非房主/房管调用时 response code；沿用现有 `PartyBattleServiceError.notAuthorized` 或增补新错误码枚举
- **A6 forceEnd 冷却语义** → F-1a milestone 抓 `forceEnd` 后 `settlement.durationSec` / `endedEarly` / `cooldownLeftSec` 字段值；若冷却时长与自然结束相同，`endedEarly=true` 作为唯一区分依据

### C. IM 号段边界

- **A7 已确认**（依据 `party-room-user-vs-anchor-comparison.md` §0 + `android-anchor-party-exclusive-apis.md` §0）：
  - NIM 1100-1112 两端**同一套**协议（服务端广播），且 H5 用户端 `pushApply` 无 role gating（`partyBattle.ts:502`），观众端也收 1102 但 UI 不展示
  - **iOS 决策**：1102 接收无 role gating（`PartyBattleMessageRouter` case `.applyPushed` 无条件走 `store.upsertApplication`）；UI 层 `PartyBattleApplicationsSheet` 显示门槛 `selfRole == .owner || .admin`
- **A8 归入 F-1a milestone 真机 log 校对**：抓"RUNNING 期观众申请上麦通过后"的 1101 payload，验证 RUNNING 中途切队是否发 1101；spec §3.2 已允许 RUNNING 中途切队（h5 `approveApply` 通过时 refresh `/state` 暗示已支持），iOS 状态机保持不加守卫

### D. iOS 侧独立决策 —— ✅ 采纳推荐

- **A9 采纳沿用 H5 双上报**：SELECTING/RUNNING 归零时 IM 1103/1109 race 允许神策事件 `b_battle_team_start` 双上报，与 H5 一致；J 里程碑埋点统一时再评估 `pkId+status` 去重

### 收敛结论

- **可立即启动 F-1a 实施**：A1/A2/A7/A9 已闭合，spec §3-§8 与新决策全部一致，无需修订
- **A3/A4/A5/A6/A8 5 项**归为 F-1a milestone DoD 的强验收项（不阻塞启动，但作为 F-1a 完工必答清单）

---

## 附录 A · spec 写作自检清单

- [x] 业务概念词表（§2）不锁 protocol 名
- [x] H5/安卓代码二次校验（§1）在文首
- [x] 状态机（§3）迁移图 + 非法迁移表
- [x] 数据模型（§4）Codable + 双兼容 wrapper
- [x] 事件路由（§5）完整 attachType → action
- [x] UI spec（§6）10 组件 + 布局改造
- [x] 复用判断（§7）就绪 vs 新增
- [x] 反向清单（§8）R-01 至 R-24 + 「反向→测试」对应表
- [x] 3 个真机 milestone DoD（§9）
- [x] 埋点 / 日志规范（§10）
- [x] 反悔归类（§11）留位
- [x] 待用户确认清单（§12）8+1 条
- [x] preflight 铁律引用（cross-scene-component-reuse-preflight / sf-symbol / im-payload-real-log / ios-decode-userid-compat / api-http-method-strict / swiftui-body-type-check-timeout / prefer-shared-component-over-adhoc）

---

## 附录 B · IM Payload 完整 Codable 定义

（因篇幅长，见 `Sources/Party/Battle/PartyBattleModels.swift` 实现；本 spec §4.6 + §5.1 已覆盖字段级映射，Codable 结构体在 step 1a 落地）

---

## 附录 C · API 端点完整定义

| Function | Method | Path | Request | Response |
|---|---|---|---|---|
| `templates` | GET | `/sapi/weidou/v1/client/party/battle/templates` | `nil` | `[Template]` |
| `start` | POST | `/sapi/weidou/v1/client/party/battle/start` | `{roomId:String, templateId:String, durationSec:Int, hostInitialTeam?:Int}` | `StartResp?` |
| `state` | POST | `/sapi/weidou/v1/client/party/battle/state` | `{roomId:String}` | `StateResp?` |
| `switchTeam` | POST | `/sapi/weidou/v1/client/party/battle/switchTeam` | `{pkId:String, targetTeam:Int}` | `nil` |
| `applyMic` | POST | `/sapi/weidou/v1/client/party/battle/applyMic` | `{pkId:String, desiredTeam?:Int, desiredMicId?:Int}` | `{applyId, desiredTeam?, desiredMicId?}` |
| `startNow` | POST | `/sapi/weidou/v1/client/party/battle/startNow` | `{pkId:String}` | `nil` |
| `forceEnd` | POST | `/sapi/weidou/v1/client/party/battle/forceEnd` | `{pkId:String}` | `nil` |
| `settlement` | POST | `/sapi/weidou/v1/client/party/battle/settlement` | `{pkId:String}` | `SettlementResp` |
| `applications` | GET | `/sapi/weidou/v1/client/party/battle/applications?roomId=X` | query `{roomId:String}` | `ApplicationsResp` |
| `approveApply` | POST | `/sapi/weidou/v1/client/party/battle/approveApply` | `{pkId:String, applyId:Int, approve:Bool}` | `nil` |
| **`config`** | GET | `/api/index/getConfigByKey?searchValue=party_room_battle_config` | query | `{party_room_battle_config: String (Java Map style)}` |

---

## 附录 D · 反向 → 测试对应完整表

见 §8.3。

---

**Spec v1 完成**。等待红队外审 + 用户签字（step 0 验收门）。

