# iOS 主播端对齐安卓 — 派对房 / 机器人·虚拟来电·转盘 / 心跳 决策规格

> **⚠️ 派对房定位已升级（2026-06-19 15:32 起）**
> 见 `iOS主播端-全量上线里程碑路线图-202606191532.md`。本文将派对房定位为"阶段三补充交付物"，新路线图已将派对房**升为核心三轴之一**，拆为 E（MVP）/F（完整玩法）两个里程碑，与直播 B、1v1 通话 C 并行启动。
> 本文"心跳频率全量对齐安卓""机器人通话做""虚拟来电不做""转盘两处都做""PartyBattle 60s 轮询不做" 等核心决策**全部仍有效**，新路线图直接采纳。

> **需求** DM-20260616-004 原生iOS主播端 · **阶段三补充交付物**（立项功能规格基线）
> **依据**：`01-主播端功能概览与差异速览.md` + `02-01~02-12` 深度梳理 + `03-WebVS安卓差异分析.md` + 本轮对 `android-anchor` **源码的二次核实**
> **范围**：固化三项 iOS 取舍决策 —— ① 派对房对齐安卓 ② 机器人/虚拟来电/转盘的"安卓有则做"判定 ③ 心跳频率全量对齐安卓
> **方法**：所有结论均有代码证据（file:line），并严格区分「活跃功能」与「死代码/未启用」。

---

## 0. 决策汇总

| 项 | 安卓现状 | **iOS 决策** | 依据 |
|---|---|---|---|
| 派对房 | 完整 `partyroom` 模块（最活跃）；Web 完全没有 | **做，以安卓为唯一基线** | 安卓独占完整业务线 |
| 机器人通话 | 活跃（NIM 132/133 驱动 + homeTraffic 接口） | **做** | "安卓有则做" |
| 虚拟来电 | 陪聊呼出活跃；独立来电响铃页为死代码 | **整块暂不做**（待产品明确业务定位） | 本轮决策 |
| 转盘抽奖 | 活跃（独立抽奖页 + 直播间内转盘，两处） | **做（两处）** | "安卓有则做" |
| 心跳频率 | 已全量枚举（见第 3 节） | **逐个对齐安卓取值** | 三端共用后端 |

---

## 1. 派对房 — 以安卓为唯一基线

### 1.1 为什么"对齐安卓"=唯一来源
`h5-anchor`（Web）经全量扫查**无任何派对房实现**：唯一带 party room 字样的代码全部被注释，注释明写"等party房开发完再放出来"。故 iOS 没有 Web 可参考，**安卓 `partyroom` 模块是唯一对齐源**。该模块依赖层级 `partyroom → common + call`，复用 `call` 的声网美颜与 1v1（PartyCall）能力。

### 1.2 必须复刻的核心对齐点（详见 `02-04-派对房.md`）
1. **三 ID 解耦**：业务 `id` / 声网 `agoraChannelId` / 云信 `yxRoomId`，RTC 管音视频流、NIM 管全部信令与公屏消息。
2. **麦位-RTC 对账中心**：`PartyRoomDataManager.postMikeList()` 每次麦位变更全量遍历对账（在麦切声网 `BROADCASTER`、不在麦切 `AUDIENCE`、他人音量在**播放端**静音而非退订阅）——这是核心，必须完整移植。
3. **强消息驱动状态机**：约 30 种 NIM `attachType` 分发（含 gzip 解压、送礼 `2049`、PK `1100-1112`、幸运数字 `1050-1052`、游戏 `136/138`）——工作量最大、最易出 bug，需逐条对齐。
4. **全局房间状态单例**：等价 `PartyRoomDataManager`（iOS 用 `ObservableObject`/Combine，`replay=1` 语义对应 `CurrentValueSubject`）。
5. **PartyCall 抢占**：房内向用户发起 1v1（`callerType==5`）与通话来电互斥/恢复（停预览/关麦/5s 下麦，结束重入频道）。
6. **房币 / 数据页**（宝石↔钻石↔金币、麦时统计）为纯 HTTP 列表，相对简单。
7. **美颜**：FaceUnity iOS + 声网自定义采集帧级打通（对齐安卓而非 Web）。

