# 根因调查纪律

> 来源：2026-07-01 直播切后台自动下播 bug，6 次修复中前 5 次在下游打补丁，最后 1 次追到 CameraManager reason 过滤对称性遗漏

## 规则

1. **从日志里最早的异常事件追起，不从最终症状反推**
2. **下游连续打 2 次补丁失败 → 强制上溯**（补丁思维是拒绝根因的隐性信号）
3. **反复修过 / 注释详细 / 有 rule 加持的模块 = 对称性遗漏高发区**（不是"这里已经对了"）

## Why

用户第一次贴的 log 里就有 `reason=3`（证据链头）和 `sub=camera_runtime_20s`（症状）。我 5 次盯着症状改下游守卫（HeartbeatController / SystemMessageRouter / LiveStore watcher）都失败；第 6 次追到 CameraManager `handleWasInterrupted` 只过滤 reason=1/4、遗漏 reason=3——同文件 `handleRuntimeError` 早有正确的 background 静默——**对称性缺失是明码**。

## How to apply

调查前置（改代码前）：

- [ ] 日志按时间排序，标出**最早**的异常信号（reason=X / errorCode=Y / notification）
- [ ] 画触发链：`系统 API → SDK 回调 → 我方 handler → 业务 store → 症状`
- [ ] 每层问："这层为什么让证据通过了"，不是"这层为什么触发症状"

跳到"竞态"假设前必须满足：非竞态解释全部 grep 排除过 + 有真机 debugger 观测手段。否则拒绝——竞态假设无法证伪，会让人无限加守卫。

发现某 handler 有过滤条件时，30 秒扫同文件其他同类 handler 的过滤条件是否对称（本次 bug 用这一步就能拦住）。

## 不适用

- 明确的单点 bug（typo / 空指针）—— 无需追证据链
- 新开发功能 —— 本规则针对已有代码 bug 排查

## 补充教训 2026-07-02（K 里程碑）

**用户反馈"拖 slider 无实时更新"追根因故事**：

1. 我下游打 3 次补丁全失败：
   - Patch 1：BeautySettingsView.onAppear 加 `camera.renderer.apply(store.settings)` 首帧一致（apply 到 Passthrough，空跑）
   - Patch 2：onReceive throttle 60ms 直调 renderer.apply 绕开 Sharer sink（同样 apply 到 Passthrough）
   - Patch 3：分析 Sharer.storeCancellable sink 的 MainActor actor hop 时序（与真根因无关，白花时间）
2. 用户第 4 次贴 log，第一屏就有：
   ```
   FaceUnity setup took 0.585708s (>500ms); fallback to passthrough
   Sharer setup failed: genericSetupFailed
   ```
3. 我立即追到 FUBeautyRenderer.init 里 `if elapsed > 0.5 { throw setupTimeout }` —— B 期立的 500ms 阈值到 K 期 25+ 参数处理下过严，585ms 属正常 setup 被误判 fallback → PassthroughRenderer.apply 空实现 → 用户看不到任何美颜效果

**新增教训**：

4. **证据链头往往就在用户贴的 log 第一屏**（往往是最早的 warning/error/state transition）—— 不是 log 尾部的症状描述。开始调查前先扫 log 全文找最早异常信号，不要先看用户描述的最终症状然后往上倒推。
5. **同一功能连续 3 次下游补丁失败强制转追根因**（原规则 §2 "连续 2 次"实操中容易破规。K 期我到第 4 次才追）。**加严约束**：**下游 2 次补丁失败 → 停手 → 强制看 log 头部证据链**。
6. **静默 fallback 是典型证据链隐藏点**：`try? throw fallback` / `guard else return` / `catch { log warning }` 这类"错误发生但不 crash"的 pattern 是**下游用户看不到真错误只看到症状**的根源。追根因时**优先 grep** `throw` / `guard .* return` / `catch` in 相关调用链。

**行动条件**：
- 遇到"UI 层看起来在变但真机效果没反应"类症状 → 优先怀疑**渲染层降级/fallback 到 no-op 实现**（如 K 期 PassthroughRenderer.apply 空实现）
- 追下游前先 grep `Renderer` / `Fallback` / `Passthrough` 相关关键字确认真渲染路径生效
