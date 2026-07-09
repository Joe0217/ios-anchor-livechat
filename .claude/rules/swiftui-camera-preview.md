# SwiftUI 相机预览 / RTC 渲染稳定性

## 1. switch case 内重复出现的子 View 必须用 if 链承载

SwiftUI 把 `switch` case 内的每个分支视为**不同位置**的 view，跨 case 切换会
触发 `dismantleUIView` + 重建（含 UIViewRepresentable 包装的 MTKView /
AgoraRtcVideoCanvas 持有 view）。CallFaceTimeView 横跨 `.calling / .connecting
/ .connected` 三态——必须放在**同一 if 分支**或用 `.id(...)` 强制 identity
稳定。

正例：
```swift
if shouldShowWaiting {
    CallWaitingView(store: store)
} else if isInCallOrConnecting {
    CallFaceTimeView(store: store, liveCamera: liveCamera, liveBeauty: liveBeauty)
}
```

反例：
```swift
switch store.state {
case .calling: CallWaitingView(store: store)
case .connecting: CallFaceTimeView(store: store, ...)
case .connected: CallFaceTimeView(store: store, ...)   // ❌ 与上一行不同位置
}
```

## 2. UIViewRepresentable 包装的强持有 UIView 单例禁止反复 makeUIView

MTKView / `AgoraManager.remoteView` 这类**持外部强引用**的 UIView 单例，被
父结构 reload 触发反复 makeUIView 会导致：
- MTKView：实例切换 → 本端画面卡帧
- AgoraRtcVideoCanvas.view：SDK 远端首帧渲染丢失 → 对端黑屏

### 正解模式：按业务 key 在 manager 侧维 UIView 池

派对房一房多视频位（≤13 个）场景，`.id()` 不足以解决——多 representable
实例必须各自取**独立稳定 UIView**。

```swift
// manager 侧持池字典
final class PartyRTCEngine {
    private var seatIndexToView: [Int: UIView] = [:]
    @MainActor func acquireRemoteView(seatIndex: Int) -> UIView {
        if let v = seatIndexToView[seatIndex] { return v }
        let v = UIView()
        seatIndexToView[seatIndex] = v
        return v
    }
}

// representable 侧 makeUIView 取池、updateUIView no-op
struct PartyRemoteVideoView: UIViewRepresentable {
    let seatIndex: Int
    let engine: PartyRTCEngine
    func makeUIView(context: Context) -> UIView {
        engine.acquireRemoteView(seatIndex: seatIndex)
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
```

**关键不变量**：UIView 实例生命周期跟 **业务上下文（房间/通话）** 一致，
不跟 SwiftUI view 生命周期一致。绑定/清理由 manager 内 `bindRemoteVideo(key:, uid:)`
幂等接口做（换人自动清旧 uid），退场景统一 `releaseAllRemoteViews()` 清池。

适用：派对房视频位（key=seatIndex）/ 1v1 通话远端 / 直播 PK 远端（key=remoteUid）
/ 任何 N 路视频流并存的场景。

## 3. CameraManager 帧分发必须用 subscribers 字典（禁用单闭包）

**来源**：v5.3.3~v5.7 单闭包 onFrame 多次修补失败（守卫 nil / 强制重绑均无效），
v5.8 立"订阅字典"新规则（2026-06-22）。

**单闭包失败根因**：直播私 call 期间本体 CameraPreview + PIP 需要**同时**收帧，
但单闭包会被 PIP `bindFrameSink` 覆盖本体；overlay 内 PIP dismantle 时，SwiftUI
不会触发 ZStack 兄弟节点（本体）的 updateUIView → 本体永远拿不到重绑时机 →
onFrame 指向 weak nil 的旧闭包 → 本端断流 + 直播观众端断流。

