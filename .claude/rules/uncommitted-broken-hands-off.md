# 大量 uncommitted pre-existing broken = 多会话协作信号 · 不要顺手修

> 来源：2026-07-14 P1-6 主播审核弹窗 impl 后 sanity build 挂 3 处 pre-existing，第 1 处 PartyRoomSeat memberwise init 我"顺手补"（理由"语言规则机械修复"），第 2 处 UserCardServiceFakes 被 linter/另一会话在两次读之间自动修（活跃改文件的证据），第 3 处 UserCardStore.toggleBlock 涉业务改造 stop。用户澄清"UserCard 有其他会话接手" + `git status` 揭示 20+ 未提交 M 文件 = 大规模多会话 refactor 进行中。第 1 处不该动。

## 规则

impl 阶段遇到 build/runtime broken，若 `git status` 显示大量 uncommitted 文件（**M/A/D ≥ 5 且多个模块目录**），且 broken 位置**不属于本任务范围**：

**默认动作 = stop + 报告用户，不顺手修**，即使"看起来只是补 missing memberwise init / 补 stub 参数 / 加 protocol conformance 之类的语言规则机械修复"。

## Why

Uncommitted 大量 pre-existing 改动 = **另一个会话正在活跃工作**的强信号。多会话协作场景里：

1. **"机械"修复也可能与另一会话意图冲突**
   - 我在 struct A 上顺手补了 memberwise init（理由：Swift 规则强制）—— 但另一会话可能故意让 struct A 走 Decoder-only，后续会改所有调用方；我提前补的 memberwise init 变成 dead code + 他们最终 diff apply 冲突
2. **顺手 fix 掩盖 refactor 半成品的信号**
   - 那个会话可能有明确的"分步 refactor"节奏（先改类型 → 后改所有调用方 → 最后 commit 一次性通过 build）；我插进去补齐 = 打乱他们的节奏
3. **同一文件多会话并写的冲突几乎必然**
   - 我这次 Edit PartyRoomSeat.swift 时被 tool 提示"File has been modified since read"—— 说明另一会话在活跃改。任何我加的改动都要 rebase/merge

## How to apply

### Preflight 判定"多会话协作场景"

impl 阶段第一次遇到 build 挂：

```bash
# 1. HEAD 状态：主分支上次 commit 是否 build 过？
git log --oneline -1
# 2. 工作区 uncommitted 规模
git status --short | wc -l
# 3. 涉及的模块目录
git status --short | awk '{print $NF}' | xargs -n1 dirname | sort -u
```

**判定信号（任一命中即 stop）**：
- HEAD 绿 + 工作区 M/A/D ≥ 5 → 大概率 pre-existing broken 是**另一会话进行中**
- 工作区改动跨 ≥ 3 个模块目录 → 大概率大规模 refactor
- 同一文件在 Read → Edit 间隙被 linter/别人改（tool 报"File has been modified"）→ **实锤活跃另一会话**

命中即：**只做本任务范围内改动 + 报告用户 uncommitted broken 属另一会话**，让用户拍板：
- (A) 我 stash pre-existing → build 本任务 → commit → unstash（复杂但可 commit）
- (B) 等另一会话完成 → 主分支通后再 commit（推荐，最少冲突）
- (C) 用户授权我"帮那个会话收尾"→ 我读全部涉及文件后再一起改（**必须显式授权**，不能默认）

### 反例（本次真犯）

```
[iteration 1] Build 挂 PartyRoomSeat memberwise init 缺
→ 我判"语言规则机械修复"顺手补 51 行
→ 触发 code-review-discipline §3 顺手 fix 反模式

[iteration 2] Build 又挂 UserCardServiceFakes 缺参
→ 读文件时 linter/另一会话已自动修（**信号强度到顶了**）
→ 我竟然还继续排查 iteration 3

[iteration 3] Build 挂 UserCardStore.toggleBlock 调 protocol 不存在的 unblock
→ 涉业务改造，才 stop
→ 应该 iteration 2 就 stop
```

### 正例（应该的做法）

```
[iteration 1] Build 挂
→ git status → 发现 20+ M 跨 UserCard/Party/Gift/Home 多模块
→ 立即 stop：不动任何非本任务文件
→ 报告用户：uncommitted broken 属另一会话，等他们完成 or 你授权我 stash+commit
```

## 触发场景

- ✅ 多人协作 branch（多会话/多开发者同时在同一 branch 工作）
- ✅ impl 阶段 sanity build 首次挂
- ✅ git status M ≥ 5 且跨多模块
- ❌ 单人 branch + 自己上一次会话遗留的未收尾工作 —— 属"自己的活儿自己收"

## 与既有 rule 关联

- [code-review-discipline.md](code-review-discipline.md) §3 "禁止私自修改" —— 本 rule 是 §3 在**多会话协作场景**的具体应用；§3 治"复查模式" / 本 rule 治"impl 模式遭遇 pre-existing broken"
- [root-cause-investigation.md](root-cause-investigation.md) §2 "下游 2 次补丁失败强制上溯" —— 本 rule 补"上溯之后的判断"：上溯到 uncommitted broken 时应识别"多会话信号"而非继续排查根因
- CLAUDE.md "修改代码前 MUST 先阅读理解现有代码" —— 触碰另一会话正在改的文件违反此约（他们的意图我不可能凭当前 diff 读全）

## 不适用

- 主分支 HEAD 就是 broken（不常见但发生）—— 属"团队级 broken"，我该修
- uncommitted 只 1-2 文件同模块 —— 大概率是我自己上次会话遗留，属"我的活儿"
- 用户显式授权（如 P1-6 会话中"帮那个会话收尾"）—— 用户拍板后可动

## 历史教训

- **2026-07-14 P1-6 主播审核弹窗**：3 处 pre-existing broken 我补了 1 处才 stop；用户澄清"UserCard 有其他会话接手" + `git status` 揭示 20+ M 跨 UserCard/Party/Gift/Home 多模块。本 rule 沉淀让未来遇到"大量 uncommitted broken"立即识别为多会话信号，第一时间 stop 而非顺手修。
