# 全局根 view 挂 `DragGesture(minimumDistance: 0)` 会瘫痪全 app 所有 slider / drag

> 来源：2026-07-08 auto-offline monitor 在 RootView 挂全局手势探测，全 app slider 拖不动；4 个错 hypothesis + 6 轮真机才追到

## 规则

**全局祖先 view**（`RootView` / `MainTabView` / 登录后所有 tab 的祖先层）挂 `.simultaneousGesture(DragGesture(...))` 时，`minimumDistance` **必须 >0**（推荐 10）。

想用 "任意触摸算活动信号" —— 用 `TapGesture()`，**不要** `DragGesture(minimumDistance: 0)`。

## Why

`DragGesture(minimumDistance: 0)` 在 touch-down 立即 recognize。挂在祖先层就覆盖整个 view tree。SwiftUI gesture arbitration 让这个 outer greedy gesture 抢先，下层业务 **SwiftUI Slider / `.gesture(DragGesture)` / UIKit `UISlider` tracking 全部不 fire**。TapGesture 幸存（与 DragGesture 是不同类别）——所以症状是 **Button 能点 + 所有 slider 拖不动**。

## How to apply

写全局观察类 gesture 前 grep 自查：

```bash
grep -rn "DragGesture(minimumDistance:\s*0\b" Sources/
```

命中的位置若在祖先层 → 必须改 `minimumDistance > 0`（10 是 tap 与 drag 的经验分界）。

## 排查纪律（重要）

症状是 **"tap 通 + drag 全废、跨多个 view"** 时，**第一步**就 grep 上面那条命令。**不要**从具体 view 局部排查（会像本次一样连错 4 个方向、6 轮真机测试才追到）。