**正确做法**：
- `CameraManager` 用 NSLock + `[ObjectIdentifier: (CVPixelBuffer) -> Void]` 字典
- 暴露 `subscribe(key, sink)` / `unsubscribe(key)` API
- `captureOutput` 锁内拷贝 sink snapshot、锁外分发（避免长持锁阻塞 main queue subscribe）
- `CameraPreview` 加 `Coordinator`：
  - `makeCoordinator()` 创建；`makeUIView` / `updateUIView` 调 `coordinator.attach(view:agora:)`
    内部 `camera.subscribe(ObjectIdentifier(self), sink)`
  - `static func dismantleUIView(_:coordinator:)` 调 `coordinator.detach()` 精确注销
- 每个 CameraPreview view 持有独立 key → PIP dismantle 仅注销 PIP 那一格，本体 sink
  始终留在字典里——**不依赖任何 SwiftUI re-eval 时机**

```swift
// CameraManager.swift
private let subscribersLock = NSLock()
private var subscribers: [ObjectIdentifier: (CVPixelBuffer) -> Void] = [:]
func subscribe(_ key: ObjectIdentifier, sink: @escaping (CVPixelBuffer) -> Void) { ... }
func unsubscribe(_ key: ObjectIdentifier) { ... }

// CameraPreview.swift
static func dismantleUIView(_ uiView: MetalPreviewView, coordinator: Coordinator) {
    coordinator.detach()   // ✓ 精确注销自己那一格
}
```

反例（禁止回退）：`var onFrame: ((CVPixelBuffer) -> Void)?` 单闭包 / `updateUIView`
每次强制重绑（依赖 SwiftUI re-eval 时机不可靠）。

## 4. MTKView 切后台保留 currentImage 作为最后一帧占位

`didEnterBackground` 内**禁止** `currentImage = nil`，仅 `releaseDrawables()`
释放 GPU 资源。回前台 setNeedsDisplay 立刻渲染最后一帧 → 真新帧
（AVCaptureSession 重启 1-2s 后到达）通过 render(_:) 自然替换，视觉无空窗黑屏。

## 5. 声网 sharedEngine 复用 singleton 时必须显式 setChannelProfile

`AgoraRtcEngineKit.sharedEngine(with:delegate:)` 第二次调用复用 singleton 并
**忽略**新 config——`channelProfile` 仍是首次创建时的值。直播 `.liveBroadcasting`
与 1v1 通话 `.communication` 切换时，必须在 sharedEngine 调用之后显式
`kit.setChannelProfile(profile)`，否则编码/丢帧策略错配。

## 6. SwiftUI onDisappear 在 ScenePhase=.background 也会触发

iOS 14+ SwiftUI 在 UIScene 切到 background 时对当前 view 调度 onDisappear
（snapshot/资源释放用），**禁止**在 onDisappear 直接 `camera.tearDown()` /
清空 onFrame——回前台走 `updateUIView` 不走 `makeUIView`，闭包不会重新赋值。
正路径：onDisappear 加守卫
`guard scenePhase != .background, store.state == .ended else { return }`。

## 7. AVCaptureSession 后台中断 reason=1/4 不进 forceEnd

`wasInterrupted(reason=1/4)` 是后台切换/iPad 多任务正常行为，CameraManager 已
过滤；**禁止**进 20s `forceEnd(.cameraFailure, endType=5)` 路径。回前台必须
监听 `AVCaptureSessionInterruptionEnded` 通知 startRunning 才生效
（willEnterForeground 时 session 还处于 interrupted，startRunning silently fail）。

## 8. 业务态遮罩禁止全屏覆盖本端预览（除非业务态语义就是"完全黑屏"）

直播 / 通话 / 派对房等"摄像头持续采集 + 短窗口不推流"的业务态（例：
私 call 挂断后 15s `returnLiveCountdownOverlay` 业务必须的倒计时窗口），
覆盖层 UI **禁止**使用 `Color.black.opacity(>=0.6).ignoresSafeArea()` 全屏蒙层。

根因：本端 CameraPreview 此刻仍在持续 `view.render(pixelBuffer)`（摄像头未关），
全屏蒙层把可见画面盖死 → 用户体感等同"画面卡死 N 秒"，与"不推流"的真实业务
语义混淆。

