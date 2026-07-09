# 业务态切换（直播 ↔ 通话 ↔ 匹配 ↔ PK）时 HTTP 心跳 **只切 payload · 不 stop**

> 来源：2026-07-09 直播私 call 每次精确 297s 自动挂断 —— 5 次 iteration + 1 次对照实验才追到根因是 `pauseForCall` 里 `heartbeat.stop()` 违反 H5 蓝本

## 规则

**HTTP 心跳类接口（`liveHeartBeatV2` / `channelUserCount` / 类似）在业务态切换时**：
- ✅ **允许**修改 payload 字段（如 `callState` 从 0 切 1）让服务端知晓当前态
- ❌ **禁止** `stop()` + 后续 `start()` 的重启模式 —— 除非 H5 蓝本明确 `clearInterval`

**判定"该不该停心跳"的唯一依据**：**H5 蓝本对应文件的 `clearInterval` 位置**。不能凭"合理性"猜测（`agora.leave()` 直播 RTC 已离开 ≠ 该停 HTTP 心跳）。

## Why

心跳的**唯一语义**是"主播端向服务端上报活跃"。服务端根据心跳频率维护"主播在线时长/状态"，与业务态无关：
- 服务端**通话业务规则**依赖持续心跳（如"5 分钟未收到主播心跳 → 判定通话异常 → 下发结算+挂断通知给用户端"）
- 主播端停心跳 = **切断服务端对主播端的感知** → 触发服务端保护/结算机制

**具体场景本次真犯**：

| 位置 | H5 蓝本 | iOS 之前（bug） | iOS 修复后 |
|---|---|---|---|
| 通话开始 pauseForCall | `keepLiving 6s` 一直发 `callState=1` | `heartbeat.stop()` **停了 HTTP 心跳** | 不停，`HeartbeatController.tick` 读 `store.callState=1` 自动上报 |
| 通话结束 resumeCall | callState 从 1 回 0，keepLiving 继续 | `heartbeat.start()` restart | 不 restart（一直在跑，callState 自动切回 0） |
| 用户主动下播 handleLiveEnd | **`clearHeartBeatTimer()`** 真停 | 走 endLive/forceEnd 里的 teardown().stop() | 保留（这里 H5 也停）|

## 触发条件（新增 pause/resume 类切换必查）

写以下模式代码时**必须**做 H5 心跳对照：

- `pauseFor*` / `enter*` / `switch*` 业务态切换函数内含 `.stop()` 心跳类调用
- 通话/匹配/PK 内部涉及心跳频率或 payload 变化
- 发现"精确固定时间挂断/异常"（**5 分钟 / 30 秒 / 60 秒**等整数规律）

## How to apply

**写代码时**：
1. 找到 H5 蓝本对应文件（`anchor-livechat-h5/src/views/liveSetting/index.vue` 或类似）
2. 搜索 `setInterval` / `clearInterval` 或心跳 API 名（`liveHeartBeat` / `keepLiving`）
3. 逐一对齐**每一处 clearInterval 位置**（**只有 handleLiveEnd 那种真下播才该 clear**）
4. iOS 代码里对应位置改**只切 payload 字段**（`callState` / `roomId` 等），**不动 Task 生命周期**

**排查 bug 时**：
- 遇到"精确 N 秒/N 分钟规律异常" → **先怀疑服务端阈值 + 主播端心跳是否停** → 立刻搜索 `heartbeat.stop\|stopHeartbeat` 出现的所有位置
- **不要**先怀疑 UI / SDK / Race —— 精确固定时间强烈指向服务端定时任务

## 反例（本次真犯）

```swift
// LiveStore.swift:326  (bug)
func pauseForCall(...) async {
    callState = 1                    // ✅ 语义切换
    heartbeat.stop()                 // ❌ 违反 H5 蓝本 —— H5 keepLiving 一直发
    monitor.stop()                   // ✅ NetworkQualityMonitor 通话中不需要（H5 也不 monitor）
    elapsedTimerStore.stop()         // ✅ 直播时长计时暂停（H5 也暂停）
    await agora?.leave()             // ✅ 直播 RTC 离开
    WSHeartbeat.shared.notifyCallStateChanged(callState: 1)   // ✅ WS 长连接切 status
    await CallStore.shared.acceptIncomingFromLive(msg: msg)
}
```

关键：**`heartbeat.stop()` 看起来合理但违反了心跳的核心语义**。**其他 stop 都对**（网络监控/时长计时确实通话中不需要）。

## 正例

```swift
func pauseForCall(...) async {
    callState = 1                                             // ← HeartbeatController.tick 读此字段
    // heartbeat 不停：让 tick 继续每 10s 发 liveHeartBeatV2 { callState: 1 } 保持服务端认可
    monitor.stop()
    elapsedTimerStore.stop()
    await agora?.leave()
    WSHeartbeat.shared.notifyCallStateChanged(callState: 1)
    await CallStore.shared.acceptIncomingFromLive(msg: msg)
}

func resumeCall() async {
    // 15s 倒计时归 0 后
    await rejoinLiveChannel()
    // heartbeat 未停，callState 从 1 → 0 后 tick 自动切回 callState=0
    monitor.start()
    elapsedTimerStore.start()
    callState = 0
    WSHeartbeat.shared.notifyCallStateChanged(callState: 0)
}
```

## 与既有规则关联

- [root-cause-investigation.md](root-cause-investigation.md) §2 "下游 2 次补丁失败 → 强制上溯"：本次连续 4 次错怪（EmptyRoomDetector / 5min UI / 用户端硬编码 / sysMsg 67）都是下游打补丁，第 5 次上溯到"业务态切换 vs H5 蓝本对照"才找到
- [feature-pipeline-complexity-tier.md](feature-pipeline-complexity-tier.md)：Spec §0 H5 二次校验必须**精确到心跳类接口的 start/stop 时机**，不能只对齐 API 端点/参数
- [api-http-method-strict.md](api-http-method-strict.md)：本 rule 补"心跳接口不只 method/path 对齐，还要**调用时机/停止时机**对齐"

## 已加固清单（2026-07-09）

- ✅ `LiveStore.pauseForCall` / `resumeCall` 心跳保留（本次修复）
- 未来新加 `pauseFor*` / `switch*` 类函数（如 PK 状态切换）**必须**按此规则对照 H5

## 历史教训

- **2026-07-09 直播私 call 5 分钟自动挂断**：iOS pauseForCall 里 `heartbeat.stop()` 让服务端 5 分钟未收到主播心跳 → 服务端下发 sysMsg 67（结算）+ callCancel type=-1（通话结束）通知 → 用户端触发 RTM action=4 hangup → iOS 主播端观察为 297s（用户端 300s − pauseForCall 链路耗时 ~3s）被动挂断。5 次 iteration 追根因（v1 300s 语义 / v2 EmptyRoomDetector / v3 用户端产品规则 / v4 锁定期 UI / **v5 心跳停问题**），前 4 次都在下游打补丁，直到用户对照 H5 keepLiving 才锁定。
