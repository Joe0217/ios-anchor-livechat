# SwiftUI modal presentation 必须 hoist 到唯一容器;容器 `.onDisappear` 慎放副作用

> 来源:2026-07-02 朋友圈图片预览双根因反悔(present in progress + first-tap self-dismiss);2026-07-03 CircleView 缓存被 fullScreenCover 触发的底层 onDisappear 误清空

## 规则

**规则 1 — Hoist**:`TabView(.page)` / `ForEach` 等多实例复用容器内部,禁止各子 view 各自挂 `.sheet` / `.fullScreenCover` / `.confirmationDialog` / `.alert(item:)` / `.popover`。modifier 必须 hoist 到唯一容器层,子 view 用 callback 向上传值。

**规则 2 — onDisappear 慎放副作用**:容器级资源清理(cache clear / observer teardown)禁止放 `.onDisappear`,改用 `isActive` / `isHomeTabActive` 等业务语义信号。`.onDisappear` 仅做真正幂等的兜底收尾。

## Why

### 规则 1 双根因(缺一不可)

**根因 1**:Button press animation 未结束时 SwiftUI presentation 系统与 Button state machine race → `Attempt to present ... while a presentation is in progress` 报错
**根因 2**:多个 view 同时挂 `.fullScreenCover(item:)` binding → SwiftUI presentation 全局只允许一个 → 已挂的 cover 首次触发时立即被 dismiss(即"first-tap self-dismiss")

反例:
```swift
TabView(selection: $selection) {
    ForEach(posts) { post in
        MomentView(post: post)
            .fullScreenCover(item: $mediaPreview) { ... }   // ❌ 每个 tag 都挂
            .tag(post.id)
    }
}
```

正例(缺一不可):
```swift
struct CircleView: View {
    @State private var mediaPreview: MediaPreviewContext?
    var body: some View {
        TabView(selection: $selection) {
            ForEach(posts) { post in
                MomentView(post: post, onMediaPreview: { ctx in
                    DispatchQueue.main.async { mediaPreview = ctx }   // 治根因 1
                })
                .tag(post.id)
            }
        }
        .fullScreenCover(item: $mediaPreview) { ... }   // ✅ 唯一容器挂,治根因 2
    }
}
```

### 规则 2 机制

iOS 14+ `.fullScreenCover` 覆盖全屏被视作 hierarchy 变化 → 底层 view 触发 `.onDisappear`(cover dismiss 时再 `.onAppear`)。**这与 `.sheet` 不同**——sheet 保留底层可见,不触发 onDisappear。

CircleView 在 `.onDisappear` 内 `pool.clear()`,用户点开图片预览 → 底层走 onDisappear → 缓存被清 → 预览关掉再打开又重下 → 用户报"缓存机制没意义"。

正例:
```swift
.onChange(of: isActive) { _, active in
    if !active { MomentPreviewMediaCache.shared.clear() }
}
.onChange(of: isHomeTabActive) { _, active in
    if !active { MomentPreviewMediaCache.shared.clear() }
}
// .onDisappear 不放清理副作用
```

## How to apply

**写 modal modifier 时(规则 1)**:
- [ ] 向上追父 view:父是 `TabView(.page)` / `ForEach` / 自定义分页容器 → modifier 必须 hoist
- [ ] modal state 上移到容器;子 view 声明 `let onXxx: (Ctx) -> Void`
- [ ] Button action 内 `DispatchQueue.main.async` / `Task { @MainActor }` 再 set state
- [ ] 涵盖的 modifier:`.sheet` / `.fullScreenCover` / `.confirmationDialog` / `.alert(item:)` / `.popover`(is 系与 item 系一视同仁)

**写容器 view 时(规则 2)**:
- [ ] 资源清理优先用 `.onChange(of: isActive)` / `.onChange(of: isHomeTabActive)` 语义信号
- [ ] 容器如果可能内嵌 fullScreenCover(即使自己不挂、子 view callback 上抛),onDisappear 副作用一律不放
- [ ] `.onDisappear` 只做真正幂等的收尾

## 与既有规则关联

- [swiftui-camera-preview.md](swiftui-camera-preview.md) §1:switch case 内重复 View 用 if 承载 —— 同源 view identity 陷阱
- [swiftui-keepalive-publisher-isolation.md](swiftui-keepalive-publisher-isolation.md):keep-alive 下订阅串扰 —— 本规则补 modal 串扰 + onDisappear 误触发
- [swiftui-button-plain-hitarea.md](swiftui-button-plain-hitarea.md):Button 声明式陷阱系列

## 历史教训

- **2026-07-02 朋友圈预览双反悔**:只加 `DispatchQueue.main.async` 治根因 1 仍复现,追到 TabView(.page) 每个 tag 都挂 cover 才根治。教训:遇 presentation race 先追 view identity + 多实例挂载,不停在"async 好像修好了"
- **2026-07-03 CircleView 缓存失效**:CircleView.onDisappear 内 `pool.clear()` 被 fullScreenCover 底层 onDisappear 误调用。教训:sheet ≠ fullScreenCover 底层可见性,容器 onDisappear 不是可靠的"用户离开容器"信号
