import Foundation

/// DecodingError 友好描述：codingPath + case 描述拼出来，dev 调试用。
///
/// 原在 `PartyRoomListView.swift` 内，E-spec §0.2 迁移到 `Sources/Party/Utils/`，
/// 供 `PartyRoomListView` + `PartyListStore` 层复用。
enum PartyDecodeErrorDescriber {
    static func describe(_ err: DecodingError) -> String {
        switch err {
        case .typeMismatch(let type, let ctx):
            return "类型不匹配 \(type) @ \(pathOf(ctx)) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "缺值 \(type) @ \(pathOf(ctx))"
        case .keyNotFound(let key, let ctx):
            return "缺 key '\(key.stringValue)' @ \(pathOf(ctx))"
        case .dataCorrupted(let ctx):
            return "数据损坏 @ \(pathOf(ctx)) — \(ctx.debugDescription)"
        @unknown default:
            return "\(err)"
        }
    }

    private static func pathOf(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map { $0.stringValue.isEmpty ? "[\($0.intValue ?? -1)]" : $0.stringValue }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }
}