### 1.3 建议分期（XL 工作量）
- **MVP**：进房 / 上下麦 / 公屏聊天 / 送礼。
- **完整**：管理（房主房管/禁麦/锁麦/踢人）/ 申请排队 / PK / 半屏游戏 / 幸运数字 / 房币兑换 / 麦时统计。
- 后端接口已就绪，iOS 主要是端能力与状态机复刻。

---

## 2. 机器人 / 虚拟来电 / 转盘 — 核实与取舍

> 编译范围确认：`settings.gradle` 中 `:keep` 模块被注释，**不参与编译**；下述活跃类均在已编译模块（`call`/`app`/`partyroom`/`mine`/`common`）。

### 2.1 核实结论总表

| 功能 | 安卓状态 | 关键证据（file:line） | 端侧定时器 | iOS |
|---|---|---|---|---|
| 机器人通话 RobotCall | **活跃** | NIM `132/133` → `CustomNotificationHandler.java:114/117` → `AppRouteImpl.java:104/131` → `RobotCallingDialog.kt:107` → `RobotCallActivity`；`call/AndroidManifest.xml:7` 注册 | 响铃 30s / 自动挂断 30s / 最短 10s / 1s ticker | **做** |
| 虚拟来电·陪聊呼出 `VirtualChatActivity`(call) | 活跃（呼出） | `Normal/ReviewAVChatStrategy.java` 匹配机器人用户 → `CallMatchHelper.match` → `outgoingCall()`；`call/AndroidManifest.xml:16` 注册 | **心跳 60s**（`checkBalance`，`anchorHeartbeat`/`heartbeatV4`） | **暂不做** |
| 虚拟来电·独立来电响铃页 `VirtualCallActivity`(app) | **死代码** | `app/AndroidManifest.xml:290` 注册，但全仓**零处** `start()` 调用；来电观察者 `StayService.kt:123-128` **被整段注释**（NIM `29` 仍 post 但无消费者） | countdown 20s（未启用） | **暂不做** |
| 转盘·独立抽奖页 `TurntableGameActivity`(app) | **活跃** | `Const.TO_TURNTABLE_ACTIVITY=0x006` → `ActivityBridgeImpl.java:36/59`，由 `BaseActivity.kt:109`/`AVChatActivity.java:1256` 等拉起；接口 `expand/turntableGame/*` | 下注 1s / 开奖轮询 100ms / 结果 8s | **做** |
| 转盘·直播间内 `WheelShowDialog`(call) | **活跃** | `LiveCallActivity.kt:302→310→315/994`（转盘按钮 → 规则三连弹 → 展示）；接口 `wheel/*` | 引导气泡 5s | **做** |

### 2.2 机器人通话（做）
服务端按引流策略推 NIM 来电通知（`133` 响铃 / `132` 奖励），主播弹响铃框、接听进 `RobotCallActivity` 走音视频；呼入/结束上报 `api/homeTraffic/hostCallVirtualUser` / `hostCallOverVirtualUser`，**计费由后端按这两个接口结算，端侧无独立心跳**。iOS 需复刻：NIM 132/133 触发链、响铃 30s 超时、通话最短 10s 限制、奖励弹窗。

### 2.3 虚拟来电（整块暂不做 — 决策记录）
安卓实际拆两块：①`VirtualChatActivity` 机器人匹配陪聊（呼出活跃，带 60s `checkBalance` 心跳 + 服务端下发心跳时间点）；②`VirtualCallActivity` 独立假人来电响铃页（已注册但**无任何入口**，来电观察者被注释，属死代码）。
**本轮决策：iOS 首版整块不做**，待产品明确"假人/机器人来电"的业务定位（引流/审核）后再单独排期。**遗留确认项**：后端是否仍下发 NIM `29`（`ROBOT_INCOMING_CALL`）来电通知（见第 4 节）。

