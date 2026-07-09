---
name: feature-pipeline
description: 重大里程碑 / 跨模块新功能落地的 7 步质量优先流水线 — 用于 Hily 项目 B/C/D/E/F/G/H/I/J 里程碑或任何 spec §3 状态机 + view + 单测 + 真集成的功能。trial #1 (Cycle 朋友圈 tab, 2026-06-24) 验证通过后 codify。
---

# Feature Pipeline (质量优先 7 步流水线)

## 何时调用

**推荐用**（满足任一）：
- 路线图里程碑级任务（A→J 任一里程碑或其子模块）
- 跨 3+ 文件 + 含状态机 + 含 UI
- 含真集成（HTTP / SDK / NIM / Agora）的功能
- 用户明示"按流水线走" / "走完整流程"

**不要用**（满足任一）：
- typo 修复 / 单行 bug
- 单文件小改动
- 复用已有 view 的 cosmetic 调整
- 用户明示"快速改"

## 总体原则

1. **质量优先于效率**：禁止"跳步" / "偷工"。流水线每一步都强制有"验收门 + 记录区"，验收门未达不进下一步
2. **机械化验证**：禁止"差不多覆盖了"；spec §5 反向清单每一项必须有具体单测/Preview/真机用例对应
3. **反悔显式**：任何"原本以为对的、真集成才发现错"的，强制 4 方向归类反思（见 step 3）
4. **沉淀复利**：每次反悔的"通用知识缺失"项 → 写入 `.claude/rules/` 让未来里程碑不重蹈

## 7 步流程

### Step 0 — Spec

**产出**：
- [ ] 业务概念词表（不锁 protocol 名，仅业务语义）
- [ ] H5 / 安卓代码二次校验（**强制前置**：发现冲突回改下游 §2-§5）
- [ ] 状态机草图（伪态文本 + 必要时 Mermaid 辅助）
- [ ] 验收清单（正向 + 反向 / 边界）
- [ ] 复用候选标记（哪些代码应落 Core/，理由）
- [ ] 待问用户清单（trial 进 step 0 前必须 close）
- [ ] 附录 A：spec 写作自检清单

**红队外审**：用 Plan agent 评审 spec（独立 context，不带主会话偏见）；27 条意见量级正常

**验收门**：
- [ ] 用户审过 spec 并签字

**spec 命名规范**：`<里程碑代号>-spec-<功能中文名>-YYYYMMDDHHmm.md`，存 `docs/plan/`

### Step 1a — Store + 状态机 + protocol

**产出**：
- [ ] 词表翻译为 Swift protocol（命名 + 接口签名）
- [ ] 状态机定义（`enum State` + ObservableObject）
- [ ] 正向路径单测
- [ ] 反向 / 边界态单测（非法迁移、回调乱序、并发态）

**验收门**：
- [ ] 单测全过
- [ ] 边界态覆盖率自检：**spec §5 反向清单的每一项必须有对应单测**（写「反向 → 单测」对应表）

### Step 1b — UI 还原

**产出**：
- [ ] **设计稿判断**：有新设计稿 → 调 `/restore-design`；无新设计稿 → **跳过 + record 跳过理由 + 标记『下次业务扩展时一并接入设计稿』作为债**（trial #1 期没明示此分支导致用户事后发现"流水线偷工"，本步已修订）
- [ ] View 接 1a 的 protocol（具体 Store 用 `@StateObject`，store 通过 protocol 注入 service）
- [ ] PreviewProvider 覆盖 spec 列出的全部合法状态（含空、加载、错误、各 tab 切换中间态）

**验收门**：
- [ ] Preview 跑出 spec 列出的全部合法状态
- [ ] View init 签名只依赖 1a 的 protocol（Store 可注入 mock，Preview 可绕过 service）

### Step 1c — API model + 数据层 protocol + Fakes

**产出（默认认可前置步骤已完成多少，本步只补缺口 + 落对应表）**：
- [ ] API request/response Codable models
- [ ] 数据层桥接 protocol
- [ ] Fakes 正常行为（`.success(...)` 路径）
- [ ] **Fakes 异常行为**（网络超时 / 业务码非 0000 / 离线 / 空列表 / **返回非法字段** / 网络延迟 cancel 路径）
- [ ] Codable decode 边界单测（防字段类型偷换 + CodingKey 别名生效反向证伪）

**验收门**：
- [ ] 用 Fakes 跑通步 1a 的所有反向用例
- [ ] **「Fakes 异常 ↔ spec 反向 一一对应表」**（机械化避免"差不多覆盖了"）

### Step 2 — 接线

**产出**：
- [ ] 真 Store + Fakes 数据层接入真 View（**三轨接线**：真 service / Preview service 永挂 / Fakes service 单测）
- [ ] **spec 验收清单覆盖表**（每条 × 单测 / Preview / 真机 三栏 ✓）

