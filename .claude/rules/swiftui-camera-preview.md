# SwiftUI 相机预览 / RTC 渲染稳定性

## 1. switch case 内重复出现的子 View 必须用 if 链承载

SwiftUI 把 `switch` case 内的每个分支视为**不同位置**的 view，跨 case 切换会
触发 `dismantleUIView` + 重建（含 UIViewRepresentable 包装的 MTKView /
AgoraRtcVideoCanvas 持有 view）。直播私 call 流程中 CallFaceTimeView 横跨
`.calling / .connecting / .connected` 三态——必须放在**同一 if 分支**或用
`.id(...)` 强制 identity 稳定，**不能写成多个 switch case 分别 return 同名
子 View**。

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
- MTKView：实例切换 → `camera.onFrame` 闭包目标空窗 → **本端画面卡帧**
- AgoraRtcVideoCanvas.view：layer 引用失效 → SDK 远端首帧渲染丢失 → **对端黑屏**

定位思路：若发现 makeUIView 在通话过程中被调多次，先排查上层 switch case
跨分支重建（见规则 1），再考虑加 `.id()` 锁 identity。

## 3. CameraManager 帧分发禁止使用单闭包 onFrame；必须用 subscribers 字典

**反悔历程（v5.3.3 ~ v5.7 全部失败，v5.8 立新规则）**：

| 版本 | 方案 | 失败原因 |
|---|---|---|
| v5.3.3 ~ v5.6 | `updateUIView` 守 `onFrame == nil` 才 bindFrameSink | 通话挂断后闭包内 weak view 变 nil 但**闭包本身非 nil** → 守卫不通过 → 本端永久断流 |
| v5.7 | 去掉守卫，`updateUIView` 每次强制重绑 | SwiftUI 在 `.overlay { ... }` 内 view 消失时**不会**触发 ZStack 兄弟节点的 updateUIView → 本体永远拿不到重绑机会 → 同样断流 |

**v5.7 失败的真根因**：
1. 直播私 call 期间 LiveRoomView 本体 CameraPreview 在 ZStack 主层、CallView overlay 在 `.overlay { ... }` 修饰内
2. PIP `bindFrameSink` 后绑覆盖本体（单闭包模型）：`onFrame` 闭包 weak view = PIP MTKView、agoraRef = callStore.agora
3. 挂断 → overlay 内 PIP CameraPreview 消失 → SwiftUI 调度 PIP 的 dismantleUIView
4. **关键盲点**：本体 CameraPreview 在 ZStack 的位置/props 都未变，SwiftUI 没有理由 re-call 它的 updateUIView，本体永远拿不到重绑时机
5. onFrame 仍指向 PIP 那个 weak nil 的旧闭包 → 本端帧渲染失败 + agoraRef nil → 直播观众端断流

**真根因**：单闭包模型本质不支持"同一 CameraManager 多个并行下游"。直播私 call 期间本体（推直播 Agora）+ PIP（推通话 Agora）需要同时收帧，必须用订阅字典。

**v5.8 正确做法**：
- `CameraManager` 删 `var onFrame`，改为 NSLock + `[ObjectIdentifier: (CVPixelBuffer) -> Void]` 字典
- 暴露 `subscribe(key, sink)` / `unsubscribe(key)` API
- `captureOutput` 锁内拷贝 sink snapshot、锁外分发（避免长持锁阻塞 main queue 的 subscribe）
- `CameraPreview` 加 `Coordinator`：
  - `makeCoordinator()` 创建 Coordinator
  - `makeUIView` / `updateUIView` 调 `coordinator.attach(view:agora:)`，内部 `camera.subscribe(ObjectIdentifier(self), sink)`
  - `static func dismantleUIView(_:coordinator:)` 调 `coordinator.detach()` 精确注销
- 每个 CameraPreview view 持有独立 key → PIP dismantle 仅注销 PIP 自己那一格，本体的 sink 始终留在字典里——**不依赖任何 SwiftUI re-eval 时机**

