# 直播间 + PK 模块功能梳理（iOS Swift 原生重建）

> 来源：真实阅读 `src/views/liveRoom`、`src/views/liveSetting`、`src/views/liveData`、`src/views/liveEnds`、`src/views/liveRule`、`src/stores/modules/{live,livePk,audiencePk,networkMonitor}.js`、`src/api/{live,livePk,liveData}`、`src/use/useCallApi.js`、`src/constant/{live,livePk}.ts`。
> 主体角色为「主播端」（H5 webview 内嵌），既能作为**主态**（自己开播）也能作为**客态**（以观众身份进入其他主播直播间，例如查看 PK 对手或被引流）。

---

## 一、模块概述

主播端直播模块包含三大子系统：

1. **直播生命周期**：开播设置 → 推流直播 → 公屏/礼物/排行实时互动 → 下播结算。基于 Agora RTC（推流）+ 云信 NIM 聊天室（chatroom scene 实时消息）+ 直播心跳接口（状态保活）三条链路。
2. **PK 玩法**：主态发起（随机匹配 / 指定邀请）、被邀请、PK 对战（左右分屏、实时计分、贡献榜）、惩罚阶段、断线/中断处理、重连状态同步。客态独立 store 渲染观看 PK。
3. **直播私 call（直播转通话）**：直播中可被用户付费私 call，暂停直播进入通话，结束后倒计时返回直播。本文聚焦直播与 PK，私 call 仅交代与直播的状态耦合。

核心状态机有两层：
- **直播前端状态** `frontStatus`（`LIVE_FRONT_STATUS_NUMBER`）：0 初始化 / 1 加载中 / 2 直播中 / 3 直播结束 / 4 异常 / 5 通话中。
- **PK 状态** `pkStatus`（`PK_STATUS` 字符串枚举）：Offline / Live / Matching / Inviting / Invited / InPK / Punishing。
- **应用直播态** `appStore.liveState`：`''` / `living` / `liveCalling`（私 call 中）/ `waitingReturnLive`（等待返回直播）。

---

## 二、页面与入口

| 路由 | 文件 | 角色 | 说明 |
|------|------|------|------|
| `/liveSetting` | `views/liveSetting/index.vue` | 主态 | 开播设置页 + 开播后切换为直播间容器（`LiveRoom` 子组件） |
| （内嵌组件） | `views/liveSetting/components/liveRoom.vue` | 主态 | 主播自己的直播间主界面（推流、公屏、PK、礼物、私 call 开关、设置） |
| `/liveRoom` | `views/liveRoom/index.vue` | 客态 | 进入其他主播直播间（订阅远端视频、观看客态 PK、可被引流/快速开播） |
| `/liveEnds` | `views/liveEnds/index.vue` | 主态 | 下播结算页（本场数据、Top Gifters、直播转私 call 列表） |
| `/liveData` | `views/liveData/index.vue` | 主态 | 历史直播收入数据（周/月维度，钻石收入、时长、钱袋子领取） |
| `/liveRule` | `views/liveRule/index.vue` | 主态 | 直播规则说明页 |

开播按钮入口：`liveSetting` 页底部「Start Live」；`/liveData` 浮标可跳数据页；客态房间右下角 `CGoLive` 快速开播。

---

## 三、功能点清单

### 3.1 开播设置页（liveSetting/index.vue）
- 直播简介（liveDescribe，必填，最多 200 字）。
- 直播封面上传（backgroundImgUrl，必填，单图，最大 2MB）。
- 私 call「免费 5 分钟」礼物设置（gitfSetup，单选，价格受 `minGiftPrice/maxGiftPrice` 区间限制；选了礼物则 `privateCallOpen=1`）。
- 愿望单 wishlist（多选礼物 + 数量，min 价 1200；本地 `localStorage` 缓存 `wishlistSetting{agoraChannelId}`，接口不保存愿望单进度需另拉）。
- 美颜设置跳转（`/beautySettings`，跳转时 `unDestroy=true` 不触发下播）。
- 开播校验：简介/封面非空、距上次下播 ≥60s、IM 在线（`checkIMOnline`）。
- 开播流程：开美颜相机 → 等待美颜初始化（`beautyStore.inited`）→ `beginLiveRoom` 接口 → 启动 6s 心跳 → `beginLiveOpen` 推流 → 显示直播间。

### 3.2 直播间主界面（liveRoom.vue 主态）
- 顶部 `LiveRoomTop`：主播头像/昵称、热度 hotScore、计时器、在线人数（≥1k 显示 xk+）、Top2 贡献者头像、本场贡献值动画数字、收礼周榜、每日任务图标、新主播扶持入口、互动轮盘开关（含「Turn on Wheel」引导气泡 + 首次 3 卡片引导）、关闭按钮。
- 中部：PK 对战界面（`isShowPkBattleView` 时）。
- 公屏弹幕 `MessageScroller`（最近 50 条，头插+裁尾）。
- 礼物飘窗 `LiveRoomFloatTips`、礼物展示区 `LiveRoomGiftList`（PK 时隐藏）。
- 底部操作栏：文本输入发送、PK 入口按钮 `PkEntryBtn`、消息按钮（半屏私聊，红点新消息）、礼物按钮、设置按钮（含工具/静音/虚拟道具提示气泡）。
- 公屏「回复@用户」浮层（点击公屏消息气泡 Screen 触发）。
- 私 call 开关（`van-switch`，仅开播选了礼物 + 状态在 Live/Invited/Punishing 时显示；PK 中自动关闭并在退出后恢复）。
- 网络质量指示器 `NetworkIndicator`、弱网提示（连续极差 ≥10 次）。
- 弹窗集合：用户周榜、主播周任务/周榜、半屏聊天、私聊、礼物、名片卡、贡献值、直播设置、公告管理、虚拟道具特效开关、PK 系列弹窗、结束直播确认、返回直播倒计时。
- 钻石盲盒主播感知层 `DiamondGiftHost`。
- 虚拟道具特效计数 >10 提示开关；进场动画。

### 3.3 客态直播间（liveRoom/index.vue）
- `LiveRoomTop`（isHost=false）、客态 PK 对战界面 `AudiencePkBattleView`、公屏、礼物飘窗、名片卡、私聊、快速开播 `CGoLive`。
- 远端视频容器 `#remoteVideoContent`（订阅房主视频流），PK 时隐藏改用 PK 分屏。
- 退出：`leaveLiveRoom()` + 重置客态 PK + `history.back()`。

### 3.4 PK 子功能
- **发起弹窗** `pkInitiatePopup`：随机匹配卡片、接受邀请总开关（`queryInviteSwitch/updateInviteSwitch`）、搜索主播（纯数字→anchorId，否则→nickname）、推荐主播分页列表、邀请按钮（上限 5）、时长设置 `pkDurationPicker`（180/300/600/900 秒）、PK 记录 `pkHistoryPopup`、规则弹窗（首次强制 10s，localStorage 标记）、等待同意弹窗 `pkInviteWaitingPopup`。
- **收到邀请弹窗** `pkInviteReceivePopup`：60s 倒计时圆环、邀请者信息、接受/拒绝；超时自动调超时接口。
- **PK 对战界面** `pkBattleView`：左右分屏（左=本地美颜画面占位、右=订阅对手频道视频）、进度条、双方 PK 值、贡献榜 Top3、倒计时、最后 5s 动画、准备 5s 动画、结果动画、静音对手按钮、对手名片卡。
- **中断/断开确认弹窗**：PK 中点 PK 按钮→中断确认；惩罚阶段→断开连线确认。
- **匹配失败弹窗** `pkMatchFailedPopup`（超时触发）。
- **PK 入口按钮** `pkEntryBtn`：按 pkStatus 切换图标（Matching/Invited 倒计时/InPK/Punishing/默认）。

### 3.5 下播结算页（liveEnds）
- 直播时长、弱网结束提示（forceEndReason=5）、数据预览（Viewers/Followers/Gifters/Diamonds）、Top Gifters 预览前 3 + 全量列表弹窗、直播转私 call 列表（含通话时长、关注按钮）。
- 数据缓存到 `liveStore.liveEndData`，避免重复请求。

### 3.6 直播数据页（liveData）
- 周/月 Tab（this/last week、this/last/two months ago，dateType 0-4）。
- 总收入钻石、直播钻石、私 call 钻石、总时长、钱袋子领取倒计时。

---

## 四、业务逻辑与规则（状态机 / PK 玩法 / 时序）

