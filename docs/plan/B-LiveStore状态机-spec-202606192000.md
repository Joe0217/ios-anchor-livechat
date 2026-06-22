# Hily B 里程碑 · B-LiveStore 状态机 spec

> 关联：
> - 路线图：`iOS主播端-全量上线里程碑路线图-202606191532.md` §三 B
> - 二次校验：`B-spec-H5安卓代码二次校验-202606192000.md`（本 spec §1 即引用此文件）
> - 兄弟 spec：`B-NIMChatroomManager完善-spec.md`（NIMChatroomManager 四处缺口）
> - 现状基线：`Hily原生工程-已实现功能审查-202606191346.md`（60% 完成度）
>
> **范围**：B 里程碑 13 项 P0 缺口中的 **10 项**（除 NIMChatroomManager 三处归 NIMChatroomManager spec）
> **真机验收门槛**：见 §13；实施任务清单见 §14
> **不包含**：1v1 通话、直播 ↔ 通话切换、PK、礼物动画真实播放（分别属 C/D/G/H 里程碑）
>
> **修订记录**：
> - v2 2026-06-19 按 LiveStore 3 角度对抗式 review 修订（删除 rtcToken 取数 bug 误判；补状态机 starting/preparing 分支；CAS 并发原子性；§12 字段补齐；NetworkMonitor 生命周期；BeautyRenderer UI 反馈；i18n 声明）
> - v3 2026-06-19 跨 spec 同步：§2.4 入口 + §12 NIM 调用表加 `adjustOnlineCount(by:)`
> - v4 2026-06-19 跨 spec 同步（NIM-spec v2 review 触发）：§2.5b 多源 forceEnd 优先级仲裁；§13 DoD #11 改"取最高优先级源"；§15 加埋点 `subSource` 与仲裁权衡风险
> - **v5 2026-06-20 弱网分层降级**（产品级反悔，与路线图 §2 #5 锁定"≥10 次"冲突，用户授权调整）：§4 增 §4.5 分层（**连续** 10 次降级 / **连续** 30 次下播 / **连续** 5 次恢复，中间任一次质量 ≤4 即清零重计）；§2.3 加 `networkWarningToast` 字段；新增 `setNetworkWarning(_:)` 入口；§11 endType=7 触发阈值改连续 30 次；§13 DoD #5 拆 5a/5b/5c 三档；AgoraManager 加 `applyEncoderQuality(.normal/.low)` API（720×1280 + 30↔15fps）
> - **v5.1 2026-06-20 弱网降级实战修复**：用户真机反馈"弱网时画面卡住没降帧率"。根因 1：外部视频源模式下相机仍 30fps 推帧编码器堆积，加 `CameraManager.targetFPS` 按时间间隔节流（low 时 15fps 丢一半帧）；根因 2：`bitrate=Standard` 自适应在弱网下不够激进，`applyEncoderQuality(.low)` 同时降码率到 **600kbps**。§2.3 加 `networkDebugInfo` + UI 调试面板（实时显示 bad/good 计数）
> - **v5.2 2026-06-22 后台→前台误触发下播修复**：用户真机反馈"切后台回来画面卡住 + 自动结束直播"。根因：iOS app 后台时 `AVCaptureSession.wasInterrupted(reason=1)` → `LiveStore.startCameraFailureWatcher` 启动 20s Task.sleep（后台仍计数）→ 回前台后误触发 `forceEnd(.cameraFailure)`。§5.2 加 reason 过滤（reason=1/4 静默不上报）；§5.3 watcher 仅 reason=2/3/5 + sessionRuntimeError 触发；CameraManager 新增 `UIApplication.willEnterForegroundNotification` 监听主动重启 session
> - **v5.3 2026-06-22 切后台→前台画面卡住深度修复**：v5.2 修了"误下播"但用户仍反馈画面卡住（调试面板 net.normal 排除网络）。深度根因 2 处：(1) `willEnterForeground` 时 `session.isInterrupted=true`，`session.startRunning()` 在 iOS 内部 silently fail——真正生效是 `AVCaptureSessionInterruptionEnded` 通知到达时；CameraManager.handleInterruptionEnded 内补 `start()`，willEnterForeground 保留作防御兜底。(2) `MetalPreviewView` 切后台时 CADisplayLink 暂停 + drawable 释放，回前台 setNeedsDisplay 时 `currentDrawable` 仍 nil 导致 draw 空跑；新增 `didEnterBackground` 调 `releaseDrawables()`，`willEnterForeground` 后延迟 300ms `setNeedsDisplay()` 等 CAMetalLayer 完全恢复
> - **v5.3.1 2026-06-22 review 加固**：3 角度对抗 review 出 6 阻塞 + 10 一般。修 4 项真阻塞 + 部分一般项：
>   (1) **MetalPreviewView.currentImage data race**（CIImage 引用类型，captureOutput background queue 写 + main queue 读，ARC 不安全可读到撕裂指针）→ `render()` 改为全 main queue 串行写
>   (2) **CameraManager.handleRuntimeError 后台静默**（Task.sleep 在 background 时 main thread 挂起但内部 mach time 仍计数，回前台后 watcher Task 醒来误触发 `forceEnd(.cameraFailure)`）→ 入口检查 `UIApplication.shared.applicationState != .background`
>   (3) **CameraManager.tearDown()** 新增 + LiveRoomView.onDisappear 调用：同步 removeObserver + 清 onFrame/onError + sessionQueue stopRunning，解决 @StateObject 延迟 deinit 期间 observer 仍响应 willEnterForeground 重启已离开 session 致摄像头灯亮 + 帧仍 mutate 已 dismissed store
>   (4) handleInterruptionEnded 先派发 onError 再 start，缩小 race window
>   附加优化：didEnterBackground 清 currentImage 消除鬼影；handleWillEnterForeground 改 DispatchWorkItem 可 cancel + `applicationState == .active` 守卫；willEnterForeground 注释纠正（不是 silently fail 而是 iOS 内部排队）
>   留 v5.4：#3 超长后台 session kill / #7 observer 改 didMoveToWindow / #13 InterruptionReason enum / #14 device.isConnected / #15 throttle / #16 Metal 资源细优化
> - **v5.3.2 2026-06-22 直播态切后台→前台仍卡住+下播 根因深挖**：用户反馈"美颜面板 OK 但直播下仍卡 + 自动下播"。深度根因：声网 SDK 在 app 后台时仍持续发 `networkQuality` 回调（SDK 自己线程），dispatch 到 `@MainActor` NetworkQualityMonitor.report 但 main thread 后台挂起 → 大量 report 排队在 main runloop。回前台瞬间 main 恢复 → backlog 一次性串行执行 → `consecutiveBadCount` 飞速 ≥30 → `forceEnd(.weakNetwork)` endType=7 误下播（用户来不及看调试面板已 dismiss）。HeartbeatController 同样隐患（后台 tick backlog）。
>   修复：NetworkQualityMonitor 监听 `UIApplication.didEnterBackground/willEnterForeground` 通知 → 后台 `isInBackground=true` 静默 + 回前台立即清零计数 + 设 **5s 冷却期**丢弃 SDK backlog；HeartbeatController.tick 入口 guard `applicationState != .background` 双保险
> - **v5.3.4 / v5.3.5 已还原**（2026-06-22）：用户决策"暂不处理后台保持推流业务，闪烁也接受"。还原内容：
>   (1) `MetalPreviewView.handleDidEnterBackground` 恢复 `currentImage = nil` 闪烁版（v5.3.1 行为）—— 闪烁不是 bug，是 AVCaptureSession 重启 1-2s 等待的视觉表现，闪烁版让"app 重连中"视觉更明确
>   (2) `CameraManager` 移除 v5.3.5 的 `lastFrame` 缓存 + `backgroundFrameTimer` 后台占位帧 relay 机制
>   (3) `Info.plist` 移除 `UIBackgroundModes: audio`；`HilyApp` 移除 AVAudioSession 配置——切后台音频也停（与视频一致）
>   PiP / 后台直播留 H/J 里程碑评估；iOS 限制相机后台访问 vs 占位帧 relay 的权衡待产品决策。当前回到 **v5.3.3 测试通过状态**
> - **v5.3.3 2026-06-22 真根因锁定：onDisappear 在 ScenePhase=.background 时被 SwiftUI 触发，tearDown 清空 onFrame 导致帧链路永久断开**。用户报告"几秒切后台回前台就复现"——v5.3.2 backlog 防御与时间线不符（5-10s 无法累 30 次回调）。3 角度 Workflow 深挖锁定真根因：
>   SwiftUI 自 iOS 14 起在 UIScene → .background 时对当前 view 调度 onDisappear（释放资源/snapshot 用），iOS 18 未变；v5.3.1 我在 onDisappear 加 `camera.tearDown()` 清 `onFrame=nil`；回前台 SwiftUI 复用 @StateObject camera + UIView，CameraPreview 走 `updateUIView`（空实现）而非 `makeUIView` → **onFrame 永远不会被重新赋值** → `captureOutput.onFrame?(processed)` 静默 no-op → `agora.pushExternalVideoFrame` 不再调用 → 推流断 → 声网持续 worst=6 → v5.3.2 冷却 5s 后开始累计 → 60s 后 `forceEnd(.weakNetwork)` 下播。
>   美颜面板不复现：sheet 半屏不触发底层 view onDisappear。
>   **修复（4 项 Fix）**：
>   - **Fix 1 onFrame 解耦 view 生命周期**：CameraPreview.makeUIView 内 `bindFrameSink(to:)`；**updateUIView 加 onFrame==nil 检查兜底重绑**——回前台 SwiftUI body 重算时自动恢复链路
>   - **Fix 2 LiveRoomView.onDisappear 加 scenePhase + state guard**：`guard scenePhase != .background, store.state == .ended else { return }`——切后台时 onDisappear 触发也不清，只有真正 dismiss（用户结束直播 + state=.ended）才 tearDown
>   - **Fix 3 AgoraManager.renewToken 加 background guard**：后台时 109/110 backlog 不触发续期，避免 URLSession 后台 timeout 累计 renewFailureCount=2 → forceEnd(.disconnected)
>   - **Fix 4 暂不加 isTornDown** 标志（Fix 2 已防住正常路径，留作 v5.4 belt-and-suspenders）