正路径：用顶部/底部胶囊条或半透明卡片承载文案 + 倒计时，**保留本端画面可见**。
"不推流"由 `pushFrame` 内 `guard state == .joined` 在数据层拦截，与 UI 蒙层解耦。

唯一豁免：业务态语义就是"完全黑屏"（下播完成态、隐私敏感场景）。

## 9. nonisolated pushFrame 读 @MainActor 字段必须用 frameSnapshot 原子快照

**来源**：Party RTC review 202606252033 P0-1；同源问题 v5.3.1 "CIImage /
CVPixelBuffer 跨线程 ARC 不安全"。

派对房 / 直播 / 通话 RTC 封装的 `pushFrame(_ pb: CVPixelBuffer)` 入口
**永远是 nonisolated**（videoQueue 后台串行调用，~60Hz），内部需读的
`engine / state / videoSeatActive` 等字段**全部在 @MainActor 写**——直接读违反
Swift 6 严格并发；Swift 5 默认 mode 静默放行但实际是 UB。

炸点：`leave()` 在 @MainActor 设 `self.engine = nil` 的瞬间，`captureOutput`
可能拿到半状态指针调 `pushExternalVideoFrame` → 崩溃，或 channelProfile 已切换
后还在用旧编码档位推帧。

### 正解：NSLock + frameSnapshot struct

```swift
final class PartyRTCEngine: NSObject, ObservableObject, @unchecked Sendable {
    // @MainActor @Published 字段配 @MainActor isolation（否则 Sendable 一致性破坏）
    @MainActor @Published private(set) var state: State = .idle
    @MainActor private var engine: AgoraRtcEngineKit?
    @MainActor private(set) var videoSeatActive = false

    // frameSnapshot 必须是 struct + @unchecked Sendable
    // 双字段联合原子读；nonisolated(unsafe) 单字段不够
    private struct FrameSnapshot: @unchecked Sendable {
        let engine: AgoraRtcEngineKit?
        let active: Bool
    }
    private let frameLock = NSLock()
    private var frameSnapshot = FrameSnapshot(engine: nil, active: false)

    /// 锁内取快照 → 锁外推帧；snap.engine 局部强引用，self.engine=nil 不影响这一帧
    func pushFrame(_ pb: CVPixelBuffer) {
        frameLock.lock()
        let snap = frameSnapshot
        frameLock.unlock()
        guard let engine = snap.engine, snap.active else { return }
        engine.pushExternalVideoFrame(...)
    }

    /// 任何 @MainActor 路径写完 engine / state / videoSeatActive 后必须调
    @MainActor
    private func updateFrameSnapshot() {
        let next = FrameSnapshot(
            engine: engine,
            active: state == .joined && videoSeatActive
        )
        frameLock.lock()
        frameSnapshot = next
        frameLock.unlock()
    }
}
```

### 调用约定（缺一不可）

| 触发点 | 何时调 |
|---|---|
| `join()` 末尾 | engine = kit 写完后 |
| `didJoinChannel` 回调 | `state = .joined` 写完后 |
| `enableVideoSeat()` 末尾 | `videoSeatActive = true` 写完后 |
| `disableVideoSeatInternal()` 末尾 | `videoSeatActive = false` 写完后 |
| `leave()` 入口 | 先存 `wasVideoActive` 局部快照 → `videoSeatActive = false` → updateSnapshot → `updateChannel(publish=false)` → leaveChannel（updateChannel 让远端立即感知离开；wasVideoActive 供后续 `if wasVideoActive { engine.disableVideo() }` 区分，直读 self.videoSeatActive 是死分支）|
| `leave()` 末尾 | engine = nil 写完后 |
| `didOccurError` 内 state 变更 | `state = .failed` 写完后 |

### 关键不变量

