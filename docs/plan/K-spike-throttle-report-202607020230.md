# K 里程碑 Spike Task — 美颜 apply 耗时决策报告

- **产出时间**：2026-07-02 (模板)
- **对应 spec**：`K-spec-美颜设置页-202607020230.md` §6.2 + §9 Step 1a
- **状态**：⏳ 模板待用户真机数据填充
- **决策目标**：选定 `BeautySettings.apply(_:)` 触发节流方式（60ms throttle / 100ms throttle / 150ms debounce）

## 背景

红队 F1/E1：H5 用 `useDebounceFn 250ms`（拖动全程只发送最终值一次），iOS v1 spec 决策沿用 60ms throttle（拖动 1s 发 16 次）。语义差异 16 倍——若相芯 iOS SDK 25 项 property write 耗时较高，60ms 会撞主线程满载。

**决策依据必须来自真机 Instruments 数据**，不能凭经验。

## 测试步骤

### 1. 准备

- 真机 iPhone 12 / iPhone 13 / iPhone 15（三档分别测）
- Xcode → Product → Profile → Instruments → Time Profiler
- 在 `FUBeautyRenderer.apply(_:)` 内加临时埋点：
  ```swift
  func apply(_ settings: BeautySettings) {
      let t0 = CFAbsoluteTimeGetCurrent()
      // ...原有 25 项 property write...
      let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
      os_log("[K-spike] apply elapsed: %.3f ms", elapsedMs)
  }
  ```

### 2. 运行

- 启动 App → 进美颜设置页
- 打开 Instruments Time Profiler 录制
- 手指快速拖磨皮滑块，来回 3 次（1s 内约 60 次滑动）
- 停止录制，导出 log

### 3. 收集数据

在 Console.app 过滤 `[K-spike]` 关键字，收集所有 apply 耗时值。

## 数据填写表

| 机型 | 25 项 apply 平均耗时 (ms) | 峰值耗时 (ms) | 主线程 FPS | 决策 |
|---|---|---|---|---|
| iPhone 12 | ⏳待填 | ⏳ | ⏳ | ⏳ |
| iPhone 13 | ⏳待填 | ⏳ | ⏳ | ⏳ |
| iPhone 15 | ⏳待填 | ⏳ | ⏳ | ⏳ |

## 决策规则

| apply 单次平均耗时 | 决策 | 理由 |
|---|---|---|
| < 3ms | 沿用 60ms throttle | 60Hz 帧的 16.6ms 里美颜 apply < 20%，可承受 |
| 3~10ms | 升级 100ms throttle | apply 占帧时间 18~60%，减少调用频率避免累计延迟 |
| ≥ 10ms | 改用 debounce 150ms | apply 占帧时间 >60%，拖动过程不 apply，松手才 apply（同 H5 语义）|

**分档策略**：以最低性能机型（iPhone 12）数据为准；若 iPhone 12 命中 debounce 但 iPhone 15 命中 throttle，Sharer 层按 `FURenderKit.devicePerformanceLevel` 分档：
- `Level < High` → debounce 150ms
- `Level >= High` → throttle 60ms

## 决策落地位置

**Step 2 接线**（BeautyPipelineSharer 加节流层）：
```swift
private let applyThrottleInterval: DispatchTimeInterval = ...  // spike 决策后填
// Store.$settings 订阅链上加 .throttle(for: interval, ...) 或 .debounce
```

**Step 1a 骨架**：不做节流（每次 store change 立即 apply）—— 单测覆盖简单；节流是 step 2 的性能层。

## 备用方案（Spike 无法真机跑）

若真机不可用（模拟器美颜 SDK 不工作），fallback 决策：**沿用 60ms throttle**（v1 spec 决策）+ 在 §6.2 记录"未做 spike，风险留 step 3 真集成暴露"。

## 复盘

- [ ] Spike 数据收集完成
- [ ] 决策 close（60ms throttle / 100ms throttle / 150ms debounce）
- [ ] Sharer 节流层实现落到 step 2
- [ ] 报告更新到最终结论