---

## §1 H5/安卓代码二次校验清单

**直接引用** `B-spec-H5安卓代码二次校验-202606192000.md`。

本 spec 负责其中 §1.4 中**非 NIMChatroomManager** 的 10 项：

1. LiveStore 抽离
2. 心跳 10s + 失败 >3 次计数
3. 心跳响应码分流
4. JSONSerialization NSNull 守卫
5. endLiveRoom 携带 endType
6. NetworkQualityMonitor
7. CameraManager 错误回调链
8. BeautyRenderer fallback
9. Agora token 续期
10. 开播前置校验（rtcToken 取数 review 已纠错：现状已对齐，无 bug）
11. userType 路由分流
12. 统一日志（裸 print → os.Logger）
13. endLive 抢跑修复

> 上列 13 条对应 §1.4 中 13 项 ❌；NIMChatroomManager 一项（含 4 处子项）归兄弟 spec。
> **review 纠错**：`LiveService.swift:42-69` 已用 `getAgoraRtmToken()` 拿 rtcToken（与 H5 一致），`LiveRoomInfo.rtcToken` 字段就是这个值——非 bug。token 续期路径（见 §7）仍是缺口。

---

## §2 LiveStore 状态机

### 2.1 状态枚举

```swift
enum LiveState: Equatable {
    case idle          // 未开播
    case preparing     // LivePrepareView 校验中
    case starting      // 三接口串行：getMyLiveRoom → beginLiveRoom → getAgoraRtmToken；声网 join 进行中
    case living        // 直播中（心跳运行 / 网络监控运行 / 公屏 active）
    case forceEnding(reason: ForceEndReason)  // 强制下播触发中（避免重复触发）
    case ending        // 用户主动 endLiveRoom 调用中
    case ended         // 已下播（持有 endType 供 UI 展示原因）
}

enum ForceEndReason: Equatable {
    case banned         // 封禁（心跳 1992 / NIM attachType=62）  → endType=2
    case disconnected   // 断连（心跳连续失败 >3 次 / NIM attachType=44） → endType=4
    case cameraFailure  // 采集失败 >20s → endType=5
    case noPermission   // 无权限（心跳 2001） → endType=6
    case weakNetwork    // 弱网连续 ≥10 次质量 5/6 → endType=7
}
```

**用户主动下播**对应 `endType=1`，不入 `ForceEndReason`，由 `LiveStore.endLive()` 入口传入。

### 2.2 状态转移图 + 各态对 forceEnd/endLive 的响应

```
        ┌─────────┐
        │  idle   │
        └────┬────┘
             │ user 进入 LivePrepareView
             ▼
        ┌─────────────┐
        │  preparing  │
        └────┬────────┘
             │ checkCanLive() 全通过 + 点开播
             ▼
        ┌─────────────┐
        │  starting   │ ── 三接口或 join 任一失败 ─▶ idle（toast）
        └────┬────────┘
             │ join success + first frame
             ▼
        ┌─────────────┐
        │   living    │ ── user 主动下播 ──▶ ending ──▶ ended(endType=1)
        └────┬────────┘
             │ forceEnd(reason)（且当前不在 forceEnding/ending）
             ▼
        ┌──────────────────────┐
        │ forceEnding(reason)  │ ── endLiveRoom(endType=reason.code) await ──▶ ended(endType=reason.code)
        └──────────────────────┘
```

