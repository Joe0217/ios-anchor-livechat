# /review loop 单轮 prompt 模板

> 由 `.claude/skills/review/SKILL.md` 的 loop 模式使用。每次 ScheduleWakeup 唤醒时，按本模板生成单轮 prompt。

---

## 模板变量

执行前由 skill 主体填充：

- `{BASELINE_REPORT}`：最新的 `docs/plan/代码审查报告-*.md` 路径
- `{LOOP_FINDINGS}`：`.claude/review-state/loop-findings.md` 当前内容（不存在则空）
- `{SCOPE}`：`diff` / `all` / `<路径>`
- `{FILES}`：本轮待审文件清单（按 scope 解析）
- `{ROUND_INDEX}`：当前轮次（从 1 开始）
- `{DRY_COUNT}`：连续 0 新增的轮数
- `{TOKEN_REMAINING}`：剩余预算（来自 `budget.remaining()`，无预算则为 `Infinity`）

---

## 单轮 prompt 模板

```
你正在执行 /review loop 第 {ROUND_INDEX} 轮增量代码审查。

## 上下文

- 范围：{SCOPE}
- 已审查文件：{FILES}（共 N 个）
- baseline 报告：{BASELINE_REPORT}
- loop 累积清单：.claude/review-state/loop-findings.md
- 剩余预算：{TOKEN_REMAINING}
- 连续 dry 轮数：{DRY_COUNT}/2

## baseline 已覆盖的角度

{从 BASELINE_REPORT 读取并总结：}
- iOS 平台规范：已覆盖（核心命中：ITSAppUsesNonExemptEncryption、PrivacyInfo.xcprivacy 等）
- Swift 并发：已覆盖（核心命中：NIMChatroomManager @MainActor、CIImage 跨线程等）
- 内存与资源：已覆盖（核心命中：deinit 缺失、observer 残留等）
- SwiftUI 性能：已覆盖（核心命中：LiveStore 失效风暴、顶层 .animation 等）
- 安全与隐私：已覆盖（核心命中：token UserDefaults、裸 print 泄露、AES 硬编码等）

## baseline 已发现摘要（仅标题 + file，用于去重）

{从 BASELINE_REPORT 和 LOOP_FINDINGS 提取，按 file 分组：}
- Sources/Networking/APIClient.swift
  - P0: Token 存 UserDefaults
  - P0: 裸 print 泄露 token
  - ...
- Sources/Live/LiveRoomView.swift
  - P0: onDisappear guard 矫枉过正
  - ...

## 本轮任务

**挖未覆盖的角度**。不要重复报 baseline 已有的发现。

具体策略（每轮选 1~2 个，前几轮做过的标记 ✓ 跳过）：

1. **API 误用深挖**：是否有 Swift Concurrency 反模式（如 Task { } 不取消、AsyncSequence 泄漏、TaskGroup 错误处理）？
2. **测试盲区**：哪些关键路径无单元测试，且业务逻辑复杂到值得加测试？
3. **依赖耦合**：是否有跨模块强耦合可以解开（如 LiveStore 与 CallStore 双向 ref）？
4. **i18n/RTL 边缘**：阿语 RTL 下是否有 layout 仍写死 left/right，或 SF Symbol 未镜像？
5. **错误码漂移**：APIClient 错误码处理是否覆盖了 CLAUDE.md 列的所有 case（1004/1005/1992/1006/1080/2001）？
6. **资源生命周期**：是否有 Metal/CoreImage/AVFoundation 对象在异常路径未释放？
7. **SDK 升级风险**：当前声网 4.5.2.9.BASIC / 云信 10.10.0 / 相芯 framework 的废弃 API、breaking change？
8. **打包体积**：是否有未压缩资源、重复依赖、debug 符号泄漏到 release？
9. **可访问性**：VoiceOver / Dynamic Type / 高对比度模式覆盖度？
10. **性能盲区**：启动时间、首帧延迟、内存峰值、电量消耗的潜在热点？

## 输出要求

跑工具：用 swiftui-pro skill 或单独 grep / Read 深挖你选的角度。

发现一条新问题后，**严格语义去重**：
1. 拿这条 finding 的 (file, 核心问题描述) 去对比 baseline 摘要
2. 如果语义等价于 baseline 已有项（不管 file/line 是否完全一致），跳过
3. 如果是 baseline 的真子集或细化（"P0-2 包含我现在发现的这个"），跳过
4. 仅当是 baseline 完全未覆盖的新角度时，才追加

追加格式（写入 .claude/review-state/loop-findings.md，append 模式）：

\`\`\`markdown
## Round {ROUND_INDEX} @ <date>

### <P0|P1|P2>-loop-<seq>: <title>
- 角度：<从上面 10 条策略中选的角度名>
- 文件：[file](file)（行 X-Y）
- 风险：<具体后果>
- 修复：<具体建议>
- 与 baseline 区分：<为什么不是已有项的重复>
\`\`\`

如果本轮 0 新增，仍要写一条：

\`\`\`markdown
## Round {ROUND_INDEX} @ <date>

dry — 选了角度「<角度>」，未发现 baseline 之外的新问题。
\`\`\`

## 收敛逻辑

本轮完成后：

- 若新增 ≥1 条 → DRY_COUNT 归 0，下次 ScheduleWakeup 600s 后唤醒（加快）
- 若新增 0 条 → DRY_COUNT++
  - DRY_COUNT >= 2 → 不再 ScheduleWakeup，打印汇总并退出 loop
  - DRY_COUNT == 1 → ScheduleWakeup 1200s 后唤醒（放慢，给一次复活机会）

剩余预算 < 50_000 token 时直接退出（不管 DRY_COUNT）。

## 退出时打印模板

\`\`\`
🔚 /review loop 退出

总轮数：{N}
新增发现：{M} 条（详见 .claude/review-state/loop-findings.md）
退出原因：<连续 2 轮 dry / 预算耗尽 / 用户中断>

后续：
- 查看新发现：cat .claude/review-state/loop-findings.md
- 合并到正式报告：手动 merge 到 docs/plan/代码审查报告-*.md，或下次跑 /review deep 自动归并
- 启动修复：/code-review --fix
- 重启 loop：/review loop {SCOPE}
\`\`\`
```

