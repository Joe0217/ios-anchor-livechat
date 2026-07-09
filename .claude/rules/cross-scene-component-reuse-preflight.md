# 跨场景复用现有 SwiftUI View 组件前必先点源码检查自持依赖

> 来源：2026-07-07 C 里程碑通话中控制按钮 UI spec §0.4 遗漏：spec 起草期只凭 K 里程碑记忆推断"美颜面板 sheet 直接复用 BeautySettingsView"，impl 期点开源码才发现它自持 `@StateObject var camera = CameraManager()` + `.ignoresSafeArea()` 全屏——通话中打开 = 双 CameraManager 抢摄像头 → reason=3 → 20s watcher → forceEnd 误下播。1 次 spec 反悔 + v2 微调 + 范围从 4 按钮回退到 3 按钮

## 规则

任何 spec §0.3 三圈判断 / §4 复用判断决策要复用某个**现有 SwiftUI View struct**（页面级 / 面板级 / sheet 级组件）时，**必须点开该组件源码**检查以下 3 类"自持隐藏依赖"，不能凭直觉、其他里程碑印象、explore agent 报告推断：

- [ ] **自持 CameraManager / AVCaptureSession / MetalPreviewView** —— 若是，跨场景打开 = 双相机实例抢前置摄像头 → 触发 `AVCaptureSession reason=3` → 20s watcher → `forceEnd(.cameraFailure endType=5)` 误路径
- [ ] **自持 @StateObject / @ObservedObject 私有 store 或 shared singleton** —— 若是，与调用方 store 生命周期冲突（如 K 页面 dismiss 会调 store.flush/clear，跨场景 dismiss 会意外触发副作用）
- [ ] **`.ignoresSafeArea()` 全屏 modifier 挂在根 View** —— 若是，无法作为 `sheet + .presentationDetents([.medium, .large])` 使用，只能 fullScreenCover 完全覆盖，与"保留业务画面顶部可见"这类交互设计不兼容

## Why

上述 3 类"自持能力"在**单一使用场景**下都合理：K 期独立美颜设置页拥有自己的相机预览 + 自己的 store + 全屏预览完全正确。但作为**跨场景 sheet 弹出**时全部反向 —— 双相机、双 store 副作用、无法半屏。

**spec §0.3 三圈"依赖已就绪 + 接入成本 <50 行 → 直接做"** 判断的隐含前提是"依赖模块可跨场景使用"；上述 3 类自持隐藏依赖会让"直接接入 20 行"实测变成"跨场景 refactor 100+ 行"或"必须新写轻量版本"。preflight 缺失 = spec 层假设撒谎 = impl 期反悔。

**具体错例**（C 里程碑真犯）：
```swift
// spec §0.4 表格里写：
// 美颜面板入口 | H5 弹出美颜面板 | 弹 K 里程碑 BeautySettingsView sheet ← ❌ 未 preflight

// 实测 BeautySettingsView.swift:18-24
struct BeautySettingsView: View {
    @StateObject private var camera = CameraManager()   // ❌ 自持相机
    // ...
    var body: some View {
        ZStack {
            BeautyPreviewPanel(camera: camera, sharer: sharer)
                .ignoresSafeArea()                       // ❌ 全屏
            // ...
        }
    }
}
```

**正例**（本 rule 加入 spec §0.4 后应该写）：
```
| 复用目标 | 自持相机? | 自持 store? | ignoresSafeArea? | 决策 |
|---|---|---|---|---|
| BeautySettingsView | ✅ @StateObject CameraManager | ✅ BeautySettingsStore | ✅ | ❌ **不复用**，改写轻量 CallBeautyPanel |
```

## 触发条件

写 spec §0.3 三圈 or §4 复用判断时，任何被"复用"的目标是**已存在的 SwiftUI View struct** 且此前从未在本 spec 涉及场景中使用过：

- 页面级：`XxxSettingsView` / `XxxRoomView` / `XxxMainView` / `XxxDetailView`
- 面板级：`XxxPanel` / `XxxSheet` / `XxxPicker` / `XxxOverlay`
- 任何名字带 `View` / `Panel` / `Sheet` / `Overlay` / `Picker` 的 struct