| 当前态 | `forceEnd(reason:)` 行为 | `endLive()` 行为 |
|---|---|---|
| `.idle` | 忽略（log warning + return） | 忽略 |
| `.preparing` | 忽略，回 `.idle` | 回 `.idle` |
| `.starting` | **触发异常清理回 `.idle`**：取消正在串行的接口 Task；不调 endLiveRoom（房间未真正建立）；toast | 同 forceEnd |
| `.living` | 切 `.forceEnding(reason)` + teardown | 切 `.ending` + teardown |
| `.forceEnding` / `.ending` / `.ended` | **CAS 守卫**忽略（见 §2.5 并发原子性） | 同 |

### 2.3 字段定义

```swift
@MainActor
final class LiveStore: ObservableObject {
    // ─── 状态 ───────────────────────────────────────
    @Published private(set) var state: LiveState = .idle
    @Published private(set) var callState: Int = 0       // 0 直播 / 1 通话 / 2 匹配 / 3 PK（D/G 后续写入）
    @Published private(set) var endType: Int?            // 仅 ended 态有值

    // ─── 房间上下文（starting 阶段填充）───────────
    @Published private(set) var roomId: Int?
    @Published private(set) var agoraChannelId: String?
    @Published private(set) var rtcToken: String?        // 来自 getAgoraRtmToken
    @Published private(set) var yxRoomId: Int?

    // ─── 公屏/合规/折扣 字段（供 NIMChatroomManager spec 写入）───────
    @Published private(set) var onlineCount: Int = 0     // setOnlineCount 写入
    @Published private(set) var warningToast: String?    // warn(message:) 写入；UI 显示 3s 后自动清空
    @Published private(set) var boostingExposure: Bool = false  // markBoostingExposure 写入（B 不渲染 UI，仅留字段）

    // ─── 网络弱网降级提示（v5 新增；NetworkQualityMonitor 内部回调写入）
    @Published private(set) var networkWarningToast: String?    // setNetworkWarning(_:) 写入；恢复时传 nil 清空

    // ─── 美颜可用性（§6 fallback 用） ─────────────
    @Published private(set) var beautyAvailable: Bool = true    // FU setup 失败时置 false，UI 置灰美颜面板

    // ─── 监控副作用（内部）────────────────────────
    private var heartbeatFailureCount: Int = 0
    private var cameraFailureStartedAt: Date?
    private var cameraFailureWatcher: Task<Void, Never>?

    // ─── 并发原子标志 ──────────────────────────────
    private var inFlightEnd: Bool = false                 // §2.5 用同步 CAS 阻止重入

    // ─── 子模块（构造注入）────────────────────────
    private let liveService: LiveService.Type
    private let heartbeat: HeartbeatController
    private let networkMonitor: NetworkQualityMonitor
    private let agora: AgoraManager
    private let camera: CameraManager
    private let nim: NIMChatroomManager
    private let analytics: AnalyticsClient
    private let logger: Logger
}
```

### 2.4 对外入口（接口契约）

```swift
extension LiveStore {
    // ─── 生命周期（user/UI 调用）──────────────────
    func prepare()                                          // idle → preparing
    func startLive(title: String) async                    // preparing → starting → living
    func endLive() async                                    // living → ending → ended(endType=1)

    // ─── 强制下播（由 HeartbeatController / NetworkQualityMonitor / CameraManager / NIM 调用）
    func forceEnd(reason: ForceEndReason) async            // living/starting → forceEnding → ended(endType=reason.code)

    // ─── 兄弟 spec 调用入口（NIMChatroomManager）─
    func warn(message: String)                              // 仅设置 warningToast 3s（NIM attachType=61）
    func markBoostingExposure(_ enabled: Bool)              // 设置 boostingExposure 字段（NIM attachType=63）
    func setOnlineCount(_ count: Int)                       // NIMChatroomManager 进房成功绝对值（chatroom.onlineUserCount）/ leave 复位 0
    func adjustOnlineCount(by delta: Int)                   // NIMChatroomManager 进出房 delta 累计；clamp max(0, current + delta)

    // ─── NetworkQualityMonitor 内部回调入口（v5 新增）─
    func setNetworkWarning(_ text: String?)                 // 降级写文案，恢复传 nil 清空（不被 NIM 调用）

    // ─── D/G 里程碑调用入口（带状态守卫）─────────
    func setCallState(_ value: Int)                         // 守卫：仅 state==.living 时生效；ended 时自动 reset=0
}
```

`forceEnd` 与 `endLive` 的实现都包含 endLiveRoom 接口调用、声网 leave、相机 stop、心跳停止、网络监控停止、聊天室 leave 的**串行 await**——同 §10 endLive 抢跑修复。

### 2.5 并发原子性（CAS 守卫）

@MainActor 仅保证函数体内顺序执行，但 await 边界存在 reentrancy gap：若 HeartbeatController/NetworkQualityMonitor/NIM 三路同时 dispatch `Task { await store.forceEnd(...) }`，三个 Task 都可能在 `await someAsyncCall()` 处让出控制权，多源 reason 会重复进入。

解决：把"切 forceEnding 态"做成**同步 CAS**，async 入口仅做 thin wrapper：

```swift
extension LiveStore {
    /// 同步 CAS：true 表示获得 forceEnding 占用权；false 表示已有人占用
    private func tryEnterForceEnding(_ reason: ForceEndReason) -> Bool {
        guard !inFlightEnd else { return false }
        guard case .living = state else {
            // .starting → 异常清理 + 回 idle 不进 forceEnding
            if case .starting = state { abortStarting(); return false }
            return false
        }
        inFlightEnd = true
        state = .forceEnding(reason: reason)
        return true
    }

    func forceEnd(reason: ForceEndReason) async {
        guard tryEnterForceEnding(reason) else { return }      // 同步 CAS，多源并发时仅第一个赢
        do {
            try await liveService.endLiveRoom(endType: reason.code)
        } catch {
            logger.error("endLiveRoom failed during forceEnd: \(error)")  // 不阻塞清理
        }
        await teardown()
        state = .ended
        endType = reason.code
    }
}
```

`endLive()` 同样用 `inFlightEnd` 守卫；`tryEnterEnding()` 镜像逻辑。`inFlightEnd` 不在 reset——`.ended` 态进入后 LiveStore 实例理应丢弃重建（UI 通过 `dismiss()` 回到 prepare 路由）。

### 2.5b 优先级仲裁（多源 forceEnd 并发文案稳定）

> v4 修订（B-NIMChatroomManager spec 跨 spec 触发）：多源 forceEnd 同时到达（如心跳 1992 banned + NIM attachType=44 disconnected），单纯"取第一个赢"会让 endType 文案随机不可复现。引入优先级仲裁：第二源若优先级更高，**升级本地 state.reason 与 endType（仅影响 UI 文案）**，但**不重发 endLiveRoom 接口**（首源接口已发，后端 endType 取首源——race 下后端与本地可能不一致，是接受的代价）。

