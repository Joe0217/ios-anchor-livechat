# Toast vs Error Banner · 同 store 内 pattern 一致

> 来源：2026-07-03 L stage 3 修 P1-2 (20004 → toast)，遗漏同 store 4 处同类语义（wish theme empty/长度、wishlist 满、count>99）；后一次 /review 才暴露

## 规则

**同一 store 内，error 语义要分层且 pattern 一致**：

| 语义 | 展示 | 状态 |
|---|---|---|
| **可修正边界**（用户输入 / 数量上限 / 冷却 / 前置校验 / 后端"再试"类业务码） | `showToast(msg)` 2s 自清 | state 保持 `.editing` |
| **接口/系统错误**（网络失败、SDK 崩溃、code -1、非预期后端错误） | `state = .error(msg)` 顶部红色 banner | state 转 `.error` |

**修一处 pattern，必扫全同 store 同类**：改一处 `state = .error(...)` → `showToast(...)` 时，必须 grep 同 store 内所有 `state = .error(...)` 逐一判档，避免分裂。

## Why

红色 error banner 是"严重错误"视觉语言：占顶部一整行 + 手动 ✕ 关闭。
把"简介留空"、"数量超 99"这类**用户可修正边界**用 banner 展示，用户体感 = 遇到系统故障；正解是底部轻量 toast 自清。

**分裂代价**（L stage 3 真事故）：`WishSettingStore.submitWishTheme` 20004（后端码）用 toast，但**同函数**内 empty/超长（前置校验）仍是 banner —— 用户看到"错误码 → toast 提示可再试"和"输入错 → 红色 banner 像出大事"的**同类错误分裂展示**，是明显 UX 分裂。

## How to apply

**改动前**：
- [ ] 判档：当前 `state = .error(...)` 是可修正边界（用户/UI 可自纠）还是接口/系统错误？
- [ ] 若是可修正边界 → 用 `showToast(...) + state = .editing`
- [ ] 若是接口/系统错误 → 保持 `state = .error(...)` banner

**改动后**：
- [ ] `grep 'state = .error' <本 store 文件>` 扫全部同 store 引用点
- [ ] 逐一判档：任一"可修正边界"分支若仍用 banner → 一起改 toast
- [ ] Store 内**同类语义必须同类展示**

**UI 层已 disable 的 store 分支也修**：即便 View 层 button `.disabled` 阻断触发，Store 层保留一致 pattern 便于未来 UI refactor 不留死角。

## 不适用

- 单一 error 语义的简单 store（1-2 处 `state = .error`）— 分裂风险低
- Store 不由 View 直接消费（如 background pipeline）— 展示层非本 store 责任

## 与既有规则关联

- [async-state-fallback.md](async-state-fallback.md)：本规则补"错误展示分层"，async fallback 补"loading dead-state"
- [code-review-discipline.md](code-review-discipline.md) §7 "工具产出 ≠ 二次复查"：**修一处 pattern 应扫全同类** 是二次复查纪律的一部分
