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