优先级表（高 → 低）：

| 优先级 | reason | endType | 含义 |
|---|---|---|---|
| 5 | `.banned` | 2 | 合规/封禁，最高优先级 |
| 4 | `.noPermission` | 6 | 鉴权失败 |
| 3 | `.cameraFailure` | 5 | 采集失败 |
| 2 | `.weakNetwork` | 7 | 弱网 |
| 1 | `.disconnected` | 4 | 断连，最低（兜底分类） |

```swift
extension LiveStore {
    private func priority(of reason: ForceEndReason) -> Int {
        switch reason {
        case .banned:        return 5
        case .noPermission:  return 4
        case .cameraFailure: return 3
        case .weakNetwork:   return 2
        case .disconnected:  return 1
        }
    }

    private func tryEnterForceEnding(_ reason: ForceEndReason) -> Bool {
        // 已 inFlight：检查升级
        if inFlightEnd {
            if case .forceEnding(let current) = state,
               priority(of: reason) > priority(of: current) {
                state = .forceEnding(reason: reason)           // 升级 reason
                endType = reason.code                          // 升级 endType（仅本地 UI 文案）
                logger.info("forceEnd reason upgraded: \(current) → \(reason)（接口不重发）")
            }
            return false                                       // 不触发新一轮 endLiveRoom 接口
        }
        // 首次：standard CAS
        guard case .living = state else {
            if case .starting = state { abortStarting() }
            return false
        }
        inFlightEnd = true
        state = .forceEnding(reason: reason)
        return true
    }
}
```

**埋点子分类**（v4 新增；NIM spec §3.4 + 本节）：

| reason | 来源埋点 key | 子来源 |
|---|---|---|
| `.disconnected` | `endlive_force_end` | `subSource: "heartbeat_failed"` / `"im_reconnect_failed"` |
| `.banned` | 同上 | `subSource: "heartbeat_1992"` / `"nim_attach_62"` |
| 其他 | 同上 | 各 reason 单一来源不需子分类 |

`subSource` 字段由触发方在调用 `forceEnd(reason:subSource:)` 时传入（forceEnd 签名 v4 加可选参数 `subSource: String? = nil`，写入埋点不影响业务）。

---

## §3 HeartbeatController

### 3.1 间隔与触发

- 间隔：**10000 ms**（对齐安卓；H5 6000ms 与"10秒"注释均废弃）
- 启动：`state` 切到 `.living` 时由 LiveStore 启动
- 停止：`state` 离开 `.living` 时立即停止（teardown 第一步）
- 实现：`Task` 链 + `try await Task.sleep(nanoseconds: 10_000_000_000)`，可取消

### 3.2 失败计数 >3 → 断连下播

```swift
private func tick() async {
    do {
        try await liveService.heartbeat(roomId: roomId, callState: store.callState)
        heartbeatFailureCount = 0
    } catch HeartbeatError.banned {
        await store.forceEnd(reason: .banned)            // 1992/1006
    } catch HeartbeatError.noPermission {
        await store.forceEnd(reason: .noPermission)      // 2001
    } catch {
        heartbeatFailureCount += 1
        logger.warning("heartbeat failed (\(heartbeatFailureCount)/3): \(error)")
        if heartbeatFailureCount > 3 {
            await store.forceEnd(reason: .disconnected)  // endType=4
        }
    }
}
```

### 3.3 响应码分流（必须读 code）

`LiveService.heartbeat` 现状 `LiveService.swift:81-84` 函数签名 + `LiveRoomView.swift:70` 调用方用 `try?` 静默吞错。改造：

```swift
// LiveService.swift
static func heartbeat(roomId: Int, callState: Int) async throws -> String {
    let body: [String: Any] = ["roomId": roomId, "callState": callState]
    guard JSONSerialization.isValidJSONObject(body) else {       // §3.4 NSNull 守卫
        throw HeartbeatError.invalidPayload
    }
    let data = try await APIClient.shared.post("/api/agora/liveHeartBeatV2", body: body)
    let env = try APIClient.shared.decodeEnvelope(data)
    switch env.code {
    case "0000": return env.code
    case "1992", "1006": throw HeartbeatError.banned
    case "2001": throw HeartbeatError.noPermission
    default: throw HeartbeatError.unknown(code: env.code, message: env.message)
    }
}
```

**禁止 `try?`**——CLAUDE.md `.claude/rules/error-handling.md` 已明令。

### 3.4 JSONSerialization NSNull 守卫

CLAUDE.md 已知坑：`JSONSerialization.data` 对 `NSNull`（如心跳 `result:null`）会抛 OC 异常且 `try?` 不捕获 → 崩溃。

- 上行 body：§3.3 已加 `isValidJSONObject` 守卫
- 下行响应：APIClient 层统一处理（沿用 60% 阶段已修方案）

### 3.5 callState 由 LiveStore 推导回写

- 阶段一（B 里程碑）：恒为 `0`
- D 里程碑：CallStore 写 `setCallState(1)`，结束写 `setCallState(0)`
- G 里程碑：PKStore 写 `setCallState(3)`

`setCallState` 加 `guard state == .living else { return }` 守卫（详见 §2.4）；切到 `.ended` 时由 teardown 重置为 `0`。HeartbeatController 通过 `store.callState` 读取（解耦）。

---

## §4 NetworkQualityMonitor

### 4.1 订阅声网回调

```swift
// AgoraRtcEngineDelegate
func rtcEngine(_ engine: AgoraRtcEngineKit,
               networkQuality uid: UInt,
               txQuality: AgoraNetworkQuality,
               rxQuality: AgoraNetworkQuality) {
    guard uid == 0 else { return }
    monitor.report(tx: txQuality, rx: rxQuality)
}
```

### 4.2 弱网下播阈值（v4 单一阈值；**v5 已被 §4.5 三阈值分层覆盖**，本节保留历史）

> ⚠️ v5 修订：本节"一次性触发 ≥10 → forceEnd"模型已被 §4.5 分层覆盖。
> 代码实现以 §4.5 为准：≥10 降级（15fps+toast）/ ≥30 forceEnd / ≥5 连续好 recover。
> 保留本节为历史决策档案。

- 单一阈值：**连续 ≥10 次质量 5/6**（vBad/Down）→ `store.forceEnd(reason: .weakNetwork)` → endType=7
- 同阈值同时触发埋点 `c_log_networkBad`（H5 双阈值 10+30 弃用）