### 4.1 开播完整时序（主态）
```
checkCanLive() 校验
 → openLocalCameraAndeMic('live') 开美颜相机
 → 等待 beautyStore.inited（watch，完成回调 handleStartLive 自递归）
 → beginLiveRoom(params) 后端开播，返回 yxRoomId/agoraChannelId/hotScore
 → setInterval 每 6s keepLiving()（心跳）
 → beginLiveOpen(settingData)：
      appStore.setLiveState('living')
      initMyLiveClient()（createClient mode:live codec:vp9 role:host，实际复用 callApi）
      确保 rtcToken（handleGetAgoraRtmToken）
      callApi.prepareForCall({ roomId: agoraChannelId, rtcToken, videoConfig 按设备档位 })
      callApi._startLive() 加入频道并发布本地音视频
      liveStore.currentLiveInfo = {...roomInfo, yxAccid, wishlist, hotScore}
      joinChatRoom(yxRoomId) 加入云信聊天室
      networkMonitorStore.startMonitoring() 启动网络监控 + 监听 networkQualityChanged
 → showLiveRoom=true 渲染直播间
```

开播 token 来源：与通话共用同一万能 token 接口 `apiGetAgoraRtmToken`（`/api/index/getAgoraRtmToken`），返回 `rtcToken`/`rtmToken`，channel 参数为空。开播前 `beginLiveOpen` 内部会兜底调一次 `handleGetAgoraRtmToken`，确保 callApi.prepareForCall 拿到的是有效 token，避免 join 频道时报「未授权」。

### 4.2 加入云信聊天室（joinChatRoom）
- `getChatRoomAddress({searchValue:roomId})` 取地址 → `new CHATROOM_BROWSER({appkey, account:yxAccid, token:imToken, chatroomId, chatroomAddresses, chatroomEnterExt})`。
- `chatroomEnterExt` 携带 icon/nickname/yxAccid/userId/isVip/isNewUser。
- 监听 `logined` 与 `chatroomMsg`。
- `logined` 回调：拉历史消息、礼物进度、观众列表、当前收入、愿望单、进房公告补发；启动 30s 观众人数同步定时器。

### 4.3 心跳与 callState
- `liveHeartBeatV2({roomId, callState})` 每 6s 一次（`src/views/liveSetting/index.vue:233-235` 内 `setInterval(keepLiving, 6000)`）。
- `callState` 由 `getCallState()` 按本地状态推导（`liveSetting/index.vue:275-290`）：0 直播中 / 1 通话中 / 2 匹配中 / 3 PK 中。优先级：`isJoiningPk||isInPk` → 3；`isMatching` → 2；`liveState ∈ {liveCalling, waitingReturnLive}` → 1；否则 0。
- 心跳返回 code `1992`（主播被封禁/直播间关闭）或 `1006`（账号封禁）→ `isCompelLiveEnd='3'`。
- 心跳连续失败 >6 次 → `isCompelLiveEnd='4'`（连接断开下播）。

### 4.4 强制下播状态码（liveStore.isCompelLiveEnd，watch 于 liveSetting/index.vue）

`FORCE_LIVE_END_STATUS` 常量（`src/constant/live.ts:32-37`）仅含 4 个值：`SYSTEM_FORCED='3'` / `CONNECTION_FAILED='4'` / `NETWORK_QUALITY='5'` / `CAMERA_ERROR='99'`。**attachType=61/62 不在该常量内**，是 `message.js:678-693` 直接以**字符串字面量硬编码**赋给 `isCompelLiveEnd`（未规范化到常量），各值统一通过 watch `liveStore.isCompelLiveEnd` 分发。**iOS 复刻建议补齐枚举**，把 61/62（含其他未来可能新增的合规状态）一并纳入强制下播状态码枚举，避免散落字符串带来的拼写错位与维护风险。

| 值 | 含义 | 触发源 | 文案 |
|----|------|--------|------|
| 3 | 系统强制关闭/封禁 | 心跳返回 1992/1006（liveSetting）、声网 UID/IP_BANNED（callApi.ts）、云信系统通知 attachType 44（message.js） | "forcibly closed by the system" |
| 4 | 连接失败 | 心跳连续失败 >6（liveSetting） | "connection failed" |
| 5 | 网络质量差 | networkMonitor `forceCloseLive` | "ended due to poor network quality" |
| 61 | 直播规范警告（不下播） | 云信系统通知 attachType 61（message.js） | 警告弹窗，继续违规将封禁 |
| 62 | 直播中被封禁（下播） | 云信系统通知 attachType 62（message.js） | "live broadcast has been banned" |
| 99 | 相机错误 | g-beautyCamera cameraError | "Camera error" |

值 3/4/5/62/99 触发 `handleLiveEnd({searchValue:val})` → 清心跳 → `livingEnd()` → `endLiveRoom` 接口 → 跳 `/liveEnds?forceEndReason=val`。值 61 仅弹警告并 `return`，不下播。

### 4.5 网络监控（networkMonitor store）
- 声网质量等级 0-6（0 未知,1 优,2 良,3 较差,4 很差,5 极差,6 断开）。
- 主播取上下行质量 max 上报 `handleNetworkQualityChange`。
- 连续极差（≥5）计数 `consecutiveCriticalCount`；≥10 上报埋点 + UI 弱网提示；达 `maxCriticalCount=30`（约 60s）→ `forceCloseLive`（设 isCompelLiveEnd=5，触发 forceCloseEvent）。
- 非极差则重置计数。`showWarning` 默认关闭。
- 网络监控**只暴露 `startMonitoring`/`stopMonitoring`**（源码 `src/stores/modules/networkMonitor.js`），**没有 `pauseMonitoring` 能力**。直播生命周期里只在开播时 start、下播/异常时 stop（彻底关闭监控并重置计数），不存在「暂停后再恢复」的中间态。PK 流程中也没有调用 stop，PK 期间弱网仍按统一阈值（连续极差 ≥30 次约 60s）触发 `forceCloseLive`。iOS 实现网络监控不要引入 pause 概念，文档其他位置若提到「暂停网络监控」实际指的是 `stopMonitoring`（彻底停止）。

### 4.6 下播流程
- `handleLiveEnd`：保存强制原因 → 清 isCompelLiveEnd → 清心跳 → `livingEnd()`（leave 频道、清公屏、停网络监控、关相机、setLiveState('')）→ `endLiveRoom(params)` → `router.replace('/liveEnds?forceEndReason=...)`。
- 主动下播前若在 PK：先 `interruptPk()`（PK 中）或 `endPunishment('manual')`（惩罚），再 `cleanupAllPkStates('live_end')`。
- 结算页 `queryLiveStat(liveTime)` 取本场数据；列表/榜单依赖结算缓存 `liveStore.liveEndData`，避免重复请求。

### 4.7 PK 状态机（PK_STATUS）
```
Live ──发起随机匹配──▶ Matching ──匹配成功(100/pkStatus10→joinPk)──▶ InPK
Live ──邀请主播──▶ Inviting ──对方接受(99/inviteStatus1)──▶ InPK
Live ──收到邀请(97)──▶ Invited ──接受──▶ InPK / ──拒绝/超时──▶ Live
InPK ──时间到(endPk→100/pkStatus8)──▶ Punishing ──倒计时结束/手动断开/对方结束(100/pkStatus9)──▶ Live
InPK ──一方中断PK(100/pkStatus9)──▶ Live（不进惩罚，直接 disconnectPk）
任意 ──对方异常断线(100/pkStatus-1)──▶ Live
```

#### 随机匹配
- `startRandomMatch`：`startRandomMatchApi({isMatchRetry:false})` → Matching，QUICK 阶段 15s 倒计时 + 3s 轮询。
- 15s 超时 → `switchToRetryMatch`（`isMatchRetry:true`，RETRY 阶段时长后端配置默认 300s，10s 轮询，poolType B）。
- RETRY 超时 → `cancelMatch('timeout')`，标记 `matchFailedByTimeout` 弹匹配失败弹窗。
- 匹配成功通过 WS（attachType 100 pkStatus=10）推送 → `handleMatchSuccess` → `joinPkApi({roomId,pkDuration:300,oppositeAnchorId,pkType:1})` 拿 pkId → `startPk`。

#### 指定邀请
- `inviteAnchor`：`invitePk` 接口，加入 invitedList（上限 5，可并发邀请多个），状态置 Inviting；埋点 `pk_initiate` style=hostPK。
- 取消邀请 `handleInvite type=4`；对方接受 `99/inviteStatus1`→`handleInviteAccepted`→joinPk(pkType:2)→startPk；拒绝 `inviteStatus2`；超时主动方本地清理，被邀请方 `handleInvite type=3`。
- 被邀请方：`97`→Invited，弹 60s 倒计时弹窗；接受 `handleInvite type=1`→joinPk→startPk；拒绝 `type=2`；超时 `type=3`。私 call 进来自动拒绝 PK 邀请。

