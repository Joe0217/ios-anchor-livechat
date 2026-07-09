# 列表下拉刷新期必须保留已有 items 视觉

> 来源：2026-07-10 E 期 PartyListStore v1 `beginRefresh` 内 `state = .loading` → UI 走 loadingView 覆盖 → rooms 视觉消失 → 数据到重回 → 闪烁 UX。用户"每次做下拉刷新都会犯"要求精简沉淀。

## 规则

任何"列表 + 下拉刷新 (`.refreshable` / pull-to-refresh)"场景，Store 的 refresh 语义**必须保留已有 items 视觉**，UI 层不能因 refresh 切到"全屏 loading 覆盖"清空列表。

## Why

`.refreshable` 手势下拉时用户视觉预期 = **列表在原地更新** + 顶部 spinner（SwiftUI 自带）。若列表消失重现，用户体感等同"数据丢失/网络异常"—— iOS 应用严重反模式。

**具体错例**（本次真犯）：

```swift
// ❌ 反模式：refresh → state.loading → rooms 视觉消失
private func beginRefresh() {
    currentTask?.cancel()
    loadedPageCount = 0
    state = .loading  // 无论当前有无 rooms 一律清空
    ...
}
```

**正例**：

```swift
// ✅ 保留视觉：仅无 items 时走 loading
private func beginRefresh() {
    currentTask?.cancel()
    loadedPageCount = 0
    switch state {
    case .loaded(let items, _), .loadingMore(let items), .pageError(let items, _):
        state = .refreshing(items: items)   // 保留视觉；.refreshable 自身管顶部 spinner
    case .idle, .loading, .refreshing, .error:
        state = .loading                    // 无 items 可保留，全屏 loading 合理
    }
    ...
}
```

## How to apply

### State enum 加 `.refreshing(items:)` 中间态

- 状态机迁移：`loaded/loadingMore/pageError → refreshing(oldItems)`（非 `→ loading`）
- 完成时：`refreshing(_) → loaded(newItems) / error / pageError`
- UI switch case：`.refreshing` 走"有 items 的列表 view"，与 `.loaded` 视觉一致

### Preflight（写 refresh 逻辑时的自检）

- [ ] refresh 期用户能否看到当前列表？若"看不到，先清空再显示"→ 反模式
- [ ] refresh 是否走 `state = .loading` 单一态？若是 → 拆 `.loading`（首拉）vs `.refreshing(items)`（有数据刷新）
- [ ] 无 items 时（首拉/error）refresh 可以走 loading（无视觉可保留）

## 触发场景

- ✅ 所有含 `.refreshable` 的列表 view（房间列表 / 朋友圈 feed / 消息列表 / 直播列表 / 黑名单等）
- ✅ 状态机含"加载 loaded/error"的 Store，refresh 入口

## 不适用

- 单一 loading spinner UI（无列表数据可保留）
- 纯网络请求 Store（无 UI 视觉概念）
- 用户明示"每次刷新都要闪一下"的特殊设计（极少）

## 与既有 rules 关联

- [async-state-fallback.md](async-state-fallback.md)：同源精神"loading 占位是 dead-state 反模式"，本 rule 是列表刷新场景的具体应用
- [feature-pipeline-complexity-tier.md](feature-pipeline-complexity-tier.md) §step 3 反悔归类 "spec 漏 case"：本 rule 沉淀避免下次 spec §2 状态机漏 refreshing 态

## 历史教训

- **2026-07-10 E 期 PartyListStore**：v1 直接 `state = .loading`，用户下拉看到全屏 ProgressView 覆盖 + rooms 视觉消失 → 反馈"体验不好"。v4 加 `.refreshing(items)` 态 + 状态机迁移更新 + spec §2 迁移图 v3。本规则精简沉淀让未来所有列表 refresh 一次做对。