```swift
final class NetworkQualityMonitor {
    private(set) var isRunning = false
    private var consecutiveBadCount = 0
    private var alreadyTriggered = false                  // 一次性触发标志

    func start() { isRunning = true; alreadyTriggered = false; consecutiveBadCount = 0 }
    func stop()  { isRunning = false }                    // teardown 调用
    func reset() { consecutiveBadCount = 0; alreadyTriggered = false }  // pause/resume 配套

    func report(tx: AgoraNetworkQuality, rx: AgoraNetworkQuality) {
        guard isRunning, !alreadyTriggered else { return }
        let worst = max(tx.rawValue, rx.rawValue)
        if worst >= 5 {
            consecutiveBadCount += 1
            if consecutiveBadCount >= 10 {                // ≥10 而非 ==10
                alreadyTriggered = true
                analytics.track("c_log_networkBad")
                Task { await store.forceEnd(reason: .weakNetwork) }
            }
        } else {
            consecutiveBadCount = 0
        }
    }
}
```

### 4.3 PK 期间 pause/resume 钩子

B 不实现 PK，但提供 `pause() / resume()` 接口供 G 里程碑 PKStore 调用：

```swift
func pause()  { isRunning = false }                       // 不 reset 计数，PK 结束 resume 继续
func resume() { isRunning = true }
```

### 4.4 生命周期与 §3.1 心跳对齐

- LiveStore 进入 `.living` 时：`heartbeat.start()` + `networkMonitor.start()`
- LiveStore 离开 `.living`（teardown 入口）：`heartbeat.stop()` + `networkMonitor.stop()`
- 后续声网回调到达时 `isRunning == false` 立即 return（§4.2 已守卫）

### 4.5 弱网分层降级（v5 覆盖 §4.2 单一阈值）

> v5 修订：原 §4.2 "≥10 次直接 forceEnd" 改为三档分层；产品反馈用户感知零、突然下播体验差，加 toast + 降帧率中间态。
> 与路线图 §2 #5 "≥10 次"决策冲突，已由用户授权 v5 调整。

| 状态 | 触发条件 | 动作 |
|---|---|---|
| `.normal` → `.degraded` | 连续 ≥ **10 次**质量 5/6（≈20s） | (a) `agora.applyEncoderQuality(.low)` 30→15fps；(b) `store.setNetworkWarning(L10n.networkWarning)` 显示蓝色条幅 |
| `.degraded`（保持） | 第 11-29 次 | 无额外动作，等待恢复或恶化 |
| `.degraded` → `.normal` | 降级期内连续 ≥ **5 次**质量 ≤4（≈10s 网络好转） | (a) `applyEncoderQuality(.normal)` 15→30fps；(b) `setNetworkWarning(nil)` 清条幅 |
| `.degraded` → `.ended` | **连续** ≥ **30 次**质量 5/6（≈60s；中间任一次质量 ≤4 即清零重计） | `store.forceEnd(.weakNetwork, sub: "network_bad_30")` → endType=7 |
| `.ended` | 一次性 | 后续 report 全部 return |

阈值常量：`warnThreshold=10` / `endThreshold=30` / `recoverThreshold=5`。
设计意图：先降级给用户感知 + 给网络 ~40s 恢复窗口；不恢复才走兜底下播。

```swift
// AgoraManager 编码档位（v5 新增）
enum EncoderQuality { case normal, low }    // normal=720×1280/30fps；low=720×1280/15fps（保分辨率仅降帧率）
func applyEncoderQuality(_ q: EncoderQuality)
```

---

## §5 CameraManager 错误回调链

### 5.1 增加 `onError` callback

```swift
final class CameraManager {
    var onError: ((CameraError) -> Void)?
    enum CameraError: Equatable {
        case permissionDenied                 // 权限拒绝（立即提示）
        case sessionRuntimeError(NSError)     // AVCaptureSessionRuntimeError
        case wasInterrupted(reason: AVCaptureSession.InterruptionReason)
        case interruptionEnded
    }
}
```

CameraManager **不持有 20s 计时**——它只产生事件。

### 5.2 监听三个系统通知 + v5.2 reason 过滤

```swift
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionRuntimeError,
    object: session,
    queue: .main
) { [weak self] note in
    let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError) ?? defaultErr
    self?.onError?(.sessionRuntimeError(err))
}
// + AVCaptureSessionWasInterrupted / AVCaptureSessionInterruptionEnded
// + UIApplication.willEnterForegroundNotification → 主动 start() 重启 session（v5.2）
```

**v5.2 wasInterrupted reason 过滤**（避免后台切换误触发 watcher → forceEnd）：

| `AVCaptureSession.InterruptionReason` | rawValue | 上报 onError？ | 说明 |
|---|---|---|---|
| `videoDeviceNotAvailableInBackground` | 1 | ❌ 静默 | app 进入后台，最常见误触发源 |
| `audioDeviceInUseByAnotherClient` | 2 | ✅ 上报 | 音频被其它 app 占用 |
| `videoDeviceInUseByAnotherClient` | 3 | ✅ 上报 | 相机被其它 app 占用 |
| `videoDeviceNotAvailableWithMultipleForegroundApps` | 4 | ❌ 静默 | iPad 多任务 |
| `videoDeviceNotAvailableDueToSystemPressure` | 5 | ✅ 上报 | 散热限流 / 系统压力 |

静默 reason 不调 `onError(.wasInterrupted)`，CameraManager 内部 logger.info 留痕；session 恢复仍由 `UIApplication.willEnterForegroundNotification` 触发 `start()` 自动 restart。

### 5.3 LiveStore 内独立 watcher 负责 20s 累计

**职责切清**：CameraManager 只发事件；LiveStore 持有 `cameraFailureStartedAt` + `cameraFailureWatcher`：

```swift
// LiveStore
func onCameraError(_ error: CameraManager.CameraError) {
    switch error {
    case .permissionDenied:
        // 不入 20s 累计：立即弹 alert 提示去设置 + 退到 idle
        Task { await abortStarting() }
        permissionDeniedAlert = true
    case .sessionRuntimeError, .wasInterrupted:
        startCameraFailureWatcher()
    case .interruptionEnded:
        stopCameraFailureWatcher()                        // 清零
    }
}

private func startCameraFailureWatcher() {
    guard cameraFailureStartedAt == nil else { return }
    cameraFailureStartedAt = Date()
    cameraFailureWatcher = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        guard let self, self.cameraFailureStartedAt != nil else { return }
        await self.forceEnd(reason: .cameraFailure)
    }
}

private func stopCameraFailureWatcher() {
    cameraFailureStartedAt = nil
    cameraFailureWatcher?.cancel()
    cameraFailureWatcher = nil
}
```

---

## §6 BeautyRenderer fallback + UI 反馈

### 6.1 FUBeautyRenderer.init 改 throws + setup 超时

```swift
final class FUBeautyRenderer: BeautyRendering {
    init(authPack: Data) throws {
        let start = Date()
        guard FUManager.shared.setupSync(authPack: authPack) else {
            throw BeautyError.setupFailed
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 0.5 {                                // setup >500ms 也算失败 fallback
            throw BeautyError.setupTimeout(elapsed: elapsed)
        }
    }
}
```

