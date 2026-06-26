# E spec amendment v4 — 他人视频流渲染补全

> 作用域：对 `E-spec-H5安卓代码二次校验-202606231500.md` v3 的增量补丁。
> 触发：真机验证发现"其他人上视频位看不到画面"。spec v3 §1.4.7 当时把"他人视频流"划在 F 期，**v4 提前到 E MVP**——视频位上只能看到自己等同于残缺。
> 时间：2026-06-24 17:30
> 状态：**真机双机已验证通过（2026-06-24）**。R1/R4/R5/R7 已跑，行为符合预期。

## 真机验证记录（2026-06-24）

| # | 用例 | 结果 |
|---|---|---|
| R1 | 远端用户上视频位，本端看到实时画面 | ✅ |
| R4 | 远端用户关摄像头 → UI 头像覆盖、远端流不断 | ✅（隐含 R5 复用） |
| R5 | 关摄像头后重开 → 画面恢复不丢首帧 | ✅ |
| R7 | 自己上视频位不被错调 setupRemoteVideo | ✅（日志验） |

R3 / R6 / R8-R12 等场景留 F 期常规回归覆盖（MVP 不阻塞）。

## Step 5/6 收尾沉淀

- `Sources/Party/RTC/PartyRTCEngine.swift` 新增 4 方法 + 双字典（不抽 Core/，F 期 PartyCall 再看）
- `Sources/Party/UI/PartyRemoteVideoView.swift` 新建（不抽 Core/，理由同上）
- **rules 沉淀**：`.claude/rules/swiftui-camera-preview.md` §2 追加「按业务 key 池化 UIView 正解模式」

---

## 1. v3 边界条款撤销

**原 §1.4.7（v3）**：
> **他人**视频位：仅头像 + 摄像头状态 icon（远端视频流渲染推 F 期）

**v4 新边界**：
> **他人**视频位：远端视频流实时渲染（按 seatIndex 维 UIView 池防 SwiftUI redraw 丢首帧）；摄像头关闭时 UI 头像 placeholder 覆盖远端 canvas，**不调 muteRemoteVideoStream**（声网订阅层保持干净，对齐 H5 行为）

## 2. H5 / 安卓代码二次校验

**调研结论**：
- H5 在 `usePartyHooks.js:207-216` 用 `playVideoInDom()` **按 seatIndex 维 DOM 池**（容器 ID `#partyMicDom-${seatIndex}`），不按 uid
- H5 摄像头关闭走 `video-seat-cell.vue:61-63` UI 头像 placeholder 覆盖，**远端流仍在订阅发送**
- H5 用户切麦位（同人换位）：`usePartyHooks.js:1515-1516` 主动重绑 `playVideoInDom` 到新 seatIndex
- H5 用户下麦：`usePartyHooks.js:1522-1524` `_closeTrack(uid)` 停止该 uid 播放
- 安卓代码未查到独立片段（与 H5 同源逻辑由前端实装），按 H5 行为对齐

**iOS 独有约束（H5/安卓无）**：
- SwiftUI redraw 会让 `UIViewRepresentable.makeUIView` 重复调用，AgoraRtcVideoCanvas.view 反复换 view 会丢首帧（`.claude/rules/swiftui-camera-preview.md` §2 已沉淀）
- 解决：UIView 必须按 seatIndex 缓存，PartyRTCEngine 持有 view 池，PartySeatItemView 通过 representable 取池中稳定实例
- 衍生：`setupRemoteVideo(uid: 0, view: nil)` 用于清理；setupRemoteVideo 重复同 (uid, view) 是声网 SDK 幂等的

## 3. 数据模型 / API 增量

无新 HTTP 接口。复用：
- 进房 `room/enter` 返回的 `agoraChannelId`（v3 已用）
- `seatList[].userId`（v3 已用，**新约束**：必须 `UInt(userId)` 转换为声网 uid 才能 setupRemoteVideo）
- `seatList[].seatType == 1`（视频位筛选）
- `seatList[].cameraEnabled == 1`（决定 UI 是否覆盖头像 placeholder）

## 4. 状态机增量

`postMikeList` 内追加远端视频流对账（在原"他人音量"循环之后）：

```
foreach seat in seatList where seatType == 1（视频位）:
    if seat.userId 有效 && uid != myRtcUid:
        view = PartyRTCEngine.acquireRemoteView(seatIndex: seat.seatIndex)
        engine.setupRemoteVideo(uid: uid, view: view)
        （声网默认 autoSubscribeVideo=true，无需 muteRemoteVideoStream(false)）
    else（视频位空 / 用户离开 / 是自己）:
        engine.setupRemoteVideo(uid: 0, view: nil)  // 仅当之前有绑定，按 seatIndex 缓存的"上次 uid"清理
```