### 2.4 转盘（两处都做）
- **独立抽奖页 `TurntableGameActivity`**：金币转盘，拉档位(SKU)→选档参与→开奖（开奖结果 100ms 轮询 `queryTurntableResult`）；被通话打断会置位并在通话结束回跳。
- **直播间内转盘 `WheelShowDialog`**：主播配置转盘文案/开关供观众参与（`api/wheel/queryWheelConfig` 等），首次开启强制看三页规则 `InteractionGameRulesDialog`，开播 5s 未开启弹引导气泡。

### 2.5 易混淆澄清（勿做错）
- `RobotTaskListFragment`（机器人**任务**，新人平台任务，NIM `135`）**≠** 机器人**通话**，是两套独立功能。
- 派对房"幸运数字 LuckyNumber"、直播间"幸运礼物飘屏" **≠** 转盘抽奖（关键字 `roulette` 全仓无命中），不要并入转盘。

---

## 3. 心跳频率 — 全量对齐安卓

### 3.1 有周期心跳 / 上报（iOS 逐个对齐取值）

| 机制 | **精确间隔** | 失败阈值 / 动作 | 接口 / 字段 | 实现 | file:line |
|---|---|---|---|---|---|
| 直播心跳 | **10 秒** | 连续 **>3 次**失败 → `endType=4` 强制下播；`1992`封禁(2)/`2001`无权限(6) | `liveHeartBeatV2`，`roomId`+`callState`(0直播/1通话/2匹配/3PK) | `Flowable.interval(0,1s)` 取 `%10` | `LiveCallActivity.kt:1268/1272/1059-1112`；端点 `common/http/HttpHelper.kt:248-250` |
| WebSocket 在线态心跳 | **15 秒** | 1 次未回 → 立即重连（重连间隔 **10 秒**） | `onlineStatus`(CALLING/BG/FG/OFFLINE)；服务端 `messageType==1` 为回应 | `ScheduledExecutorService.scheduleWithFixedDelay` | `common/websocket/VptWebSocketManager.java:43/231-269/301-316` |
| 在线时长 A·收益上报 | **300 秒**(5min) | 无重试；跨天即时结算；**退后台>60s 补传** | `addUpOnlineTime`(dayDate/daySeconds/monDate/monSeconds) | `Observable.interval(1s)` 取 `%300` | `ActivityLifecycleCallbacksForOnlineStatistics.kt:102/116-156` |
| 在线时长 B·任务时长 | **60 秒**(1min) | 仅本地 SP + UI，不直接上报 | 事件 `Const.UPDATE_ONLINE_TIME` | 同一 interval 取 `%60` | 同上 `:120-122`；`OnlineTaskHelper.kt:31-99` |
| 虚拟/机器人陪聊心跳 | **60 秒** | `checkBalance`；另叠加服务端下发心跳时间点 | `anchorHeartbeat` / `heartbeatV4`（`remark=CALL_IN/OUT`） | `Flowable.interval(0,1s)` 取 `%60` | `VirtualChatActivity.java:~686/691`（虚拟来电暂不做，仅记录） |
| PK 快速匹配轮询 | **1 秒 × 15 次** | 完成 → 进扩大匹配 | `startPkMatch(false)` | `interval(0,1s).take(15)` | `LiveRoomMsgFragment.kt:594-653` |
| PK 扩大匹配轮询 | **1 秒 × waitDuration** | 超时 → 弹"未匹配到"+取消+打点 | `startPkMatch(true)` | `interval(0,1s).take(n)` | `LiveRoomMsgFragment.kt:620-626` |
| 隐身自动取消（随 WS 心跳判断） | 随 **15s** 检查；上限 **20 分钟** | 超 20min 自动取消隐身、恢复前台态 | 本地翻转 + `EVENT_HIDEN_STATUS_CHANGE` | 复用 WS ScheduledExecutor | `VptWebSocketManager.java:242-249`；`Const.java:482` |