setup >500ms 容忍上限避免阻塞 startLive（startLive 在 starting 态本身已是 100-300ms 接口串行 + join，再叠 1s+ 美颜 setup 会让用户感知卡顿）。

### 6.2 失败自动降级 + LiveStore 标记

```swift
let renderer: BeautyRendering = {
    do {
        return try FUBeautyRenderer(authPack: authpack)
    } catch {
        logger.error("FaceUnity setup failed, falling back to passthrough: \(error)")
        analytics.track("c_beauty_fallback", properties: ["error": "\(error)"])
        Task { @MainActor in store.markBeautyUnavailable() }
        return PassthroughRenderer()
    }
}()
```

LiveStore 新增 `markBeautyUnavailable()` → 设 `beautyAvailable = false`。

### 6.3 UI 反馈

LiveRoomView 的"美颜"按钮：

```swift
Button("美颜") { showBeautyPanel = true }
    .disabled(!store.beautyAvailable)
    .overlay(alignment: .topTrailing) {
        if !store.beautyAvailable {
            Text(L10n.beautyUnavailableHint).font(.caption2)
        }
    }
```

降级是用户**可感知但不阻塞开播**——开播正常，仅美颜面板灰掉 + 顶部条幅提示。运行时无法切回 FU（重启 app 才会重试 setup）。

---

## §7 Agora token 续期

### 7.1 监听 `tokenPrivilegeWillExpire`

现状 `AgoraManager.swift:157-161` 仅赋值 `self.message`，无 `renewToken` 调用：

```swift
// 现状
func rtcEngine(_ engine: AgoraRtcEngineKit,
               tokenPrivilegeWillExpire token: String) {
    self.message = "token will expire"     // ← 仅赋字段，不续期
}
```

改为：

```swift
func rtcEngine(_ engine: AgoraRtcEngineKit,
               tokenPrivilegeWillExpire token: String) {
    Task {
        do {
            let res = try await LiveService.getAgoraRtmToken()   // 复用现有接口
            guard let newToken = res.rtcToken else { throw AgoraError.tokenEmpty }
            engine.renewToken(newToken)
            logger.info("Agora token renewed")
        } catch {
            logger.error("Agora token renew failed: \(error)")
            await store.forceEnd(reason: .disconnected)          // 续期失败按断连下播
        }
    }
}
```

### 7.2 error code 109/110 兜底

声网 `didOccurError`：
- 109 = token 过期
- 110 = token 无效

**同链路**进 7.1 的续期流程；两次续期失败仍报错 → `store.forceEnd(reason: .disconnected)`。

### 7.3 续期 token 入参

`LiveService.getAgoraRtmToken()` 接口（`LiveService.swift:42-45`）入参为空 body，鉴权头带 `loginToken`/`anchorToken` 即可——绑 uid 隐含在登录态。CLAUDE.md 集成事实"主播加入声网的 rtcToken 来自 `/api/index/getAgoraRtmToken`（绑 uid、与 channel 无关）"已对齐。

---

## §8 开播前置校验

### 8.1 现状

`LivePrepareView` 仅 title 非空校验；`LiveService.startLive` (`LiveService.swift:51-53`) 仅 cover 非空校验。

### 8.2 补全（对齐 H5 `checkCanLive`）

```swift
// LivePrepareView
func checkCanLive() throws {
    guard !title.trimmed.isEmpty else { throw PrepareError.titleEmpty }
    guard cover != nil else { throw PrepareError.coverEmpty }
    let lastEndAt = UserDefaults.standard.object(forKey: "lastEndAt") as? Date
    guard Date().timeIntervalSince(lastEndAt ?? .distantPast) >= 60 else {
        throw PrepareError.cooldown(remainingSeconds: 60 - elapsed)
    }
    guard nim.isLoggedIn else { throw PrepareError.imOffline }
}
```

四项 fail 时 LivePrepareView toast 提示（走 `Localizable.strings`，详见 §13.i18n 声明），**不触发 startLive**。

### 8.3 lastEndAt 持久化

写 `UserDefaults`（绝对时间差，非业务跨日，不涉时区——CLAUDE.md `Asia/Shanghai` 业务日期规则不适用本场景；若未来涉跨日业务须切 Asia/Shanghai）。

### 8.4 rtcToken 取数（无需修改）

`LiveService.swift:42-69` 已正确调 `getAgoraRtmToken()` 拿 rtcToken（与 H5 一致）。本节**仅记录现状已对齐**，不改代码。

---

## §9 userType 路由分流

### 9.1 字段已解析未消费

- `AuthModels.swift:10` 含 `userType: Int`（已解析）
- `RootView.swift:4-14` 仅 isLoggedIn 二分（未消费 userType）

### 9.2 分流规则

| userType | 含义 | 路由 |
|---|---|---|
| 2 | 已审核主播 | `HomeView`（含 LivePrepareView 入口） |
| 9 | 代理 | `AgentRestrictedView`（仅钱包/收益） |
| 其他 | 未审核/异常 | `MineRestrictedView`（仅个人中心） |
| token 失效 1005 | — | 登出回 LoginView |
| 封禁 1992/1006 | — | 登出 + toast |

```swift
struct RootView: View {
    @EnvironmentObject var session: SessionStore
    var body: some View {
        if !session.isLoggedIn { LoginView() }
        else {
            switch session.userType {
            case 2: HomeView()
            case 9: AgentRestrictedView()
            default: MineRestrictedView()
            }
        }
    }
}
```

封禁/token 失效的登出逻辑由 APIClient 错误码统一分流（B 里程碑工程化收尾的一部分）。

---

## §10 endLive 抢跑修复 + 日志收敛

### 10.1 endLive 抢跑

现状 `LiveRoomView.swift:178`（或同语义位置）：

```swift
// 现状
Button("结束直播") {
    Task { try? await liveService.endLiveRoom() }    // 调用方 try? 吞错
    agora.leave()                                     // 不等接口
    dismiss()                                         // 不等接口
}
```

改为：

```swift
Button("结束直播") {
    Task { @MainActor in
        await store.endLive()                         // 内部 inFlightEnd CAS + 串行 await
        dismiss()
    }
}
```

`store.endLive()` 实现：

```swift
func endLive() async {
    guard tryEnterEnding() else { return }            // 同步 CAS
    do {
        try await LiveService.endLiveRoom(endType: 1)
    } catch {
        logger.error("endLiveRoom failed: \(error)")
    }
    await teardown()
    state = .ended
    endType = 1
    UserDefaults.standard.set(Date(), forKey: "lastEndAt")  // §8.3 用
}
```

### 10.2 endType 必须传

`LiveService.endLiveRoom` 函数签名（`LiveService.swift:87-89`）加 `endType: Int` 参数；调用点：

- 用户主动：`endType: 1`
- forceEnd 分支：`endType: reason.code`（见 §11）