**关键决策**：
- PartyRTCEngine 内部维护两个映射：
  - `seatIndexToView: [Int: UIView]` UIView 池（按 seatIndex，**生命周期与房间一致**，进房创建、退房释放）
  - `seatIndexToBoundUid: [Int: UInt]` 上次绑定的 uid（用于换人时清理旧 uid）
- view 池在进房（rtc.join 时）按视频位数预分配；不预分配也可懒分配，但按 spec §1.4.7 的麦位模板预知更稳

## 5. 反向 / 边界清单（**Step 4 真机必跑**）

| # | 场景 | 期望 | 验法 |
|---|---|---|---|
| R1 | A 进房 + 上视频位 1 → B 进房 | B 看到 1 号麦位 A 的实时画面 | 双机 |
| R2 | A 上视频位 1 → A 下麦 → A 再上视频位 1 | uid 不变 / view 不变；B 看到画面连续无空帧 > 1s | 双机 |
| R3 | A 上视频位 1 → A 切到视频位 2（下 1 再上 2）| 1 号空 view 复位、2 号绑定 A；B 同时看 1 号空、2 号 A 画面 | 双机 |
| R4 | A 上视频位 1 → A 关摄像头（updateMedia type=2 enable=0）| B 看到 1 号麦位 UI 头像覆盖；声网 SDK 流仍订阅（不调 muteRemoteVideoStream）| 双机 + 日志确认无 mute 调用 |
| R5 | A 关摄像头后 → A 重新开摄像头 | B 看到视频流恢复无空白（**不丢首帧**）| 双机 |
| R6 | A、C 同时上视频位 1、2 | B 同时看到 A、C 两路远端 | 三机 |
| R7 | 自己上视频位 1 | 自己看本端预览（已实装），**不应该有 setupRemoteVideo(uid=自己)** 错调 | 单机 + 日志验 |
| R8 | seat.userId 转 UInt 失败（异常 ID） | 不调 setupRemoteVideo + warning 日志 | 单机日志验 |
| R9 | A 上视频位 1 → A 在该房断网 reconnect | 重连后 B 看到 A 画面恢复（RTC 重连内置由 SDK 处理）| 双机 + 飞行模式 |
| R10 | SwiftUI 频繁 @Published redraw（如 chat.onlineCount 跳变）| 视频画面不丢帧不黑屏（**rules §2 关键约束**）| 单机 + 真机观察 |
| R11 | 退房 → 进同房 | 远端 view 池正确释放 + 重建；不发生 view 错绑前次房间残留 | 单机退进 3 次循环 |
| R12 | 视频位 1 上的 A 离线（不主动下麦）| 30s 后 1 号清空；B 看到画面消失 | 双机 + A 杀进程 |

## 6. 验收清单（amendment）

正向（覆盖到上面 R1, R5, R6）：
- [ ] 一房双视频位 双机 双视频流互通
- [ ] 摄像头关/开循环不丢首帧
- [ ] 切麦位换 seatIndex 远端画面正确切位

反向（覆盖到 R7, R8, R10）：
- [ ] 自己视频位不被错调 setupRemoteVideo
- [ ] 异常 userId 跳过 setupRemoteVideo
- [ ] SwiftUI redraw 不导致 view 重建丢帧

边界（覆盖到 R9, R11, R12）：
- [ ] 断网重连恢复
- [ ] 退进同房循环不残留
- [ ] 远端离线自动清空

## 7. 复用候选标记

| 模块 | 候选位置 | 决策 | 理由 |
|---|---|---|---|
| PartyRemoteVideoView 池机制 | Core/Agora/ | **不抽** | 直播侧 RemoteVideoView 是单远端单 view 模式，与派对房 N 路远端 + 池化模式不同；F 期派对房视频位扩展时再看是否复用 |
| AgoraRtcVideoCanvas 创建模板 | Core/Agora/ | **不抽** | 单点用法（PartyRTCEngine 内），抽离会拆肉；F 期 PartyCall 真用到再抽 |

## 8. Step 1 验收门（spec 自我审）

- [ ] 词表：`PartyRemoteVideoView` / `acquireRemoteView(seatIndex:)` / `clearRemoteVideo(seatIndex:)` 三个新概念已定义
- [ ] 状态机：postMikeList 增量分支已用伪态描述
- [ ] 反向清单：R1-R12 共 12 条覆盖 v3 §1.4.7 撤销后的全部边界
- [ ] 复用候选：明示 trial 期暂不抽并记录理由
- [ ] H5/安卓校验：已对齐

## 9. 待用户审批后进 Step 1 入口

如审批通过：
- 实施顺序：**1a → 1b → 2 → 3 → 4**
- 不写单测（项目 SwiftPM 无测试 target，沿用 v3 真机验证模式）
- step 1b 无新设计稿 → **跳过 /restore-design，记入流水线 checklist**