**验收门**：
- [ ] spec 验收清单 100% 覆盖（真机 only 项标"留 step 4"）

### Step 3 — 真集成 (接真后端接口 + 真机)

**产出**：
- [ ] Fakes 替换为真 service
- [ ] 真接口下 spec 验收清单全部通过

**反悔机制**：
任何"原本以为对的、真集成才发现错"，强制 4 方向归类反思：
- **spec 漏 case** → 回 step 0 改 spec（标 v2/v3...）
- **状态机错** → 回 step 1a
- **View 结构错** → 回 step 1b（参考 v5.x SwiftUI 坑模式）
- **通用知识缺失** → 沉淀 `.claude/rules/` + 继续

**验收门**：
- [ ] 真接口下 spec 验收清单全部通过
- [ ] 每次推翻假设有对应反思记录（表格 4 列：假设 / 实际 / 反悔方向 / 修复）

### Step 4 — 真机验收

**产出**：
- [ ] 用户在真机走 spec 验收清单（特别是 §5 反向"真机 only"项 + 嵌套手势 + 冷启动竞态）
- [ ] 清单外发现的 bug 不直接修，先回补 spec 验收清单再回测

**验收门**：
- [ ] 用户签字通过

### Step 5 — 代码位置 Review (弱化版)

**产出**：
- [ ] spec §6A 复用候选清单 trial 期实际落位表（位置 / 决策 / 理由）
- [ ] **语义/物理位置一致性检查**：若文件名/类型名暗示不同业务（如 CircleService 但挂 Profile/Moment/），**强制提议移位**而非仅记录（trial #1 已修订此项）
- [ ] trial 期未标记但实际通用的代码 → 评估是否抽

**验收门**：
- [ ] 代码位置与最新复用判断一致

**注**：真复用验证不在本步——等下一个里程碑用到时回看本里程碑代码是否能直接复用

### Step 6 — Retrospective

**产出**：
- [ ] 各验收门有效性逐项核对（**所有"否"的验收门要么删除、要么修改，不能原样保留**）
- [ ] 应删 / 改 / 合 / 拆的步骤建议
- [ ] `.claude/rules/` 新增条目清单
- [ ] 流水线本身反思（哪步价值低 / 高 / 应换做法）

## 产出物路径规范

| 文件 | 路径 | 命名 |
|---|---|---|
| Spec | `docs/plan/` | `<里程碑代号>-spec-<功能名>-YYYYMMDDHHmm.md` |
| Checklist | `docs/plan/` | `<里程碑代号>-pipeline-checklist-<功能名>-YYYYMMDDHHmm.md` |
| Rule 沉淀 | `.claude/rules/` | `<规则主题>.md`（kebab-case） |

**Checklist 模板**：参考 `docs/plan/流水线试运行-checklist-202606241500.md`（trial #1 产物）

## Trial #1 复盘吸收的关键纪律

1. **step 0 spec 必含 H5 / 安卓二次校验**：H5 蓝本里有大量死代码（路线图 §六），spec 不能盲信文档要追源码
2. **step 1c 反向场景必须含「返回非法字段」decode tests**：防 CodingKey 别名失效（trial #1 挖出 `MomentPost.likeCount` 缺别名 bug）
3. **异步派生 state 禁 loading dead-state**：见 `.claude/rules/async-state-fallback.md`（trial #1 段位字段二选一坑沉淀）
4. **嵌套 TabView(.page) 在 iOS 16 真机一次过**：trial #1 验证可行；spec §6B.2 降级阈值未触发，可作为推荐方案
5. **真机验收必须含飞行模式 / 冷启动场景**：单测 + Preview 永远验不出"网络突变" + "进程冷启动竞态"
6. **反悔记录用表格而非散文**：表格机械化让回溯易追，trial #1 step 3 4 次推翻全表格记录

## 不要做

- 不要"跳步"（每步验收门都必须达成）
- 不要"差不多覆盖了"（spec § 反向清单每条必须有对应单测/Preview/真机）
- 不要"我先快速看一下"（用对应表逼出系统性核对）
- 不要在 step 3 反悔不归类（4 方向必选其一）
- 不要在没有新设计稿时假装跑了 /restore-design（step 1b 明示"跳过 + record"是合法选项）

## 引用 / 进一步学习

- **trial #1 完整 checklist 含全部记录区**：`docs/plan/流水线试运行-checklist-202606241500.md`
- **trial #1 产出的 spec 示例**：`docs/plan/A-spec-Cycle朋友圈tab-202606241600.md`
- **trial #1 沉淀规则**：`.claude/rules/async-state-fallback.md`
