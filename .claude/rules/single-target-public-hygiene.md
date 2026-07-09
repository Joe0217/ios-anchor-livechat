# 单 target 工程避免 `public` + 工具扩展禁重复造轮子

> 来源：2026-07-09 会话真机 build 一次连爆 5 处（Config.imBind / DataSource × 3 `public + internal type` 冲突 + RewardProgressView `Color.init(hex:)` 与 UserLevelBadge.swift 重复定义）

## 规则

### 1. 单 target 工程默认 internal

Hily 工程只有一个 target（无 SPM 拆包 / 独立 framework 计划）——**源码里 `public` 修饰词 100% 是噪声**，且经常制造编译错：

```swift
public extension CommonGiftPanelConfig {
    // ❌ 参数用 internal 类型 → "Method must be declared internal because its parameter uses an internal type"
    static func imBind(service: GiftMessageServiceProtocol, ...) -> Self { ... }
}

public final class DefaultGiftDataSource {
    // ❌ 参数 GiftService.Scene 是 internal
    public init(scene: GiftService.Scene) { ... }
}
```

**How to apply**：
- 写新代码 / review 时看到 `public class` / `public struct` / `public func` / `public extension` → 除非确认将来要抽 SPM 包，**去掉 `public`**
- 遇到"Method must be declared internal because its parameter uses an internal type" → **优先降级为 internal**，别升级依赖类型的可见性
- grep 自查：`grep -rn "public " Sources/` 看是否有历史遗留

### 2. 工具扩展禁重复造轮子

Color / String / View / URL 等类型的**工具扩展**在整个工程里只写一份。本次 `Color.init(hex:)` 已经在 **4 处**独立定义（Theme.swift / ChatColors.swift / UserLevelBadge.swift / RewardProgressView.swift），签名部分重叠碰撞就 `Invalid redeclaration`。

**How to apply**：
- 写 `extension Color/String/View { init(hex:) / func xxx }` 前 grep 一次：
  ```bash
  grep -rn "extension Color\|extension String\|extension View" Sources/ | grep -i "<你要加的方法名>"
  ```
- 有 → 复用现有（internal 同 module 可访问）
- 无 → 优先放 `Sources/Core/Extensions/` 或 `Sources/DesignSystem/`（复用最广的位置），不写在功能文件私有 extension 里
- **禁止**在功能文件里 `private extension` 造签名相同的工具方法——`private` 只让本 file 用，但类型级 name collision 仍会 `Invalid redeclaration`

## Why

- **规则 1**：Swift 里 `public` 的成员默认继承外层 `public`，一旦引用 internal 类型（协议/enum/struct）就编译错。单 target 内部代码所有类型都 internal，`public` 只带来错、无收益
- **规则 2**：type extension 的 method 名字挂到类型命名空间上，跨 file 同签名 = redeclaration 错，`private` 修饰词救不了

## 不适用

- 明示要抽 SPM / framework 的独立子模块（本工程目前无）
- 主 target 需要暴露给 test target 的接口（本工程 HilyTests 用白名单直接编源码，不需要 public）