### 10.3 print → os.Logger

工程化收尾：`LiveService.swift:60,98,103,106` + `AgoraManager.swift` + `CameraManager.swift` + `LiveRoomView.swift` 内全部裸 `print` 替换为：

```swift
import os
private let logger = Logger(subsystem: "com.anchor.livechat", category: "Live")
logger.info("...")
logger.warning("...")
logger.error("...")
```

---

## §11 endType 数字编码统一表（**本表覆盖 CLAUDE.md 字符串映射**）

| endType | 触发来源 | 中文含义 | 触发链路 |
|---|---|---|---|
| **1** | 用户点结束直播 | 主动 | `store.endLive()` |
| **2** | 心跳响应 1992/1006 / NIM attachType=62 | 封禁 | `store.forceEnd(.banned)` |
| **4** | 心跳连续失败 >3 次 / NIM attachType=44 / 声网 token 续期失败 | 断连/系统强制 | `store.forceEnd(.disconnected)` |
| **5** | CameraManager 持续失败 >20s | 采集失败 | `store.forceEnd(.cameraFailure)` |
| **6** | 心跳响应 2001 | 无权限 | `store.forceEnd(.noPermission)` |
| **7** | NetworkQualityMonitor **连续** ≥30 次（v5；先连续 ≥10 次降级 15fps+toast 见 §4.5；连续语义：中间一次质量 ≤4 即清零重计） | 弱网 | `store.forceEnd(.weakNetwork)` |

> **本表为 iOS B 里程碑落地形态，覆盖 CLAUDE.md「关键集成事实 · 强制下播 5 原因」中 H5 字符串编码 `'3'/'4'/'5'/'99'`** —— H5 字符串映射保留作为"H5 历史现状"参考（CLAUDE.md 同步加注脚），iOS 实现按本表数字编码与路线图 §三 B 决策对齐安卓。

---

## §12 对外接口契约（NIMChatroomManager spec 调用入口）

兄弟 spec 中 ComplianceMessageParser / GiftMessageParser **不直接调 endLiveRoom 接口**，而是调本 spec 定义的 LiveStore 入口：

| NIM 触发 | LiveStore 调用 | 结果 |
|---|---|---|
| attachType=44（强制下播） | `store.forceEnd(reason: .disconnected)` | endType=4 |
| attachType=61（合规警告） | `store.warn(message: ...)` | 仅 warningToast 字段，UI 显示 3s 自动清空，不下播 |
| attachType=62（封禁下播） | `store.forceEnd(reason: .banned)` | endType=2 |
| attachType=63（进折扣池） | `store.markBoostingExposure(true)` | 仅 boostingExposure 字段；B 不渲染 UI（H 里程碑接入） |
| 公屏进房成功（chatroom.onlineUserCount 绝对值） | `store.setOnlineCount(_:)` | 写入 onlineCount 字段 |
| 公屏 leave 复位 | `store.setOnlineCount(0)` | onlineCount → 0 |
| 公屏进出房 delta | `store.adjustOnlineCount(by:)` | NIM 进/出房 delta 累计；clamp `max(0, current + delta)` |

> ⚠️ v5 注：`networkWarningToast` 由 `NetworkQualityMonitor` 内部 degrade/recover 路径调 `setNetworkWarning(_:)` 写入，**不在 NIM 触发表范围**（避免后续会话误以为 NIM 也可写入这字段）。

LiveStore 是**主播端业务状态的唯一收口**——NIM 消息解析层只产出"事件"，由 LiveStore 决定是否触发 endLiveRoom 接口、传什么 endType。

---

## §13 真机验收 DoD（Definition of Done）

> **i18n 声明**：本节所有用户可见文案（toast / alert / 条幅）实现时必须走 `Localizable.strings` key，本表内出现的中文仅为说明文字。CLAUDE.md `i18n（en/ar/tr）` 约束适用，B 里程碑用 en 默认值占位，文案翻译归 J 里程碑收尾。

| # | 验收场景 | 预期 | 工具/手段 |
|---|---|---|---|
| 1 | 心跳基线 | 间隔严格 10s（±200ms）；30s 内识别断连下播 | 抓包看 `/api/agora/liveHeartBeatV2` 请求时间戳 |
| 2 | 心跳连续失败 >3 | 第 4 次失败触发 endType=4，UI 跳"网络异常已断连"（i18n key） | Mock 后端返回错误 / 拔网线 |
| 3 | 心跳封禁码 1992 | 触发 endType=2，UI 跳"账号违规已封禁" | 后端测试账号触发 1992 |
| 4 | 心跳无权限 2001 | 触发 endType=6，UI 跳"权限校验失败" | 后端 mock |
| 5a | 网络质量 ≥10 次极差（v5 §4.5 降级） | 顶部蓝色条幅"网络较差，已切换低帧率"；声网 fps 30→15；**不下播** | Network Link Conditioner Edge |
| 5b | 5a 后网络恢复（连续 ≥5 次质量好，≈10-15s 内） | 条幅消失；fps 15→30 | NLC 关闭后等 10-15s 观察 |
| 5c | 网络质量 ≥30 次极差（≈60s 仍未恢复） | 触发 endType=7，UI 跳"网络环境过差" | NLC Edge 持续 1 分钟+ |
| 6 | 相机持续失败 >20s | 触发 endType=5 | 直播中触发 RuntimeError 后等 20s |
| 6a | **v5.2：切后台 60s 回前台不下播** | 画面 1-2s 内恢复；不触发 forceEnd；Console 看到 "background-type interruption (reason=1); not reporting" + "App will enter foreground; ensure capture session is running" | 直播中按 Home → 等 60s → 回 Hily |
| 6b | **v5.2：被其它相机 app 占用** | 触发 toast "相机被占用"；20s 内未恢复才下播 endType=5 | 直播中切到原生相机 app，等 20s+ |
| 7 | 相机权限拒绝 | 立即 alert + 跳设置；不进 living | 系统设置关闭相机权限后启动 |
| 8 | 美颜 setup 失败 / 超时 | 自动降级 Passthrough；美颜按钮置灰；顶部条幅提示 | 临时替换 authpack 为无效 / mock setup 慢 |
| 9 | 声网 token 续期 | 直播持续后 mock token TTL=30s，续期日志可见，推流不中断 | 真机 + 日志监控 |
| 10 | 用户主动下播 | endType=1 入参传到后端；await endLiveRoom 完成后才 dismiss | 抓包 + UI 观察 |
| 11 | 多源 forceEnd 并发（**v4 优先级仲裁**） | 仅触发一次 endLiveRoom 接口（首源）；本地 state.reason 与 endType 取**最高优先级源**（§2.5b：banned > noPermission > cameraFailure > weakNetwork > disconnected） | Mock 心跳 1992（banned）+ NIM 44（disconnected）同时到，验证本地 endType=2、UI 文案"封禁" |
| 12 | rtcToken 取数 | 抓包确认 `/api/index/getAgoraRtmToken` 调用；声网 join 用其返回（**现状已对齐，回归验证而非新功能**） | 抓包 |
| 13 | 开播前置校验 | title/cover 空 → toast；距上次下播 <60s → toast；IM 离线 → toast | UI 各场景验证 |
| 14 | userType=2 主播 | 进 HomeView；userType=9 进 AgentRestricted；其他进 MineRestricted | 后端切账号验证 |
| 15 | 日志无裸 print | Console.app 过滤 `subsystem:com.anchor.livechat`，所有 Live 日志可见，无裸 print | grep `Sources/Live/` `Sources/Camera/` 等无裸 print |