### 3.2 安卓「无客户端周期心跳」的地方（iOS **不要自造**，否则与后端结算/在线态冲突）
- **声网真实 1v1 通话**（`ShengWang1V1CallActivity`）：**无计费心跳**，扣费全由声网 CallApi + 后端驱动，端侧 `callTimeDisposable` 只刷 UI 显示时长。⚠️ 与上面"虚拟陪聊 60s 心跳"是**两套不同通话栈**，勿混。
- **派对房**：在线人数靠 NIM 进出房事件增减（`PartyRoomVM.kt:327/349`），进房全量重置一次，**无周期心跳**；麦时 `mOnMikeStartTime` 仅在下麦/切麦一次性埋点。
- **观众数**：安卓**没有** Web 那种 30s `queryMembers` 定时校准。
- **审核态**：复用同一个 15s `VptWebSocketManager`（带审核账号 token），**无独立审核 WS**；`VptWebSocketManager2`（30s）全仓无调用方，是死代码，忽略。
- **PartyBattle PK 状态**：`PartyBattleManager.kt` 有 `STATE_POLL_INTERVAL_MS=60_000` 但 `pollJob` **已被注释**（`:72-77`），现状靠 NIM 推送 + `forceRefresh()` 一次性拉取 → **iOS 按 NIM 推送实现，不做 60s 轮询**。

### 3.3 与 Web 的差异 & 统一值提醒
- 直播心跳：Web **6 秒 / 失败>6 次**，安卓 **10 秒 / 失败>3 次**。本需求"对齐安卓"=取 **10 秒 / >3 次**。
- 弱网强制下播阈值：Web 连续 30 次极差，安卓连续 **≥10 次**（`endType=7`）；采集失败 **>20 秒**（`endType=5`）。均为回调累计/差值判断，非固定间隔心跳。
- **立项建议**：三端共用后端，iOS 取值前同步知会后端确认"直播心跳频率/失败阈值"的三端统一口径。

---

## 4. 待产品 / 后端确认项

1. **虚拟来电业务定位**：假人/机器人"来电"的引流/审核定位；后端是否仍下发 NIM `29`（`ROBOT_INCOMING_CALL`）来电通知。确认后再决定 iOS 是否补做（含陪聊呼出 60s 心跳）。
2. **心跳统一值**：直播心跳 Web 6s vs 安卓 10s，iOS 取安卓值前与后端对齐三端统一口径。
3. **PartyBattle 轮询**：确认"已注释的 60s 轮询"是否永久废弃（iOS 默认按 NIM 推送实现）。

---

## 5. 关键文件索引（iOS 研读用 · 安卓侧）

- **派对房**：`partyroom/manager/PartyRoomDataManager.kt`（状态单例/麦位对账/PartyCall）、`partyroom/manager/RtcEngineManager.kt`（声网引擎/角色/媒体/美颜）、`partyroom/viewmodel/PartyRoomVM.kt`（NIM 消息状态机/断线重连）、`partyroom/http/ApiService.kt`。
- **机器人通话**：`call/agora/ui/RobotCallActivity.kt`、`call/page/dialog/RobotCallingDialog.kt`、`app/route/AppRouteImpl.java`、`common/nim/NIMMsgAttachType.java`（132/133）、`call/http/HttpHelper.kt`（homeTraffic）。
- **转盘**：`app/page/activity/TurntableGameActivity.kt` + `app/bridge/ActivityBridgeImpl.java`；`call/page/dialog/WheelShowDialog.kt` + `InteractionGameRulesDialog.kt` + `LiveCallActivity.kt`（转盘按钮）。
- **心跳**：`call/agora/ui/LiveCallActivity.kt`（直播心跳）、`common/websocket/VptWebSocketManager.java`（WS 心跳）、`app/app/ActivityLifecycleCallbacksForOnlineStatistics.kt` + `app/helper/OnlineTaskHelper.kt`（在线时长）、`call/page/fragment/LiveRoomMsgFragment.kt`（PK 匹配轮询）。

---

*本文件为阶段三补充产出，仅固化本轮三项 iOS 取舍决策；完整业务梳理见 `01-*` / `02-01~02-12` / `03-*`。*
