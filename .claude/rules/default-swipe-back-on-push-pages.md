# push 页面默认支持左滑返回手势

> 来源：2026-07-08 用户明示"所有页面都默认支持左滑关闭，除非我特殊说明"——iOS 系统 back 手势是深植肌肉记忆的交互，缺失即体验退化。

## 规则

**任何 SwiftUI NavigationStack push 的子页**，只要用了 `.navigationBarBackButtonHidden(true)` 隐藏系统 back（无论是自定义 leading 按钮 / 拦截 dirty 状态 / 定制视觉），**必须**同时挂 [`.swipeToPopEnabled()`](../Sources/Core/UI/SwipeToPopHelper.swift) 恢复系统左边缘右滑返回手势。

## Why

`.navigationBarBackButtonHidden(true)` 是**双重副作用**：
1. 系统 back 按钮消失（预期）
2. **同时禁用** `UINavigationController.interactivePopGestureRecognizer` —— 因为系统 delegate 判 nav bar 隐藏时拒绝手势（非预期，但 iOS 硬编码行为）

用户从 iOS 系统 App 培养的肌肉记忆：**任何 push 页面都能从左边缘右滑回去**。缺失时用户会连续尝试几次、误以为 App 卡死、最后不得已找 back 按钮——体验断崖。

## How to apply

### 写自定义 back 时的标准模板

```swift
var body: some View {
    content
        .navigationTitle("...")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { handleBackTap() } label: { ... }
            }
        }
        .swipeToPopEnabled()   // ✅ 恢复系统左滑返回手势
}
```

### 触发条件

- ✅ 自定义 leading 按钮（如 dirty check 拦截、视觉重设计）
- ✅ dynamic 隐藏 back（`.navigationBarBackButtonHidden(isBusy)`）
- ✅ 完全无 leading（想让 title 更居中）
- **例外（明示不做左滑）**：业务态页面必须走"确认弹窗才能返回"，如：
  - 直播中页面（LiveRoomView）—— 直播中意外滑退会丢会话；需要 back 弹窗确认
  - 派对房内页（PartyRoomView）—— 同上
  - 开播准备中的 LiveSettingsView（`isBusy=true` 期间不可返回）
  上述场景 **禁用 `.swipeToPopEnabled()`** —— 用 `.navigationBarBackButtonHidden(true)` 的**副作用**（自动禁 swipe）作为业务防误退保护。

## Preflight（Code review 时的自检）

改动包含 `.navigationBarBackButtonHidden` 时：

- [ ] 页面 push 出来（不是 sheet / fullScreenCover）？
- [ ] 是否属于"业务态需拦截返回"页面（直播 / 派对房 / 通话中）？
  - 是 → 不加 swipeToPopEnabled，保留副作用禁手势
  - 否 → **必须**加 `.swipeToPopEnabled()`

## 与既有基础设施

- [Sources/Core/UI/SwipeToPopHelper.swift](../Sources/Core/UI/SwipeToPopHelper.swift) —— H-3 里程碑抽出的通用 helper（新代码用这个）
- [Sources/DesignSystem/SwipeBackEnabler.swift](../Sources/DesignSystem/SwipeBackEnabler.swift) —— trial #3 期加的老版本（`enableSwipeBack()`）；两者功能等价，新代码统一用 `.swipeToPopEnabled()`，老代码保持不动待未来 unify

## 已加固清单（2026-07-08 v3）

- ✅ ChatDetailView（H-3）
- ✅ UserProfileView（H-0）
- ✅ EditProfileView（I，本次沉淀触发点）

## 未加固（需按 preflight 判决）

- PartyRoomView / LiveRoomView / LiveSettingsView(isBusy) —— 属"业务态防误退"，保持副作用禁手势不加

## 历史教训

- **2026-07-08 EditProfileView 用户报"进入资料编辑页无法左滑返回"** —— navigationBarBackButtonHidden 副作用问题，本 rule 沉淀让未来所有新页面 preflight 一致处理，避免逐个页面反复重现问题。