1. **锁只守快照拷贝**，不守 SDK 调用（锁持有 ≤ 几条赋值）
2. **snap.engine 是局部强引用**——sharedEngine 是 singleton 不会真销毁
3. **leave() 必须先 active=false 再销毁动作**——关闭竞态窗口的核心
4. **pushFrame 完全不读 self.xxx**——只读 frameSnapshot；函数体 `grep self\.` 必须 0 匹配
5. **新增 @MainActor 字段必须同步进 FrameSnapshot struct**——强制机制

### 禁止的等价错解

- `@MainActor func pushFrame(...)` — hop 到 main 后帧延迟堆积 100ms+
- `Task { @MainActor in ... }` — 同上 + Task 创建开销
- `assumeIsolated(to: MainActor.shared)` — 运行时崩溃（pushFrame 实际在 videoQueue）
- `nonisolated(unsafe) var engine` — 单字段标注不够，需 struct 联合原子读
- `@preconcurrency import AgoraRtcKit` — 只降级参数/返回值 strict 警告，对存储字段无效

### deinit / await 跨边界禁区

```swift
deinit {
    // ❌ 禁止：deinit 线程不确定，调 @MainActor 方法跨 actor hop
    // ❌ 禁止：deinit 持锁 + ARC 析构子对象触发回调 = 死锁 UB
    if engine?.delegate === self { engine?.delegate = nil }  // ✅ 唯一允许：同步原子
}
```

`leave()` 内 `await` 跨边界：
- **永远禁止**在 await 之间持锁（NSLock 跨 await 是 UB）
- **单 owner** 场景（PartyRTCEngine 当前）：`join()` guard 已阻断重入，无需
  `preservedSnapshot` re-guard
- **共享 owner** 场景（G 期 PK 抽 `RTCSharedEngineGuard` 后）：必须
  `let preservedEngine = self.engine; await ...; guard self.engine === preservedEngine else { return }`

### sharedEngine 跨场景失效（与 §5 协同）

`AgoraRtcEngineKit.sharedEngine(with:)` 是**进程级 singleton**，多场景复用同一
指针。危险：A 场景 joined 时 B 场景 `setChannelProfile` 切换 → A.self.engine
指针没变、frameSnapshot 没变 → A 的 pushFrame 继续推到错的 channel/编码档位。

frameSnapshot **侦测不到"外部改 SDK 内部状态"**——指针对照不够。

正路径：任一场景做 `setChannelProfile` 前必须**所有其他场景 active=false →
updateFrameSnapshot → setChannelProfile → 配套 encoder 配置 → 自己 active=true**。
G 期开始多场景频繁切换前必须抽 `RTCSharedEngineGuard` 共享基建（路线图 §五
候选）。

### inflight 帧窗口（设计上接受）

锁取快照到 SDK pushExternalVideoFrame 之间 <1ms 窗口内若 leave() 已开始 →
snap.engine 推帧到正在 leave 的 channel。**dev 真机长期观察未触发崩溃/远端异常**
（sharedEngine 不销毁保证——D v5.4 立"leave 不调 destroy"铁律）。

SDK 升级（4.5.x → 4.6.x 或换厂）必须**重新真机验证**此窗口容忍度；如未来
SDK 不再容忍，升级到 "先 cm.tearDown 同步 + grace 200ms + rtc.leave" 模型。

### 与 §3 subscribers 字典的衔接

sink 闭包内调 pushFrame 必须 `[weak rtc]` 弱引用——否则 sink strong capture
`PartyRTCEngine` 自身导致漏释：

```swift
cm.subscribe(ObjectIdentifier(self)) { [weak rtcRef] pixelBuffer in
    rtcRef?.pushFrame(pixelBuffer)   // ✅
}
```

### 适用场景

- 派对房 `PartyRTCEngine.pushFrame`（E v4 已落地）
- 直播 / 1v1 通话 / PK 的 `AgoraManager.pushExternalVideoFrame`（G 期接入按本模式）

**所有"@MainActor 字段 + background queue 入口"组合一律 frameSnapshot**。