```swift
// CameraManager.swift
private let subscribersLock = NSLock()
private var subscribers: [ObjectIdentifier: (CVPixelBuffer) -> Void] = [:]
func subscribe(_ key: ObjectIdentifier, sink: @escaping (CVPixelBuffer) -> Void) { ... }
func unsubscribe(_ key: ObjectIdentifier) { ... }

// CameraPreview.swift
func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }
static func dismantleUIView(_ uiView: MetalPreviewView, coordinator: Coordinator) {
    coordinator.detach()   // ✓ 精确注销自己那一格
}
```

反例（v5.7 失败方案，禁止回退）：
```swift
// CameraManager: var onFrame: ((CVPixelBuffer) -> Void)?   // ❌ 单闭包 PIP 覆盖本体
// CameraPreview.updateUIView { bindFrameSink(to: uiView) }   // ❌ overlay 兄弟节点拿不到重绑时机
```

## 4. MTKView 切后台保留 currentImage 作为最后一帧占位

`didEnterBackground` 内**禁止** `currentImage = nil`，仅 `releaseDrawables()`
释放 GPU 资源。回前台 setNeedsDisplay 立刻渲染最后一帧 → 真新帧
（AVCaptureSession 重启 1-2s 后到达）通过 render(_:) 自然替换，视觉无空窗
黑屏。v5.3.5 "清空让闪烁更明确"决策已在 v5.5 反悔（实测用户反馈"卡死"）。

## 5. 声网 sharedEngine 复用 singleton 时必须显式 setChannelProfile

`AgoraRtcEngineKit.sharedEngine(with:delegate:)` 第二次调用复用 singleton 并
**忽略**新 config——`channelProfile` 仍是首次创建时的值。直播
`.liveBroadcasting` 与 1v1 通话 `.communication` 切换时，必须在 sharedEngine
调用之后显式 `kit.setChannelProfile(profile)`，否则编码/丢帧策略错配。

## 6. SwiftUI onDisappear 在 ScenePhase=.background 也会触发

iOS 14+ SwiftUI 在 UIScene 切到 background 时对当前 view 调度 onDisappear
（snapshot/资源释放用），**禁止**在 onDisappear 直接 `camera.tearDown()` /
清空 onFrame——回前台走 `updateUIView` 不走 `makeUIView`，闭包不会重新赋值
（参考 CLAUDE.md v5.3.3 已知坑）。正路径：onDisappear 加守卫
`guard scenePhase != .background, store.state == .ended else { return }`。

## 7. AVCaptureSession 后台中断 reason=1/4 不进 forceEnd

`wasInterrupted(reason=1/4)` 是后台切换/iPad 多任务正常行为，CameraManager 已
过滤；**禁止**进 20s `forceEnd(.cameraFailure, endType=5)` 路径。回前台必须
监听 `AVCaptureSessionInterruptionEnded` 通知 startRunning 才生效
（willEnterForeground 时 session 还处于 interrupted，startRunning silently
fail，参考 CLAUDE.md v5.3 已知坑）。

## 8. 业务态遮罩禁止全屏覆盖本端预览（除非业务态语义就是"完全黑屏"）

直播 / 通话 / 派对房等"摄像头持续采集 + 短窗口不推流"的业务态（例：
私 call 挂断后 15s `returnLiveCountdownOverlay` 业务必须的倒计时窗口），
覆盖层 UI **禁止**使用 `Color.black.opacity(>=0.6).ignoresSafeArea()` 全屏蒙层。

根因：本端 CameraPreview 此刻仍在持续 `view.render(pixelBuffer)`（摄像头未关），
全屏蒙层把本可见的实时画面完全盖死 → 用户体感等同"画面卡死 N 秒"，
与"不推流"的真实业务语义混淆——用户无法区分"是我的设备卡了"还是"业务在等"。

正路径：用顶部/底部胶囊条或半透明卡片承载文案 + 倒计时，**保留本端画面可见**。
"不推流"由 `pushFrame` 内 `guard state == .joined` 在数据层拦截，与 UI 蒙层解耦。

唯一豁免：业务态语义就是"完全黑屏"（比如下播完成态、隐私敏感场景），
否则一律按本规则走半透明胶囊条。