**全部 15 项通过**方可关闭 B 里程碑，进 D。

---

## §14 实施任务清单（implement 阶段拆分）

按依赖排序。每项给：影响文件、新建/修改、估时（人/天）、建议 commit scope。

| # | 任务 | 影响文件 | 新/改 | 估时 | commit scope |
|---|---|---|---|---|---|
| 1 | `LiveStore` 状态机骨架 + 字段 + 入口 | `Sources/Live/LiveStore.swift`（新） | 新 | 0.5 | `feat: [直播状态机]` |
| 2 | `LiveState` / `ForceEndReason` 枚举 + endType 映射 | `Sources/Live/LiveState.swift`（新） | 新 | 0.2 | `feat: [直播状态机]` |
| 3 | `LiveStore` 同步 CAS（tryEnterForceEnding / tryEnterEnding / inFlightEnd） | `Sources/Live/LiveStore.swift` | 改 | 0.3 | `feat: [直播状态机]` |
| 4 | `LiveService.heartbeat` 改 throws + NSNull 守卫 + code 分流 | `Sources/Live/LiveService.swift` | 改 | 0.5 | `feat: [直播心跳]` |
| 5 | `LiveService.endLiveRoom` 加 endType 参数 | 同上 | 改 | 0.2 | `feat: [直播下播]` |
| 6 | `HeartbeatController` 实现（10s / >3 / 响应分流） | `Sources/Live/HeartbeatController.swift`（新） | 新 | 0.5 | `feat: [直播心跳]` |
| 7 | `NetworkQualityMonitor` 实现（一次性触发 + start/stop/reset/pause/resume） | `Sources/Live/NetworkQualityMonitor.swift`（新） | 新 | 0.5 | `feat: [直播网络监控]` |
| 8 | `AgoraManager` 接 `networkQuality` 转发 monitor | `Sources/Agora/AgoraManager.swift` | 改 | 0.2 | `feat: [直播网络监控]` |
| 9 | `CameraManager.onError` 三类系统通知监听 | `Sources/Camera/CameraManager.swift` | 改 | 0.5 | `feat: [相机错误回调]` |
| 10 | `LiveStore` 接 CameraManager 错误（含 20s watcher Task） | `Sources/Live/LiveStore.swift` | 改 | 0.3 | `feat: [相机错误回调]` |
| 11 | `FUBeautyRenderer.init` 改 throws + setup 超时 + Passthrough fallback | `Vendor/FaceUnity/FUBeautyRenderer.swift` + `Sources/Beauty/BeautyRenderer.swift` | 改 | 0.3 | `feat: [美颜降级]` |
| 12 | LiveStore.beautyAvailable + LiveRoomView UI 反馈 | `Sources/Live/LiveStore.swift` + `LiveRoomView.swift` | 改 | 0.2 | `feat: [美颜降级]` |
| 13 | Agora token 续期（tokenPrivilegeWillExpire + 109/110） | `Sources/Agora/AgoraManager.swift` | 改 | 0.5 | `feat: [声网token续期]` |
| 14 | `LivePrepareView` 加 checkCanLive 前置校验 | `Sources/Live/LivePrepareView.swift` | 改 | 0.3 | `feat: [开播前置校验]` |
| 15 | `RootView` userType 分流 + AgentRestrictedView / MineRestrictedView 占位 | `Sources/Home/RootView.swift` + 2 个新 View | 改+新 | 0.5 | `feat: [userType路由]` |
| 16 | `endLive` 抢跑修复（store.endLive await + teardown） | `Sources/Live/LiveStore.swift` + `LiveRoomView.swift` | 改 | 0.2 | `fix: [下播抢跑]` |
| 17 | 裸 print → os.Logger（约 16 处） | `LiveService` / `AgoraManager` / `CameraManager` / `LiveRoomView` 等 | 改 | 0.3 | `refactor: [*]` |
| 18 | 真机回归 DoD 15 项 | — | 验证 | 1.0 | `chore: [*]` |

**总估时**：6.5 人/天（约 1.3 周单人）

**依赖顺序**：1→2→3 → 4→5→6 → 7→8 并行 → 9→10 → 11→12 → 13 → 14 → 15 → 16→17 → 18

可与 `B-NIMChatroomManager完善-spec.md` 的实施任务**并行**（无文件冲突；接口契约 §12 已明确）。

---

## §15 风险与未决项

| 风险 | 描述 | 缓解 |
|---|---|---|
| 安卓源码本地不可达 | 心跳响应 1992/1006/2001 的具体 body 字段未取到样本 | implement 阶段抓 dev 真实样本对齐；用户补全安卓源码访问优先 |
| 后端 endType=2001 行为未知 | H5 无 2001 分支 | 等后端确认路线图 §7.3 #10 三端心跳统一时一并对齐入参 |
| FU authpack bundleId 绑定有效期 | 路线图 §7.2 #9 待对齐 | 联系相芯确认 dev/prod 双绑定到期日 |
| 美颜降级埋点字段定义 | `c_beauty_fallback` 后端可能无埋点 | 接 ThinkingData 前先 logger.error 留痕（J 里程碑收尾） |
| Swift @MainActor reentrancy gap 实测 | §2.5 CAS 设计基于推理，未实测多源并发场景 | implement 阶段写 unit test：3 个 Task 同时 forceEnd 验证仅一个赢 |
| Localizable.strings 文件未建立 | B 实施时引用 `L10n.xxxKey` 但 strings 文件不存在 | 建一个 stub strings 文件占位 en 默认值，J 里程碑补全翻译 |
| forceEnd subSource 埋点字段名（v4） | §2.5b 引入 `subSource` 区分 `heartbeat_failed` / `im_reconnect_failed` 等，但后端埋点字段名待定 | implement 期间与后端对齐字段名（推荐 `subSource`），不阻塞主流程 |
| 优先级仲裁与后端 endType 不一致（v4） | §2.5b 升级 reason 但不重发接口——race 下后端 endType 取首源、本地 UI 文案取最高优先级 | 接受代价；后续若产品反馈用户困惑可加二次接口调用（B 不实现） |

未决项**不阻塞 B implement 启动**，但需在 implement 期同步推进。