**不适用**：
- 纯数据 struct / enum / protocol / Store / Service / 工具函数 —— 无自持 UI 依赖
- 项目内本 spec 场景中已跨场景验证过的组件（如 CircleButton / AvatarView / MatchToast enum 等）

## How to apply

写 spec §0.3 或 §4 起草时，对每个"复用某已有 View 组件"决策跑一遍：

### 步骤 1: preflight grep（10 秒）

```bash
grep -nE "@StateObject|@ObservedObject.*shared|CameraManager|MetalPreviewView|AVCaptureSession|ignoresSafeArea" Sources/<组件路径>.swift
```

### 步骤 2: 判档

- **0 命中** → spec 可写"直接复用"
- **命中 CameraManager / AVCaptureSession** → **不能作为 sheet/overlay 跨场景引入**（除非改 init 接受外部 camera）
- **命中 @StateObject shared store** → 明示"跨场景 dismiss 副作用需评估"
- **命中 ignoresSafeArea** → 明示"只能 fullScreenCover 全覆盖，不能 sheet detents 半屏"

### 步骤 3: spec 明示

若命中任一"自持隐藏依赖"，spec §4 复用判断表格必须写：
- 是否 refactor 原组件接受外部依赖（+改动量）
- 或新写轻量场景专用组件（+新代码行数）
- 或本轮跳过该功能（+范围回退）

### 具体到已知组件的 preflight 结论（C 期梳理）

| 组件 | 自持相机 | 自持 store | ignoresSafeArea | 跨场景 sheet 结论 |
|---|---|---|---|---|
| `BeautySettingsView` (K 里程碑) | ✅ | ✅ | ✅ | ❌ **不可**——只能独立全屏页面使用 |
| `LiveSettingsView` (B 里程碑) | 未验证 | 未验证 | 未验证 | 下次复用前需 preflight |
| `PartyRoomView` (E 里程碑) | 未验证 | 未验证 | 未验证 | 下次复用前需 preflight |
| `GiftPickerSheet` | 未验证 | 未验证 | 未验证 | 下次复用前需 preflight |
| `MatchMainView` (L 里程碑) | 未验证 | 未验证 | 未验证 | 下次复用前需 preflight |

**触发条件下补充**：下次任一里程碑复用上述"未验证"组件时，按 §How to apply 跑 preflight → 结论回写此表。

## 与既有 rules 关联

- [feature-pipeline-complexity-tier.md](feature-pipeline-complexity-tier.md) §0.3 "范围三圈占位栏必答"：本 rule 补三圈内圈决策前的**前置检查**——占位判定前先跑 preflight，避免"依赖已就绪"是假象
- [swiftui-camera-preview.md](swiftui-camera-preview.md) §规则 3 (subscribers 字典) & §规则 7 (AVCaptureSession reason=1/4)：本 rule 是**问题左移**——从 spec 阶段就避免双相机场景，不让 impl 期真机才暴露
- [root-cause-investigation.md](root-cause-investigation.md) §"下游 2 次补丁失败 → 强制上溯"：本 rule 是**问题从更早左移**——把 impl 期反悔提前到 spec 起草期

## 不适用

- 本项目内非 SwiftUI 组件（UIKit UIView / OC 混编代码）—— 自持依赖模式不同
- 完全新写的 View（无历史包袱可 preflight）—— 本 rule 只针对"复用已有"
- 组件设计者本人（K 期开发 BeautySettingsView 的开发者知晓自持关系）—— 本 rule 面向"复用者"

## 历史教训

- **2026-07-07 C 里程碑通话中控制按钮 UI**：spec §0.4 未 preflight → impl 期发现 BeautySettingsView 自持 CameraManager + ignoresSafeArea → 直接反悔 4 按钮 → 3 按钮 + 美颜方案留 D 里程碑独立 spec。本 rule 沉淀避免 D/E/F/G/H/I/J 里程碑重复踩坑