---

## 实施提醒

1. **每轮 prompt 内必须显式列 baseline 摘要**（前 200 字）—— 不要让 LLM 自己去读 markdown，浪费 token
2. **角度选择有状态**：在 `.claude/review-state/loop-state.json` 记录已尝试角度，避免重复（M2 优化项；本版可先让 LLM 自己挑，靠 prompt "前几轮做过的标记 ✓ 跳过" 软约束）
3. **去重是 LLM 任务**：不要在 skill 主体做字符串相似度计算，让 LLM 在 prompt 内判断后写盘
4. **ScheduleWakeup 间隔避开 :00 和 :30**：本身用 600/1200s 已避开 cache 5min 边界
5. **退出时不要清 .claude/review-state/loop-findings.md**：保留累积，用户可手动归档

---

## 与 deep 模式的关系

| 维度 | deep | loop |
|---|---|---|
| 触发方式 | 一次性 | 持续 |
| 维度数 | 5 维并行 | 每轮 1~2 维 |
| 对抗验证 | 3 票 ≥2 通过 | 无（LLM 单轮判断） |
| 输出 | `docs/plan/代码审查报告-*.md`（snapshot） | `.claude/review-state/loop-findings.md`（mutable 累积） |
| 去重 | 同维度内 | 跨 baseline + 跨轮 |
| 退出 | 自然结束 | dry / 预算 / 中断 |

**协作模式**：deep 跑铺底，loop 持续挖深，loop 累积到一定量人工 merge 回 deep 报告，再跑下一次 deep 重建 baseline。