#### PK 进行（startPk）
- 进入 InPK，`preparingCountdown=5`（5s 准备动画），同时 PK 倒计时立即开始（startTime=now, endTime=now+duration*1000）。
- 准备结束发公屏通知「The PK is on!」。
- PK 倒计时到 0 → `endPkWhenTimeUp` → `endPkManuallyApi({isActiveDisconnect:1})`，等后端推 8 进惩罚。
- 埋点：`inpk_success`。

#### 多频道并发（PK 对手频道订阅）
- PK 期间维持两个 RTC client：本地推流频道（复用 callApi）+ 订阅对手频道（`rtcPkClient`，`createClient({mode:'live', codec:'vp9', role:'audience'})`，`src/views/liveSetting/components/pkLive/pkBattleView.vue:35,147`）。
- `rtcPkClient.join(opponent.agoraChannelId, ...)` 加入对手频道后，仅订阅 `opponentUserId` 的流，其他用户的 publish 事件按 uid 过滤忽略。
- 离开 PK 时（结束 / 中断 / 异常）`rtcPkClient.leave()` 并置 null，避免下一次 PK 复用残留监听。
- iOS 端同样需要在一个 App 内同时 join 两个频道：用 `joinChannelEx` + 独立的 `AgoraRtcConnection` 管理，token 复用 RTC 万能 token，按 uid 过滤订阅。

#### 实时计分（attachType 98）
- `updatePkValueAndContributors`：myPkValue=pkCounter, opponentPkValue=oppositePkCounter, 双方 Top3（top3User/oppositeTop3User）。
- 进度条 `myPkProgress = floor(my/(my+opp)*100)`，总和 0 时 50。
- PK 期间礼物动画进优先级队列（按 giftPrice 排序，限长 pkGiftsQueueLengthMax 默认 15）。

#### 惩罚阶段（endPk）
- 收 `100/pkStatus8` → Punishing，result 映射 1 win/2 lose/3 draw，惩罚倒计时 120s。
- 发 PK 结束公屏通知（结果文案 + 贡献榜 Top3 富文本，`getPkTop3RankList`）。
- 倒计时结束 / 手动断开 → `endPunishing`（isActiveDisconnect: 1 正常/2 主动/3 断线，disconnectFromStatus: 7 PK 中/8 惩罚中）→ `disconnectPk` 重置回 Live，埋点 `pk_end`。
- 对方结束惩罚 `100/pkStatus9` → 我方 `endPunishment('opponent_ended')`。
- 对方异常断线 `100/pkStatus-1`（后端 20s 无心跳）→ `handleOpponentAbnormalDisconnect` 调 endPunishing(isActiveDisconnect:3)。

#### 静音对手
- `toggleOpponentMute`：`mutePkRoom({mute})` + 发聊天室自定义消息 `attachType:-8` 广播观众；对手音轨 stop/play。

#### 重连同步（syncPkStateAfterReconnect）
- 重连后若本地 InPK/Punishing，调 `getPkStatus`（返回 'INPK'/'PUNISHING'/null）；服务器已结束但本地未结束 → `cleanupAllPkStates`；服务器惩罚中但本地倒计时异常 → 重置 120s 重启。

### 4.8 客态 PK（audiencePk store，独立于主态）
- 进房 `joinLiveRoom` userJoinRoom 返回带 `pkId/pkStatus`（7 PK/8 惩罚）→ `initPkData(res, 房主userId)` → `getPkInfo({anchorId:房主})` 拿双方信息（leftAnchor=房主, rightAnchor=oppositePkInfoVo）。
- WS `100/pkStatus7`（仅客态）→ `initPkFromNotification` 重新拉 getPkInfo，准备 5s 动画 + 倒计时。
- `98` → updatePkData（left=pkCounter, right=oppositePkCounter）。
- `8` → enterPunishment（result 1 left/2 right/3 draw, 惩罚时长 pkPunishingDuration）。
- `9`/`-1` → endPk 重置。
- 客态不调结束接口，纯等 WS 通知。

### 4.9 直播私 call 状态耦合
- `liveState` watch：`liveCalling` 自动拒绝待处理 PK 邀请 + 关所有弹窗；`waitingReturnLive` 弹 15s 返回倒计时弹窗，超时 `returnLive`（beginLiveOpen 复播 + 心跳 + sendCallEnd）。
- `livingEnd(false)` 暂停直播转私 call（不清 currentLiveInfo），`livingEnd(true)` 真正下播。

---

## 五、数据与接口（API / store / 消息类型 / SDK）

