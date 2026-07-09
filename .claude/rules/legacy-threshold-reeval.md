# 早期里程碑立的性能/超时阈值到后期里程碑需重估

> 来源：K 里程碑 2026-07-02 用户反馈"拖 slider 无实时更新"—— 真根因是 B 里程碑 spec §6.1 立的 500ms setup timeout 到 K 期 25+ 参数处理场景下过严，585ms 实际正常但被误判 fallback PassthroughRenderer，apply 空跑

## 规则

**里程碑 X 立的性能/超时/降级阈值，到里程碑 X+N（N ≥ 2）时**必须重估：
1. 立阈值时的假设是否仍成立
2. 新功能加载/调用面是否让阈值不再合理
3. 若不再合理，**修阈值 or 明示保留原因**，不留"看上去合理但实际过严/过宽"的隐性坑

## Why

**B 期立的 500ms timeout 到 K 期挂了**：

- **B 期语境**（2026-06-19）：spec §6.1 立 500ms setup timeout 是因为 FUManager.setupSync 只挂 4 个基础参数 + 面部 AI 模型，实测在 iPhone 12+ 上 setup ~200-400ms。500ms 是保守上限
- **K 期语境**（2026-07-02）：FUManager 已扩展到 25+ 参数 property + 8 张 sticker bundle resource 引用 + 更多 SDK 内部初始化。首次冷启动 setup ~585ms 是**正常**，但阈值仍是 500ms → 误判 fallback

**下游后果**：
- 降级 PassthroughRenderer → BeautyRenderer.apply 是空实现 → 用户拖 slider 无效果、无日志
- 更糟：用户 UI 层看到"参数值变了"（Store 生效）+ SDK 层没变 → 误以为是**其他 bug**（Sharer sink actor hop / Combine 时序 etc.）
- 花了 3 次下游打补丁才追到根因（对齐 [root-cause-investigation.md](root-cause-investigation.md) 铁律）

## How to apply

### 在早期里程碑立阈值时

写 spec 时**必须**：
- 记录**阈值来源**（实测数据 or 保守估计 or 参考值）
- 明示**该阈值假设**的功能面（如"当前 A/B 里程碑覆盖 X 个参数 / Y 个 SDK 调用"）
- 标 **"阈值需在后续里程碑加参数/功能时重估"** 作为已知 TODO

例（B spec §6.1 应该写但没写）：
```
- FUBeautyRenderer.init 500ms setup timeout
  - 依据：iPhone 12 实测 setup 4 参数 + AI 模型 ~200-400ms，500ms 保守
  - 假设：仅美颜 4 参数 + 无贴纸/滤镜
  - 阈值重估触发：新增 ≥5 个 SDK property write / 新增 sticker/滤镜 bundle
```

### 在后期里程碑用到已有基础设施时

进入 spec §0.3 范围三圈时：
- **必查**当前功能是否触及**早期里程碑立的阈值参数**（timeout / 帧率上限 / 内存上限 / 重试次数 / cache size 等）
- 若触及且新功能显著改变负载（如 K 期加 25 参数 vs B 期 4 参数），**在 spec 里明示**：
  - 早期阈值 X ms
  - 新负载估计 Y ms
  - 决策：**修 or 保留原因**（如"K 期虽加 25 参数但单次 apply 仍 <1ms，B 阈值仍有效"）

**不能默认沿用**——需要明示估算过。

### grep 阈值定位

工程内常见阈值 grep pattern：
```bash
# 时间阈值
grep -rnE "elapsed\s*>\s*[0-9.]+" Sources Vendor
grep -rnE "timeout.*[0-9.]+" Sources
grep -rnE "throttle\(for:\s*[0-9.]+" Sources
# 数量阈值
grep -rnE "count\s*[><=]+\s*[0-9]+" Sources
grep -rnE "maxRetries\s*=\s*[0-9]" Sources
```

新里程碑 spec §0.3 起草前跑一遍相关模块，看有无老阈值需重估。

## 相邻规则

- [root-cause-investigation.md](root-cause-investigation.md)：追证据链头思维 —— 遇到 X 不工作先看**是否被某个阈值/条件门 static 拦截**（这次的 500ms 就是典型条件门）
- [async-state-fallback.md](async-state-fallback.md)：兜底策略应用 —— 500ms timeout 触发降级 Passthrough 本身合理（有兜底），错在**阈值本身过严**

## 具体到本工程的已知阈值（K 期梳理）

以下已在生产代码里的阈值，未来加功能触及时需重估：

| 阈值 | 位置 | 立于 | 假设 | 触发重估条件 |
|---|---|---|---|---|
| 60ms slider throttle | LiveRoomView.BeautyPanel / BeautySettingsView | B 期 | 单参数拖动 | K spec Spike Task 已 planned 但未真机跑，K 期沿用；未来若加参数或帧率关键场景需 Instruments 验证 |
| 心跳 10s / 失败 >3 次 forceEnd | HeartbeatController | B 期 | 直播心跳链路 | PK / 派对房共用；若加通话心跳并发需重估 |
| 弱网 ≥10 次质量 ≤5 降帧 / ≥30 次强制下播 | NetworkQualityMonitor | B v5 | 直播弱网 | PK / 派对房沿用；若加通话质量监控需重估 |
| 后台切换 20s 相机 forceEnd | LiveStore watcher | B v5.2 | 直播态 | 通话态用 D v5.2 独立分支不共用 |
| 15s 私 call 回直播倒计时 | CallView returnLiveCountdownOverlay | D 期 | 通话结束回直播 | 无重估触发 |
| PK 邀请 15s 超时 / QUICK 3s RETRY 15s 轮询 | PKCountdownController | G 期 | 5 并发 PK 邀请 | 无重估触发 |

## 不适用

- 明确不会随功能扩展变化的常量（如物理定律相关 / 平台硬性上限 / 后端合约固定值）
- 短期实验性 A/B 阈值（本身就是"待重估"状态）

## 历史教训

- **2026-07-02 K 里程碑真根因**：B 期 500ms setup timeout 是保守估计，K 期 25+ 参数处理 setup 实测 585ms 属于正常 —— 但代码里 `if elapsed > 0.5 { throw }` 硬 fallback 导致美颜功能整体挂 apply 路径。花 3 次下游补丁（onAppear apply / onReceive throttle / Sharer sink 优化）才追到根因。**沉淀本规则**+ 修 FUBeautyRenderer.init 只 warning 不 throw。
