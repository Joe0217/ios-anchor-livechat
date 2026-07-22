# 改 SwiftUI View init 参数后必 grep Preview 目录扫全调用

> 来源：2026-07-09 会话 ChatDetailView 单次 build 内**同一模式 3 次犯**：
> - `privateItems / privateItemsLoading` 新增，`previewEmpty` / `previewError` 漏（我第一次补 Preview）
> - `replyPointsStore` 新增（linter 后补的），三 Preview 各补一份
> - `originProfileUserId` 新增，三 Preview 又漏，第三次同一位置报错

## 规则

**改任何 SwiftUI View struct 的存储属性 / init 签名**（新增必填参数、改类型、改名）时：

1. **必 grep 全工程该 View 的调用点**（含 Preview 目录）
2. **每个调用点判 3 档**：
   - 生产代码 → 传入真实值
   - Preview / DEBUG → 传 nil / 默认 / mock
   - Test / Snapshot → 传 fixture
3. **同一批 view 多个 Preview 变体（loaded/empty/error）改一个就必须改全部** —— 别只改跟当前 build error 那一处

## Why

- **Preview 也参与全量 build**（不只 preview 渲染时），DEBUG target build 会编译 `#if DEBUG` 块——init 参数缺失直接 fail
- 同一 View 通常有 loaded / empty / error 3+ Preview 变体，改一处不改其他 = 下次 build 又爆
- SwiftUI init 无 default value 时 required 参数缺失是**硬错**（无 warning 兜底），必扫全

## How to apply

改 View init 后：

```bash
grep -rn "<ViewName>(" Sources/ 2>/dev/null | grep -v "//"
```

例：
```bash
grep -rn "ChatDetailView(" Sources/ 2>/dev/null | grep -v "//"
# 应看到 5+ 处：生产 wrapper（ChatDetailContainer / ChatDetailBottomSheet）+ 3 个 Preview 变体
```

判断遗漏：每一个 `<ViewName>(` 调用后括号内应含新参数名，缺一个就补一个。

## 更彻底：给 View 提供 preview 静态工厂

若某 View 长期有 3+ Preview 变体且 init 参数频繁增删，做**一次性重构**：

```swift
#if DEBUG
extension ChatDetailView {
    static func preview(
        messages: [ChatMessage] = [],
        error: Error? = nil,
        peerUserId: Int? = nil
    ) -> some View {
        ChatDetailView(
            store: /* stub store */,
            peerNickname: "Alice",
            peerAvatarURL: nil,
            myAvatarURL: nil,
            mediaItems: [],
            mediaItemsLoading: false,
            privateItems: [],
            privateItemsLoading: false,
            peerUserId: peerUserId,
            originProfileUserId: nil,
            onClose: nil,
            chatType: .regular,
            canCall: false,
            replyPointsStore: .shared
        )
    }
}

struct ChatDetailView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ChatDetailView.preview(messages: sampleMessages, peerUserId: 12345)
            ChatDetailView.preview(messages: [])
            ChatDetailView.preview(messages: [], error: NSError(...))
        }
    }
}
#endif
```

**下次改 init 只改 `preview()` 一处**，3 个 Preview 变体自动跟进。适合 init ≥8 参数或已经改过 ≥3 次的 View。

## 触发条件

- ✅ 改 SwiftUI View struct 存储属性（`let x: T` / `@Binding var x: T` / `@ObservedObject var x`）
- ✅ 显式 `init(...)` 参数增减
- ✅ 删属性 → 也要 grep 掉调用点残留（不然报 `Extra argument`）
- ❌ struct 内私有 `@State` / `@StateObject`（不影响外部 init）
- ❌ computed property / method（不影响 init 签名）

## 与既有 rules 关联

- [toast-vs-banner-consistency.md](toast-vs-banner-consistency.md) §"修一处 pattern 必扫全同 store 同类" —— 同源精神：**改契约必扫全调用点**；本 rule 是"View init 契约"的具体应用
- [prefer-shared-component-over-adhoc.md](prefer-shared-component-over-adhoc.md) —— 若某 View 只被 Preview + 1 处生产 wrapper 使用，改 init 影响面小；跨多处 wrapper 更需 grep

## 历史教训

- **2026-07-09 单次 build 内 ChatDetailView 3 次同错**：init 加 3 组参数（`privateItems*` / `replyPointsStore` / `originProfileUserId`），3 个 Preview 变体每次都要重补一遍。第 3 次修完时才决定沉淀本 rule。触发原因：单次 pull-request 内 init 频繁改动，每次改动人只改**报错位置那一处**（loaded），另外 2 处（empty/error）编译时才暴露 → 下轮 build 又要修。**本 rule 强制"改 init 一次性扫全同类调用点"**。