### 5.1 直播 API（src/api/live/index.ts）
| 接口 | 路径 | 用途 |
|------|------|------|
| beginLiveRoom | /api/agora/live/beginLiveRoom | 开播 |
| endLiveRoom / endLiveRoomV2 | /api/agora/live/endLiveRoom(V2) | 下播 |
| getMyLiveRoom | /api/agora/live/getMyLiveRoomV2 | 我的直播房（含上次设置） |
| liveHeartBeatV2 | /api/agora/liveHeartBeatV2 | 心跳（callState） |
| getChatRoomAddress | /api/agora/live/getChatRoomAddress | 聊天室地址 |
| userJoinRoom | /api/agora/live/getRoomAndJoinRoom | 加入直播间（含 PK 数据/收入） |
| updatePrivateCall | /api/agora/live/updatePrivateCall | 私 call 开关 |
| getAnchorWishlist | /api/agora/live/getAnchorWishlist | 愿望单 |
| getLiveGiftTask | /api/wallet/anchor/taskInfo/liveGiftTask | 礼物任务进度 |
| queryLiveStat | /api/agora/live/queryLiveStat | 下播结算数据 |
| getContributionRank | /api/live/send/rank/contributionRank | 贡献榜 |
| apiReceiveRank/apiViewers/apiReceiveHistoryRank | /api/live/send/rank/* | 周榜/观众/历史榜 |
| apiGetLiveAnimation | /api/agora/live/openEffect | 进场动画 |
| saveLiveAnnouncement/getLiveAnnouncement | /api/agora/live/editLiveAnnouncement、getLiveAnnouncement | 公告（敏感词 1070） |
| getLiveData | /api/anchor/live/authorLiveData | 历史数据页（实际在 `src/api/liveData/index.ts`，非 live 模块） |

### 5.2 PK API（src/api/livePk/index.ts）
> 导出的是「函数名 → 路径」，函数名带 Api 后缀，路径除规则图外均为 `/api/pk/*`。

| 函数名 | 路径 | 用途 |
|--------|------|------|
| startRandomMatchApi | /api/pk/startPkMatch | 随机匹配发起/轮询（isMatchRetry 区分快速/重试） |
| cancelMatchApi | /api/pk/cancelMatch | 取消匹配 |
| joinPkApi | /api/pk/joinPk | 加入 PK，返回 pkId（pkType 1随机/2邀请） |
| inviteAnchorPkApi | /api/pk/invitePk | 指定邀请 |
| handleInviteApi | /api/pk/handleInvite | 处理邀请（type 1接受/2拒绝/3超时/4取消） |
| getPkRankListApi | /api/pk/getPkRankList | 贡献榜 |
| endPkManuallyApi | /api/pk/endPk | 结束 PK（倒计时到/主动中断走此接口） |
| endPunishingApi | /api/pk/endPunishing | 结束惩罚/断开连线（isActiveDisconnect + disconnectFromStatus） |
| getPkHistoryApi | /api/pk/getPkRecordList | PK 历史记录 |
| getRecommendAnchorsApi | /api/pk/getRecommendAnchorList | 推荐主播列表 |
| getPkTop3RankListApi | /api/pk/getPkTop3RankList | 贡献榜 Top3 |
| muteOpponentApi | /api/pk/mutePkRoom | 静音对手（mute 1/0） |
| getPkRuleImgApi | /api/agora/live/selectPKRuleIcon | PK 规则图（注意在 live 域下，非 /api/pk） |
| updateInviteSwitchApi | /api/pk/updateInviteSwitch | 更新接受邀请开关 |
| queryInviteSwitchApi | /api/pk/queryInviteSwitch | 查询接受邀请开关 |
| getPkInfoApi | /api/pk/getPkInfo | 获取 PK 信息（客态用） |
| getPkStatusApi | /api/pk/getPkStatus | 获取 PK 状态（重连同步，返回 'INPK'/'PUNISHING'/null） |

注：`interruptPk()`（PK 中主动中断）实际复用 `endPunishingApi`（disconnectFromStatus=7），并非独立的 endPk 接口。

### 5.3 Pinia Store
- **useLiveStore**：聊天室对象、公屏记录、观众、热度、礼物、愿望单、任务、强制下播标记、收入、各类公屏分发（钻石盲盒、活动中奖、猜拳、公告、进场动画）。
- **useLivePkStore**（主态）：pkStatus、currentPkInfo、pkBattleData、matchingData、inviteData、pkResult、pkSettings（持久化）、各类定时器。
- **useAudiencePkStore**（客态）：pkStatus、pkInfo、leftAnchor/rightAnchor、pkResult、倒计时。
- **useNetworkMonitor**：网络质量监控与强制关闭。

### 5.4 云信聊天室消息（chatroom scene，chatroomLiveChatRecordMsg 分发）
- **text**：公屏聊天（ext 含 userId/replyNick/chatBubble/isVip/isNewUser/userLevel/activeTycoon/inLiveChannel）。
- **custom（attachType）**：50 直播礼物（含 hotScore/tasks/wishlist 进度/幸运礼物）、56 排行更新、71 热度衰减、52 私 call 开关、-1 通话中、80 进场动画、97-100 PK、-8 PK 静音、-9 PK 公屏、140 活动中奖广播、144 猜拳获胜、195 公告、1030-1033 钻石盲盒、`active_tycoon_enter_room`（attachTypeStr）大 R 进房 Toast。
- **notification（attach.type）**：memberEnter（进房+1，等级用户进场动画/公屏）、memberExit（房主退出=下播）、gagMember/ungagMember（禁言）。
- PK WS 关键：97 收到邀请 / 98 实时计分+贡献榜 / 99 邀请状态(inviteStatus 1接受/2拒绝/4取消，3超时不在 99 分支处理) / 100 状态(pkStatus 7客态开始/8进入惩罚/9对方断开-惩罚阶段=对方结束惩罚、PK进行中=对方中断PK/10匹配成功/-1对方异常断线)。注意 pkStatus 9 由 `handleOpponentDisconnect` 按当前本地状态（PUNISHING vs IN_PK）分流，并非单纯"对方结束惩罚"。
- 发送：公屏 `chatroomMsg.sendTextMsg`，自定义 `chatroomMsg.sendCustomMsg`（ext 必须 JSON.stringify）。

### 5.5 Agora SDK 用法
- **主播推流**：`rtcLivingClient = createClient({mode:'live', codec:'vp9', role:'host'})` 仅被创建/leave 但**从未 join**，实际推流复用 `callApi`（prepareForCall + _startLive）。callApi 的底层 client 是 `createClient({mode:'rtc', codec:'h264'})`，故**主播实际推流编码为 H.264**（项目刻意全程 H.264：移动端 H.264 多有硬编、iOS 无 vp9 编码）。文档中出现的 vp9 仅是未生效的 client 配置，iOS 端按 H.264 实现即可。
- **客态观看**：`rtcOtherLiveClient = createClient({mode:'live', codec:'h264', role:'audience'})`，join + subscribe + 远端 video play 到 `#remoteVideoContent`，监听 user-published/user-left/first-frame-decoded。
- **PK 对手订阅**：`rtcPkClient = createClient({mode:'live', codec:'vp9', role:'audience'})`，join 对手 agoraChannelId，按 opponentUserId 过滤订阅 video/audio。
- 网络质量：`callApi.on('networkQualityChanged', ...)`，preload 预加载频道。
- 静音：`audioTrack.setMuted(value)`（callApi 与 rtcLivingClient 双轨道）。

---

## 六、依赖的 SDK 与原生能力

- **Agora RTC**（agora-rtc-sdk-ng）：推流（host）、订阅（audience）、多频道（直播频道 + PK 对手频道）、网络质量回调、编码档位按设备分档。Swift 用 AgoraRtcKit，注意一个 App 内同时 join 两个频道（PK）需多 `AgoraRtcEngineKit`/`joinChannelEx`。
- **Agora RTM**：rtmToken 鉴权（与 RTC 共用 token）。
- **云信 NIM ChatRoom**：聊天室连接、消息收发、成员查询（queryMembers regularReverse limit 500）、历史消息。Swift 用 NIM SDK 聊天室模块。
- **美颜（NamaSDK/相芯）**：开播前必须初始化（beautyStore.inited），PK 时本地画面用美颜 canvas，按容器尺寸 `beautyCameraCustomSize`。
- **相机/麦克风**：本地采集，静音控制。
- **数数埋点**（reportShuShuCustomEvent）：pk_initiate / inpk_success / inpk_fail / pk_end / c_log 等。
- **DOMPurify**（PK 公屏富文本 XSS 清洗）→ Swift 端富文本需做等价白名单过滤。
- **localStorage 缓存**：愿望单设置、PK 规则首次标记、互动引导标记（需迁移到 UserDefaults/Keychain）。

---

## 七、边界与异常处理

- **开播永久 loading**：rtcToken 缺失会致 `_rtcJoin` 抛错被 cameraError 吞掉；必须 join 前确保 token（与客态一致守卫）。
- **观众人数误差**：30s 定时 `syncAudienceNum` 校正，进退房增量更新可能丢失。
- **公屏无限增长**：定长 50 条，头插裁尾；新消息提示靠监听 `liveChatRecords[0]` 引用变化。
- **猜拳公屏节流**：首条立即，后续每 10s 出队一条，队列上限 20 丢最早。
- **公告去重**：与最近一条相同则跳过；进房补发走 getLiveAnnouncement 而非读字段（竞态）。
- **PK 重复处理防护**：handleMatchSuccess/handleReceiveInvite 在 InPK/Matching/已有邀请时忽略；isJoiningPk 标记确保 join 过程心跳上报 callState=3。
- **PK 参数缺失**（roomId/pkId/oppositeAnchorId）：强制重置回 Live，避免卡死。
- **PK 重连**：syncPkStateAfterReconnect 对齐服务器，惩罚倒计时异常重置 120s。
- **PK 期间网络监控不暂停**：源码 `networkMonitor.js` 无 pause 能力，PK 流程也无调用 `stopMonitoring`，弱网仍按统一阈值（连续极差 ≥30 次约 60s）触发 `forceCloseLive`。iOS 不应实现 PK 期间暂停逻辑。
- **私 call 与 PK 互斥**：私 call 进来自动拒绝 PK 邀请；PK 中自动关私 call 开关并在退出恢复。
- **空 catch 上报**：chatroomMsg 解析异常上报 c_log。
- **强制下播 61 不下播**：仅警告，与 62 区分。

---

## 八、iOS 重建注意事项

1. **多频道并发**：PK 需同时维持「本地推流频道」与「订阅对手频道」。iOS 用 `joinChannelEx` + `AgoraRtcConnection` 管理多频道，注意 token 复用与频道隔离，对手只订阅 opponentUserId 的流。
2. **状态机务必落地为枚举**：主态/客态两套 PK store 完全独立，不要合并；frontStatus、pkStatus、liveState 三层状态相互影响（尤其私 call/PK/网络强制下播交叉）。建议用状态机库或显式 enum + transition 校验（参考 `PK_STATE_TRANSITIONS`）。
3. **心跳是状态权威源**：6s 心跳 callState 由本地状态推导，封禁/断连靠心跳返回码与失败计数判定，Swift 端需保证后台/前台切换时心跳与 callState 一致。
4. **定时器密集**：匹配倒计时/轮询、PK 倒计时、准备 5s、惩罚 120s、观众同步 30s、返回直播 15s、各类气泡。务必在状态切换/页面销毁集中清理（参考 `clearAllTimers`/`cleanupAllPkStates`），避免跨场次串扰。
5. **PK 计分与进度**：myPkValue/opponentPkValue 来自 WS 98，进度条 floor(my/total*100) total=0 取 50；结果 result 1/2/3 映射，惩罚时长以后端 pkPunishingDuration 为准。
6. **聊天室消息分发表**：attachType 是核心路由键，须 1:1 复刻分发逻辑（含 ext/data 二次 parse、roomId 一致性过滤、字符串/对象兼容）。
7. **美颜与 PK 分屏**：PK 时本地画面用美颜渲染并按左半屏容器尺寸调整；iOS 美颜 SDK（相芯）需支持自定义渲染区域。
8. **断线/重连**：重连后必须主动 getPkStatus 对齐，否则本地与服务器 PK 状态不一致会卡死。
9. **网络监控阈值**：连续极差 30 次（约 60s）强制下播；网络监控仅有 start/stop 两态，PK 期间不暂停。iOS 须按统一阈值实现，禁止为 PK 单独引入暂停逻辑。
10. **本地缓存迁移**：愿望单设置、PK 规则首次标记、互动引导标记等 localStorage → UserDefaults，key 带 userId/channelId 维度。
11. **富文本安全**：PK 结束贡献榜公屏为后端可控富文本，Swift 渲染前需白名单过滤标签。
12. **私 call 转直播**：直播中可被付费私 call，暂停直播（不销毁 currentLiveInfo）→ 通话 → 15s 倒计时返回复播，这条链路与 callApi 深度耦合，重建时需与通话模块统一设计。

---

## 九、直播间内嵌玩法补遗

> 本章是对前面「直播生命周期 / PK 状态机 / 网络监控 / 心跳」之外的**内嵌玩法、运营活动、公屏消息类型、名片卡、榜单、任务、公告、虚拟道具**的完整落地清单。来源：真实阅读 `views/liveSetting/components/*`、`views/liveRoom/components/*`、`components/live/*`、`components/diamondGift/*`、`stores/modules/live.js`，以及 `api/{roulette,task,newBie,gift,live}`。

### 9.1 互动转盘玩法（Interaction Wheel / Roulette）

完整的主播自配置抽奖转盘系统。

#### 9.1.1 转盘配置弹窗
- **功能名**：互动转盘设置弹窗
- **说明**：主播在直播间右上角 wheel icon 打开，配置转盘奖项（互动项文本）+ 单次抽奖价格（钻石），可开启/关闭/编辑。
- **file**：`views/liveSetting/components/liveRoulettePopup.vue`、入口在 `liveRoomTop.vue`
- **业务逻辑**：
  - 转盘分区 2~8 项（`baseWheelSectorList`），按 `360/count` 角度均分绘制（conic-gradient + 旋转分隔线，iOS 需自绘制扇形）。
  - 价格 `diamondCount` 必填，奖项文本单条 ≤20 字。
  - 预设互动项 `getQueryPresetText` 可点选快速添加。
  - 状态机按钮：未开启且 ≥3 项 → Enable Wheel；已开启且数据变更 → Finish Editing；已开启 → Close Wheel。
  - 「转盘已开启时改了数据」用 `openAndChangeDataStatus` 标记，决定是否显示「完成编辑」。
- **API**：`api/roulette` —— `getQueryWheelConfigByAnchorId`（查配置/开关状态）、`getAddWheelConfig`（新增/保存，enabled 1/0）、`getChangeWheelStatus`（关闭）、`getQueryPresetText`（预设文案）。
- **状态持久化**：`enabled` 字段（1/0 或 bool），刷新后需重新拉 `getQueryWheelConfigByAnchorId` 同步 icon 开关态。

#### 9.1.2 转盘开播引导气泡 "Turn on Wheel!"
- **功能名**：转盘引导气泡
- **说明**：开播后未开启转盘时，延迟弹出粉紫渐变气泡提示开启，自动消失。
- **file**：`liveRoomTop.vue`（`scheduleWheelTip`）
- **业务逻辑**：延迟 `wheelTipDelaySec`（默认 5s）出现、`wheelTipDurationSec`（默认 5s）后消失，已开启转盘则不弹；运营后台可配（读 `liveStore.rpsConfig`）。

#### 9.1.3 转盘中奖公屏（wheelRes）
- **功能名**：转盘命中公屏消息
- **说明**：用户在转盘抽中某项时，公屏渲染「XXX hit "奖项" on the wheel」橙色样式消息，带等级/VIP 标。
- **file**：`messageScroller.vue`（`item.type === 'wheelRes'`）

### 9.2 猜拳玩法（Rock Paper Scissors / Morra）

RPS 是与转盘并列的「直播互动游戏」，主播端是**感知+引导**角色（实际对战在用户端）。

#### 9.2.1 互动游戏首次引导卡片
- **功能名**：互动游戏引导弹窗（Wheel + RPS 双卡片轮播）
- **说明**：每账号首次点 wheel icon 时弹出 3.5s 自动轮播的引导卡片（Wheel / Rock Paper Scissors），看完才解锁转盘设置。
- **file**：`views/liveSetting/components/rpsIntroPopup.vue`
- **业务逻辑**：localStorage `rps_intro_first_time_shown_{userId}` 标记（**必须带 userId 后缀**，防多账号串号）；引导真正完成（`finish`）才写标记，避免点遮罩关闭后再不展示；转盘弹窗右上角「?」可重看。

#### 9.2.2 猜拳规则说明浮层
- **功能名**：猜拳规则浮层
- **说明**：展示猜拳玩法规则（Best of N 局、每局价格、平局重赛、获胜得勋章上限、异常退出退款）。
- **file**：`views/liveSetting/components/rpsRulesSheet.vue`
- **业务逻辑**：参数 `price/bestOf/medalBase/medalCap` 优先取 `liveStore.rpsConfig`（`price/bestOf/grantedHours/medalCap`），缺失走一期默认 300/3/2/72。

#### 9.2.3 猜拳获胜公屏（rpsWinNotify）
- **功能名**：猜拳获胜公屏 + 勋章奖励通知
- **说明**：用户猜拳赢了，公屏广播「XXX wins RPS，get 勋章图 *Nh」，主播端**无 Challenge 按钮**（用户端才有）。
- **file**：`messageScroller.vue`（`item.type === 'rpsWinNotify'`）、入队逻辑 `live.js enqueueRpsWinNotify`
- **业务逻辑**：attachType=144（LIVA_GAME_NOTIFY），字段 `nickname/medalUrl/grantedHours(medalHours)/price/gameType`；**节流队列**：首条立即，后续每 10s 出队一条，队列上限 20 丢最早。

### 9.3 名片卡（User Card）

点公屏头像/昵称、榜单项、观众项均会弹出，是高频交互。

- **功能名**：用户/主播名片卡
- **说明**：底部弹窗展示对方资料（头像+头像框+资料卡边框、UID、性别年龄、国旗、等级、VIP、勋章、粉丝/关注数、欢迎语）、礼物墙（收到/送出礼物横向滚动）、操作按钮。
- **file**：`views/liveSetting/components/userCard.vue`
- **业务逻辑**：
  - `userType`：1 用户 / 2 主播 / 3 虚拟主播 / 4 机器人；`isAnchor = userType∈{2,3}`，决定显示「收到礼物」vs「送出礼物」、是否显示关注/私聊按钮。
  - **拉黑/移除黑名单**（仅对用户）：`blockUser`（带 isLive 标记）/ `removeBlack`，UI 切换 isBlocked。
  - **关注/取关**：`getFollowUser`（followType 1/2）。
  - **私聊**：emit `openTalkPopup` 打开半屏私聊（埋点 `trackAnchorStart='profile_card'`）。
  - 礼物墙 `getUserCardGiftList`，左右箭头滚动；曝光埋点 `b_host_card_view` / `b_user_card_view`。
  - **资料卡边框** `cardFrame`（透明 PNG 叠层，z-index:-1，不拦点击）、**头像框** `head-frame`、**勋章列表** `medals`。
- **iOS 注意**：拉黑/关注/私聊三类操作有副作用且与全局状态耦合，需对齐。

### 9.4 观众与榜单系统

#### 9.4.1 观众 + 礼物榜聚合弹窗
- **功能名**：Viewers / Fans Rank 弹窗
- **说明**：双主 Tab：在线观众列表（Viewers）+ 送礼榜（Fans Rank）；送礼榜下含 Now/Today/Week 三子 Tab。
- **file**：`views/liveSetting/components/userWeeklyRank.vue`
- **业务逻辑**：
  - Viewers：`apiViewers`，展示头像框/等级/VIP/活跃大R/国家。
  - 送礼榜：`apiSendRank`（rankType now/today/week，传 dbId=房间 id），最多 100 条。
  - **Week 榜特殊布局**：前 3 名领奖台（皇冠 crown1/2/3 + 渐变卡 + 空位 vacant seat），其余列表展示。
  - 钻石数 ≥1000 格式化为 `x.xk`。
  - 点头像 → 名片卡。

#### 9.4.2 主播收礼周榜（Girl Weekly Rank）
- **功能名**：主播收礼周榜弹窗
- **说明**：本周/上周双 Tab，展示给本主播送礼的用户排行；**底部固定栏显示主播自己当前排名 + 距上一名差值**。
- **file**：`views/liveSetting/components/girlWeeklyRank.vue`
- **业务逻辑**：`apiReceiveRank`（rankType week/lastWeek）；`currentAnchorRank`（>100 显示 100+、-1 显示 100+）、`diffNum`（To next rank 差值）。

#### 9.4.3 顶部主播排名条
- **功能名**：直播间顶部主播周榜排名条
- **file**：`views/liveSetting/components/liveRoomTopAnchorRank.vue`
- **业务逻辑**：`apiReceiveRank` 取 `currentAnchorRank`，>100 → 100+、-1 → 99+、0 也显示。

#### 9.4.4 贡献榜/贡献记录弹窗
- **功能名**：本场贡献值弹窗
- **说明**：双 Tab：本场贡献排行（contribution rank）+ 送礼记录（contribution record），顶部显示「This Live Income」。
- **file**：`views/liveSetting/components/liveContributionPop.vue`（+ `contributionRank.vue` / `contributionRecord.vue`）
- **业务逻辑**：`getContributionRank`（anchorId+roomId）、`getLiveGiftRecord`（分页 pageSize 999）。

#### 9.4.5 顶部 Top2 贡献者头像 + 本场收益动画数字
- **功能名**：顶部 Top2 贡献者 + 本场收益滚动数字
- **file**：`liveRoomTop.vue`（`topRankList`、`AnimatedNumber` 绑定 `currentLiveIncome`）
- **业务逻辑**：Top2 来自 `liveStore.topRankList`（cost>1 才显示，第一名金边）；收益数字滚动动画（duration 600ms）。

### 9.5 直播任务系统

#### 9.5.1 Live Stream Task 双 Tab 弹窗
- **功能名**：直播任务弹窗（Live Gift Task + Active Tycoon Task）
- **file**：`girlWeeklyTask.vue`（外壳）+ `liveGiftTaskTab.vue` + `activeTycoonTaskTab.vue`
- **业务逻辑**：
  - **Live Gift Task**：进度条（`giftTask.giftTotal/taskAmount`）+ 今日送礼历史榜（`apiReceiveHistoryRank` 分页），帮主播完成每日礼物任务。
  - **Active Tycoon Task**（仅主态）：主播本周「活跃大R 任务」多阶段进度列表（`getActiveTycoonTaskPanel`，金额脱敏），`reachFlag===1` 显示已完成。
  - 规则弹窗：Tycoon Tab 优先取首条任务 `taskRuleText`，空则默认文案。
- **API**：`api/task` getActiveTycoonTaskPanel；`api/live` apiReceiveHistoryRank。

#### 9.5.2 客态礼物任务进度
- **file**：`liveRoomTopGiftTaskNotHost.vue` + hooks `useCurrentLiveTaskPoints.js`（客态独立算积分）

### 9.6 活跃大R（Active Tycoon）体系

横跨进场、公屏、榜单、任务、名片卡的完整运营标识体系。

- **功能名**：活跃大R 标识与专属待遇
- **file**：`live.js`（`handleActiveTycoonEnterToast`）、`components/common/c-active-tycoon-badge.vue`、`userEntranceFloat.vue`、`messageScroller.vue`、`userWeeklyRank.vue`、`liveGiftTaskTab.vue`
- **业务逻辑**：
  - **进房 Toast**：attachTypeStr `active_tycoon_enter_room`，仅主态主播开播中可见，每个大R **当天首次进房去重**（`activeTycoonToastDedup`）。
  - **进场专属金色底图**：`userEntranceFloat.vue` 普通底图 vs 大R 金色底图（`live_userRR_bg.webp`），文案过长跑马灯滚动；公屏入场专属金边底色 `tycoon-enter-bg`。
  - **大R 徽章** `CActiveTycoonBadge`：公屏消息、榜单、观众列表、任务历史、名片卡处均按 `activeTycoon` 显示，**仅主态可见**。
- **iOS 注意**：大R 标识 `activeTycoon` 字段在几乎所有「人」相关 UI 都要透传判断。

### 9.7 用户进场体系

#### 9.7.1 用户进场飘屏（等级横幅）
- **功能名**：用户进场飘屏组件
- **file**：`components/live/userEntranceFloat.vue`、数据来自 `giftStore.userEntranceData`
- **业务逻辑**：展示进场用户等级标签（`CLevelBadge`）+ VIP + 昵称 + Entered Room，5s fadeLeft 动画；按等级 0~999 分 11 档背景（`level-enter-bg0~11`，高等级用图片底）。

#### 9.7.2 虚拟道具进场动画（80）+ 座驾
- **功能名**：虚拟道具进场特效
- **file**：`live.js` attachType 80 → `virtualPropsStore.playEnterAnimation`；公屏 enterRoom 带 `itemSmallImg`（座驾小图）
- **业务逻辑**：与进场飘屏分层（飘屏层级更低）；公屏入场消息可携带座驾图标 `itemSmallImg`。

#### 9.7.3 公屏进场消息两态
- **功能名**：公屏 Entered Room 消息（普通 vs 官方引流）
- **file**：`messageScroller.vue`（`item.type === 'enterRoom'`）
- **业务逻辑**：`inLiveChannel===1` → 「Official Boost✨ / Platform Featured Newcomer's Room」蓝色引流样式；否则普通等级底色入场条。

### 9.8 虚拟道具特效开关

- **功能名**：虚拟道具特效全局开关
- **file**：`liveSettingEffectSwitchPopup.vue`（开关）、`liveSettingPopup.vue`（入口）、`virtualPropsStore`
- **业务逻辑**：`virtualPropsStore.effectEnabled` 双向绑定开关；`effectPlayCount > 10` 且当场未提示过 → 弹引导提示开关（`hasShownEffectTip`，`resetEffectCountForLive` 每场重置）。

### 9.9 直播间公告（Announcement）

- **功能名**：公告编辑弹窗（敏感词原地标红）
- **file**：`liveAnnouncementPopup.vue`、入口 `liveSettingPopup.vue` 📢
- **业务逻辑**：
  - 最长 120 字，空内容=清空。
  - **敏感词标红**：保存命中后端返回 code=1070 + message（逗号拼接命中词），组件用「镜像叠层」把命中词在输入框内原地标红（textarea 文字透明 + backdrop 渲染）。iOS 需等价实现（attributed string 高亮）。
  - 回显：先用 `currentLiveInfo.announcement`，再异步 `getLiveAnnouncement` 拉最新。
  - 公屏广播 attachType 195：📢 + 高亮标题 + pre-wrap 换行；进房补发与实时广播共用入队（含内容去重，roomId 一致性过滤）。

### 9.10 运营活动资源位 + 中奖广播

#### 9.10.1 直播间活动资源位轮播（iframe 半屏）
- **功能名**：直播间活动 Banner 轮播
- **file**：`liveSetting/components/liveActivitySwiper.vue`
- **业务逻辑**：
  - 轮播 `homeStore.bannerList`，点击用**半屏 iframe 弹窗**打开（不跳路由、不中断直播）。
  - **iframe postMessage 协议**（iOS 需用 WKWebView 实现同协议）：
    - `getAppParams` → 下发 `{token, appId, clientType:'anchor', platform:'web', roomId, roomType, reportParams}`（targetOrigin 校验，失败 return 防 token 泄露）。
    - `CLOSE` 关弹窗；`GO_ROOM`/`GO_LIVE` → 跳 `/liveSetting`；`REPORT_SHUSHU` → 包装成 `anchor_event` 上报。
  - URL 剥离 `roomId/roomType/reportParams` 但保留活动标识。

#### 9.10.2 中奖公屏广播（winner_broadcast / 140）
- **功能名**：活动中奖公屏广播
- **file**：`messageScroller.vue`（`item.type === 'winner_broadcast'`）、`live.js` attachType 140
- **业务逻辑**：
  - 过滤：`roomType===0` 且 `userType===2`（仅主播房）才展示。
  - 两种渲染：带 `messageImage` 的图片卡（叠加文本+Join 按钮）/ 纯文本跑马灯条。
  - 点击 Join 同样走半屏 iframe（独立 `handleWinnerMessage` 监听，e.source 隔离避免与活动 Banner 双触发）。
  - 字段：nickname/activityName/validDays/quantity/activityUrl/avatar/image/messageImage/messageJoin/messageNicknameColor。

### 9.11 钻石盲盒主播感知层

- **功能名**：钻石盲盒主播感知（挂件 + 飘屏 + 公屏）
- **file**：`components/diamondGift/diamond-gift-host.vue`、`diamond-gift-chat-message.vue`、`stores/modules/diamondGift.js`、`live.js handleDiamondGiftMessage`
- **业务逻辑**：
  - attachType 1030 送出 / 1031 / 1032 / 1033，主播端**仅感知**（展示挂件/飘屏/公屏），点挂件只弹规则弹窗，不参与开盒。
  - 公屏 4 态：`diamondGiftSend / diamondGiftClaim / diamondGiftSettled / diamondGiftExpired`。
  - 飘屏队列 `diamondGiftFloatList` + 定时器；离房 `resetForLeave` 清理。
  - 1032 不带 roomId，由 store 内 giftId 链式过滤兜底。

### 9.12 公屏消息富交互

`messageScroller.vue` 是直播间核心，远不止滚动列表，iOS 需逐条复刻消息类型与交互：

- **功能名**：公屏多形态消息渲染 + 主播操作气泡
- **file**：`messageScroller.vue`、发送侧 `liveRoom.vue sendMessageToUser`
- **落地点**：
  1. **消息分类渲染**（按 `item.type` / 字段分支）：主播自己消息、用户文本（VIP/新人/普通三态 + 等级牌 6 档底色 `bg-level1~6`）、礼物消息、幸运礼物中奖（`totalReward`）、PK 通知（DOMPurify 清洗富文本）、钻石盲盒、转盘命中、猜拳获胜、进场（普通/引流）、活动中奖、公告。
  2. **翻译**：每条用户消息可点翻译图标 `CTranslate`，结果原地展示。
  3. **聊天气泡皮肤** `chatBubble`：消息携带 `borderImageSource` 自定义气泡边框（主播穿戴的气泡也透传）。
  4. **主播操作气泡**（仅主态）：点消息「hi」图标弹 van-popover，含 **Screen（公屏@回复）** 与 **MSG（半屏私聊）** 两个动作。
  5. **公屏@回复**：`sendMessageToUser` 发 ext 带 `replyNick`，公屏渲染「主播 @ 用户:」格式（`replyNick`）。
  6. **New screen msg 提示**：监听 `liveChatRecords[0]` 引用变化，不在底部时弹「New screen msg」点击回底。
  7. **等级入场 11 档底色** `level-enter-bg0~11`（高档位用图片）。

### 9.13 新主播扶持计划入口

- **功能名**：新主播扶持计划（NewBie）
- **file**：`liveRoomTop.vue`（`showNewBie`）→ 半屏 `views/newBie/index.vue`
- **业务逻辑**：入口可见性 `getCheckEntryVisibleApi`（`api/newBie`）；点击埋点 `newHost_tool_taskClick {path:'inRoom'}`；半屏弹窗加载 NewBie 页面（隐藏导航栏）。

### 9.14 愿望单展示（房内）

- **功能名**：直播间内愿望单进度条轮播
- **file**：`liveSetting/components/wishlist.vue`
- **业务逻辑**：房内顶部轮播展示未完成愿望（`completed=false` 过滤），4s 自动切换；进度条 `ratio` + `compelteGiftNum/giftNum`；主态读 `currentLiveInfo.wishlist`，客态读 `liveWishList`；**PK 时隐藏**。

### 9.15 礼物面板（房内送礼）

- **功能名**：直播间礼物面板（三 Tab）
- **file**：`liveSetting/components/newGiftsPopup.vue` + `giftsItem.vue`
- **业务逻辑**：Popular / Exclusive / Lucky Gift 三 Tab（`getGiftListData('LIVE')`）；Popular Tab 内幸运礼物按 weight 排在前；swiper 切换 + 指示点。
- **礼物飘窗**：`liveRoomFloatTips.vue` 左侧 bounce-in 飘窗（送礼人头像+昵称+礼物+数量），**PK 时隐藏礼物展示区**。

### 9.16 禁言（Gag/Ungag）状态机

- **功能名**：主播被禁言状态机
- **file**：`live.js`（notification frontMsgType `gagMember`/`ungagMember`）
- **业务逻辑**：`isBlockUser` + `whoBlock`（0 无 / 1 系统 / 2 房主 / 3 系统+房主）双字段状态机；ungag 时按 whoBlock 分流（case 3→仅解房主留系统、case 2→全解、case 1→保持系统禁言）。iOS 需精确复刻该 switch。

### 9.17 其它零散点

- **memberExit = 房主退出即下播**：`live.js` notification memberExit 中，若退出者是房主 yxAccid → `leaveLiveRoom(false)` 并刷新关注/直播列表（客态侧的下播判定）。
- **热度衰减 71**：`updateHotScore`（71 是定时衰减推送）。
- **私 call 开关公屏同步 52**：`attachType 52` 同步 `privateCallOpen`，会回写主态开关态。
- **计时器组件 Calculagraph**：直播时长基于 `myCallStore.currentCallInfo.callingStartTime`（`calculagraph.vue`）。
- **结束直播确认弹窗** `endLivePopup.vue` / **返回直播倒计时弹窗** `returnLivePopup.vue`（15s 旋转倒计时 + 立即返回按钮）。
- **半屏私聊入口弹窗** `messagePopup.vue`（房内消息列表半屏，红点新消息）。
- **rpsConfig 运营配置**：转盘引导气泡时长、RPS 价格/局数/勋章上限统一从 `liveStore.rpsConfig` 读，iOS 需对接同一配置接口。

### 9.18 iOS 复刻补充清单（按玩法）

| 玩法 | 关键自配置/状态 | 关键消息/接口 | 持久化 |
|------|----------------|--------------|--------|
| 互动转盘 | 奖项列表/价格/enabled | roulette 4 接口 / wheelRes 公屏 | enabled 服务端 |
| 猜拳 RPS | rpsConfig（price/bestOf/medal） | 144 rpsWinNotify（10s 节流） | rps_intro_shown_{userId} 本地 |
| 互动引导 | 3 卡片轮播 | — | rps_intro 本地标记 |
| 名片卡 | 拉黑/关注/私聊 | blockUser/getFollowUser/getUserCardGiftList | — |
| 榜单 | now/today/week 多 Tab | apiSendRank/apiReceiveRank/apiViewers | — |
| 直播任务 | Gift Task + Tycoon Task | getActiveTycoonTaskPanel/apiReceiveHistoryRank | — |
| 活跃大R | activeTycoon 全局透传 | active_tycoon_enter_room（当天去重） | activeTycoonToastDedup |
| 公告 | 120 字/敏感词标红 | save/getLiveAnnouncement / 195 公屏 / 1070 | — |
| 活动资源位 | iframe postMessage 协议 | bannerList / 140 winner_broadcast | — |
| 钻石盲盒 | 感知层挂件/飘屏 | 1030-1033 | — |
| 虚拟道具 | effectEnabled 开关 | 80 进场动画 + 座驾 itemSmallImg | effectEnabled |
| 公屏 | chatBubble 皮肤/翻译/@回复/hi 气泡 | sendTextMsg（ext.replyNick） | — |
| 禁言 | isBlockUser + whoBlock 状态机 | gagMember/ungagMember | — |

---

## 十、通用组件与配置补遗（整合）

> 本章整合横切组件 / 零散视图 / 基建配置 / 通用业务组件 四份补遗中归属直播与 PK 的子项，供 iOS 复刻时与第八/九章状态机协同对照。

### 10.1 PK 活动相关弹窗（拉新弹窗与活动奖励弹窗）

PK 活动在主播端有两类入口弹窗，源码同一个文件 `src/components/global/g-pkPopup.vue`，但触发链路与跳转规则有差异，iOS 需统一在 PK 活动入口处理。

- **关键文件**：
  - 组件：`src/components/global/g-pkPopup.vue`
  - 触发：`App.vue` 中的 `getPkData()`（站内信关闭后调用 `getPkActivityData`，返回 `popup` 为真才弹）
  - 跳转：写入 `useAppStore().iframeUrl` 后 `router.push('/iframePage')`

- **关键逻辑**：
  - 距活动结束时间判定：`isLastDay = dayjs(endTime).diff(now, 'hour') < 24`
  - 两套视觉切换：
    - `Last Chance`：最后一天专属标题、主图、按钮文案 `Grab the Final Reward`、独立背景图
    - `Reward Drop`：常规样式，按钮文案 `Join Now`
  - 触发节奏：登录后距上次登录超过 24 小时弹一次
  - 跳转 URL **手动拼接** `&token=${tokenManager.getLoginUuid()}`（与通用 `c-goToIframe` 的 getAppParams 握手机制不同，此处直接走 URL 注入 token）
  - 埋点 `hostPK_activity`
  - 启动期弹窗链顺序：站内信（g-loadList）关闭 → 才拉 PK 活动数据并弹此弹窗，iOS 需保持先后依赖

- **iOS 复刻要点**：
  - 24 小时切换规则需保留两套素材与文案
  - PK 活动页 token 必须通过 loginUuid 拼到 URL 上下发给 H5 容器
  - 与站内信存在先后依赖：站内信关闭事件触发后再拉 PK 数据

### 10.2 直播间用户进场飘屏

直播间与通话场景共用的用户进场金边横幅，承载等级 / VIP / 昵称跑马灯展示，并针对活跃大 R 单独换金色底图。

- **关键文件**：`src/components/live/userEntranceFloat.vue`
- **数据源**：`giftStore.userEntranceData`（与礼物动画队列 `userData` 同源，复用第八章礼物队列机制）

- **关键逻辑**：
  - **跑马灯测量**：渲染时测量内容宽度 `contentWidth`，若大于遮罩宽度 `maskWidth` 才启用横向滚动，动画 4 秒线性循环；不溢出则居中静态展示（替代省略号）
  - **活跃大 R 金色底图**：`isHost && activeTycoon` 时使用 `live_userRR_bg` 金色底图，普通态使用 `live_user_bg`，通过 CSS 变量 `--entrance-bg` 驱动 `::after` 伪元素
  - **整体淡出**：`fadeLeft` 动画 5 秒淡出后从队列中移除

- **iOS 复刻要点**：
  - 复刻"内容宽度测量决定是否启用跑马灯"的判定逻辑
  - 活跃大 R 金色底图通过状态变量驱动，与普通底图互斥
  - 整体淡出与队列消费需对齐礼物进场动画的节奏

### 10.3 浮动按钮容器 fastButtons

直播间右下角（RTL 下为左下角）固定定位的浮动按钮 slot 容器，量级轻但全局复用，承载诸如直播工具、PK、礼物入口等浮动按钮。

- **关键文件**：`src/components/fastButtons.vue`
- **关键逻辑**：
  - `position: fixed; bottom: 100px`，按 `$language` 判断当前语言方向，自动切换 `left/right` 定位
  - 不持有业务逻辑，仅提供 slot 与定位能力，业务按钮由父层透传

- **iOS 复刻要点**：
  - 原生用 UIView 容器实现，按 `UIView.userInterfaceLayoutDirection`（RTL/LTR）自适应左右锚点
  - 底部偏移需结合底部安全区与 TabBar 高度

### 10.4 直播枚举常量（live.ts）

直播相关全部数字状态枚举集中在 `src/constant/live.ts`，iOS 状态机必须对齐这些口径。

- **关键文件**：`src/constant/live.ts`

- **前端直播状态机 LIVE_FRONT_STATUS_NUMBER**（前端流转主状态）：
  | 常量 | 值 | 含义 |
  |------|----|------|
  | INIT | 0 | 未初始化 |
  | LOADING | 1 | 加载中 |
  | LIVE | 2 | 直播中 |
  | LIVE_END | 3 | 直播结束 |
  | LIVE_ERROR | 4 | 异常 |
  | CALLING | 5 | 直播转私 call |

- **后端房间状态 LIVE_ROOM_STATUS_NUMBER**：
  | 常量 | 值 | 含义 |
  |------|----|------|
  | LIVE | 2 | 直播中 |
  | LIVE_END | 1 | 已下播 |

- **强制关播码 FORCE_LIVE_END_STATUS**：
  | 常量 | 值 | 含义 |
  |------|------|------|
  | SYSTEM_FORCED | '3' | 系统强制关播 |
  | CONNECTION_FAILED | '4' | 推流连接失败 |
  | NETWORK_QUALITY | '5' | 网络质量过差 |
  | CAMERA_ERROR | '99' | 相机异常 |

- **在线态枚举 LIVE_STATUS_NUMBER**（心跳 WebSocket 上报用，与主状态机刻意分离避免冲突）：
  | 常量 | 值 | 含义 |
  |------|------|------|
  | ONLINE | 1 | 在线（主状态 1） |
  | OFFLINE | 2 | 登出（主状态 3） |
  | DISCONNECT | 3 | 断链（主状态 3） |
  | CALLING | 10000 | 通话中（主状态 2） |
  | CALL_END | 10001 | 通话结束（主状态 1） |
  | FOREGROUND | 10002 | 回到前台（主状态 1） |
  | BACKGROUND | 10003 | 退到后台（主状态 2） |
  | DO_NOT_DISTURB_MODE_OPEN | 10004 | 开启勿扰（主状态 2） |
  | DO_NOT_DISTURB_MODE_CLOSE | 10005 | 关闭勿扰（主状态 1） |
  | ON_MATCH_MODE | 10006 | 匹配模式（主状态 1） |

  在线态推导（`getOnlineStatus`）：美颜未初始化完成 → 强制返回 CALLING（忙碌）；通话中或 `waitingReturnLive` → CALLING；否则按 `IMOnline` 返回 CALL_END / BACKGROUND。

- **在线态文案归类**（`utils/index.js getStatusName`，与上面是不同口径，用于头像状态点显示）：
  - online：`[1, 10001, 10002]`
  - busy：`[10000, 10003]`
  - offline：`[2, 3]`
  - 有 `liveUrl` 一律返回 `'live'`（优先级最高）

- **iOS 复刻要点**：
  - 三套枚举（前端主状态机、后端房间状态、强制关播码）值域互不重叠，iOS 需逐项映射
  - 心跳在线态刻意使用大数（10000+）避免与主状态冲突，iOS 上报必须沿用同一值
  - 在线态归类与心跳值是两套口径，状态点显示与心跳上报不能复用

### 10.5 PK 枚举与状态机（livePk.ts）

PK 全套状态机、时间常量、限制项、消息类型与状态转换合法性表统一在 `src/constant/livePk.ts`，iOS 复刻 PK 必须以此为单一事实源。

- **关键文件**：`src/constant/livePk.ts`

- **PK 主状态 PK_STATUS**：
  - `Offline` 离线
  - `Live` 直播中可邀请
  - `Matching` 快速匹配中
  - `Inviting` 已发出邀请等待对方
  - `Invited` 收到对方邀请
  - `InPK` PK 进行中
  - `Punishing` 惩罚阶段

- **后端 pkStatus 数字口径**（接口透传值，与前端 PK_STATUS 字符串需双向映射）：
  - `0` 不可邀请
  - `1` 可邀请
  - `2` 等待同意
  - `3` PK 中
  - WS attachType 100 内：`7` 匹配成功 / `8` 进入惩罚 / `9` 断线

- **PK 时间常量 PK_TIME**：
  | 常量 | 时长 | 用途 |
  |------|------|------|
  | QUICK_MATCH | 15 秒 | 快速匹配窗口 |
  | RETRY_MATCH | 300 秒 | 重试匹配冷却 |
  | INVITE_TIMEOUT | 60 秒 | 邀请超时 |
  | PUNISHMENT_DURATION | 120 秒 | 惩罚阶段时长 |
  | 默认 PK 时长 | 300 秒 | 未指定时长时的兜底 |

- **PK 限制项 PK_LIMITS**：
  - `MAX_INVITE_COUNT` 5（同一直播间最大邀请次数）
  - `MAX_HISTORY_DAYS` 30（历史记录保留天数）
  - `RECOMMEND_LIST_SIZE` 100（推荐列表大小）

- **PK 时长选项 PK_DURATION_OPTIONS**：180 / 300 / 600 / 900 秒，含阿拉伯语文案版本 `PK_DURATION_OPTIONS_AR`

- **PK WebSocket 消息类型 PK_WS_MESSAGE_TYPE**：
  | 值 | 含义 |
  |----|------|
  | 101 | 匹配成功 |
  | 102 | 匹配失败 |
  | 110 | 收到邀请 |
  | 111 | 接受邀请 |
  | 112 | 拒绝邀请 |
  | 113 | 邀请超时 |
  | 120 | PK 开始 |
  | 121 | 分值更新 |
  | 122 | 贡献榜更新 |
  | 130 | PK 结束 |
  | 131 | 对方退出 |
  | 132 | 断线 |

- **PK 结果与结束原因**：
  - `PK_RESULT`：胜 / 负 / 平 / 退出
  - `PK_END_REASON`：`timeover` 时间到 / `cutpk` 主动切断 / `opponentQuit` 对方退出 / `liveEnd` 直播结束 / `disconnect` 断线
  - `PK_STATE_TRANSITIONS`：完整的状态转换合法性表，标记每个状态可流转到哪些目标状态（iOS 状态机需逐项落地，非法转换需拦截）

- **iOS 复刻要点**：
  - 前后端 PK 状态有两套口径（字符串 PK_STATUS vs 数字 pkStatus + WS 内嵌 7/8/9），iOS 需要在接入层做双向映射
  - 五类时间常量决定全部超时与节流，硬编码必须与本表一致，禁止散落到业务代码
  - PK_WS_MESSAGE_TYPE 共 12 个值，对应原生 WS 消息分发的 switch 分支
  - `PK_STATE_TRANSITIONS` 合法性表必须移植到原生状态机，作为非法转换的拦截依据

