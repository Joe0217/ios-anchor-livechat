# iOS decode userId 字段必 String/Int 兼容

## 规则

**任何接口 decode 时，userId / 类似 ID 字段必须 String/Int 双兼容**，不参 H5 `type.ts` 的 TypeScript 类型声明。

## Why

H5 `anchor-livechat-h5/src/api/user/type.ts` 多处声明 `userId: string`（line 11/47/139 等），但**这不是接口真契约**：

- trial #2 (I-1 黑名单) 真机抓包：`BlackListData.userId` 实际返 string ✓
- trial #3 (H-0 用户详情) 真机抓包：`UserInfoData.userId` 实际返 **number** (`__NSCFNumber` 1000001877) ❌
- LiveListAnchor 早就发现混发问题，已用 `decode(String) ?? decode(Int64) → String` 兼容

**真因**：H5 TypeScript 类型声明是开发者手写，后端实际给的是 JSON 原生类型（Number / String）—— 两者经常不一致。**iOS 严格 Codable 会 fail-loud** 触发 decode 错误，但业务上这不是契约破坏，是 H5 类型声明撒谎。

## How to apply

### Decoder 模板（NSNumber 桥接安全版）

```swift
var userIdStr: String?
if let s = dict["userId"] as? String, !s.isEmpty {
    userIdStr = s
} else if let n = dict["userId"] as? NSNumber {
    // 排除 Bool 桥接（NSNumber 含 Bool/Int 两态，objCType "c"/"B" = Bool）
    let cType = String(cString: n.objCType)
    if cType != "c" && cType != "B" {
        userIdStr = n.stringValue
    }
}
guard let userId = userIdStr, !userId.isEmpty else { return nil }
```

### Codable struct 版（如用 Codable 而非手写 dict 解析）

```swift
extension MyModel: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId 接口侧 String/Int 混发，统一收为 String
        if let s = try? c.decode(String.self, forKey: .userId) {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .userId, in: c, debugDescription: "userId neither String nor Int64")
        }
        // 其他字段...
    }
}
```

## 适用范围

- ✅ `userId` / `followUserId` / `targetUserId` 等所有用户 ID 字段
- ✅ `roomId` / `anchorId` / `giftId` 等业务 ID 字段（同款 H5 type.ts 类型不可信）
- ❌ **不适用** float/double 字段（这些类型相对稳定）
- ❌ **不适用** Bool 字段（用 NSNumber objCType 严格判，参 `trial #3 step 1c` followed 字段教训）

## 历史教训

- 2026-06-25 trial #3 H-0 step 3 真机反悔 #1：UserProfileService.parseDetail 严格 String fail-loud，真接口返 `__NSCFNumber` → 详情页永远显示错误态。spec §2.3 v3 修订 + 本规则沉淀。
- LiveListAnchor 早就发现并 String/Int 兼容（Sources/Home/LiveTab/List/LiveListModels.swift:47-58），是历史正确实践。
- ⚠️ **预防性检查未做的模块**：trial #2 BlocklistItem 严格 `let userId: String` Codable，真机验证时 blacklist 接口实际返 string 才没出 bug。但若后端某次改了类型，会同款挂。**TODO**：trial #4 启动时回看 BlocklistItem 是否需补 String/Int 兼容。

## 与既有规则关联

- 不与 `error-handling.md` 冲突：本规则是 decode 容错策略，不是错误处理
- 补充 `feature-pipeline-complexity-tier.md`：spec §0 H5 二次校验时**不能只信 type.ts**，必须真机/抓包验证类型
