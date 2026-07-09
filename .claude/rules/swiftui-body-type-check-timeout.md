# SwiftUI body/子 view 内 modifier chain + 嵌套 closure 超一定复杂度 → 编译器 type-check timeout

> 来源：
> - 2026-07-07 ChatDetailView_Previews `Group { 3×ChatDetailView }` type-check timeout（v6 修复：拆到 previewLoaded/Empty/Error computed property）
> - 2026-07-09 PartyRoomView.body 10+ modifier + 5 处嵌套 closure，一次 body 拆 + 二次 sceneBody 抽 handler/@ViewBuilder 才通过

## 症状

编译器报：
```
The compiler is unable to type-check this expression in reasonable time;
try breaking up the expression into distinct sub-expressions
```

出现位置一般在 `var body: some View` 声明行，或某个含多个 modifier chain 的 computed property 声明行。

## 规则

**触发阈值**（任一条命中就重构，别等报错）：
- modifier chain ≥8 个
- modifier 内 closure 含 `if let` / `switch` / 多语句多层嵌套
- VStack/HStack/ZStack 内 ≥5 个子 view 且**每个子 view 自己也带 modifier**
- 出现 `Group { if...else 多分支 View }` 且外层还挂 modifier

## How to apply

### 1. 事件 closure → `perform: methodName`

```swift
// ❌ 编译器要推导 closure body 的类型
.onAppear {
    AutoOfflineMonitor.shared.suspend()
    sortedSeatsCache = store.seatList.sorted { ... }
    guard !didStartEnter else { return }
    didStartEnter = true
    Task { await ensureEntered() }
}

// ✅ 用 method 引用，编译器只需匹配 () -> Void
.onAppear(perform: handleAppear)

private func handleAppear() { ... }
```

同款适用：`.onDisappear(perform:)` / `.onChange(of:perform:)` / `.onSubmit` 等所有接受 `() -> Void` 或 `(T) -> Void` 的 modifier。

### 2. Alert / Sheet / ConfirmationDialog 的 actions / message → `@ViewBuilder` computed property

```swift
// ❌ 长 closure 含 if let / 多 Button
.confirmationDialog(title, isPresented: $show) {
    if let me = store.selfSeat {
        // 10+ 行按钮 + 嵌套 if
    }
}

// ✅ 抽 @ViewBuilder property
.confirmationDialog(title, isPresented: $show) { selfActionsButtons }

@ViewBuilder private var selfActionsButtons: some View {
    if let me = store.selfSeat { ... }
    Button("Cancel", role: .cancel) {}
}
```

### 3. 容器 View → 独立 computed property

`VStack/HStack/ZStack` 内含 ≥5 个子 view + 子 view 各自带 modifier → 抽 `contentStack: some View` 让 body 只做 modifier chain。

### 4. 拆分层数不够就再拆一层

**关键教训（2026-07-09 PartyRoomView）**：先把 body → sceneBody（外挂一个 modifier）仍不够 —— sceneBody 内 modifier chain 才是超时源头。判定标准：**报错行仍是自己**，说明拆得不够深，必须继续按 §1-§3 抽 closure/子 view。

## Why

SwiftUI `body` 类型是 `some View` 隐式关联类型，每个 modifier 返回 `ModifiedContent<Prev, Modifier>` 嵌套包装类型；modifier chain 越长嵌套越深，加上 `@ViewBuilder` 的 `TupleView<repeat each T>` 变参泛型 + `if/switch` 分支的 `_ConditionalContent<T,F>` 组合，Swift 类型推导复杂度**指数级增长**。

closure 里含 `if let` / 多语句时，编译器还要为每条语句独立做类型推导 + capture 分析，进一步放大。

**Method 引用 vs closure**：`perform: handleAppear` 让编译器只匹配已声明的函数签名（O(1)），而 `perform: { ... }` 需要推导整个 closure 类型 → 差异巨大。

## 预防（写代码时的启发式）

写 view 时**边写边观察**这几个信号，命中就立刻拆：

- [ ] body 或某个 computed property 已经 30+ 行还没结束
- [ ] 已经写了 5 个 modifier 还没到 body 结尾
- [ ] 某个 modifier closure 里出现 `if let` 或 `switch`
- [ ] 复制粘贴了另一个 view 的 modifier chain 补上——评估合并后总长度

## 与既有 rules 关联

- [swiftui-camera-preview.md](swiftui-camera-preview.md) §1 "switch case 内重复 View 用 if 承载" —— 同源 SwiftUI 声明式类型系统陷阱
- [swiftui-background-in-shape-signature.md](swiftui-background-in-shape-signature.md) —— 类似"编译器 overload/generic 推导误区"
