import Foundation
import NIMSDK

/// 通用云信自定义消息附件：把 raw JSON 解码为字典原样保留，业务层按 `attachType` 字段分发。
///
/// 注册方式：在 `NIMSDK.shared().setupOnce()` 内调
/// `NIMSDK.shared().chatManager.register(GenericCustomAttachmentCoder())`。
final class GenericCustomAttachment: NSObject, NIMCustomAttachment {
    let rawDict: [String: Any]
    let rawJSON: String

    init(rawDict: [String: Any], rawJSON: String) {
        self.rawDict = rawDict
        self.rawJSON = rawJSON
        super.init()
    }

    func encode() -> String {
        rawJSON
    }
}

/// 注册到 `NIMSDK.shared().chatManager` 后，所有自定义消息自动解码为 `GenericCustomAttachment`。
/// 业务层从 `attach.rawDict["attachType"]` 取类型 → `AttachType(raw:)` 分发。
final class GenericCustomAttachmentCoder: NSObject, NIMCustomAttachmentCoding {
    func decodeAttachment(_ content: String?) -> NIMCustomAttachment? {
        guard let content = content,
              !content.isEmpty,
              let data = content.data(using: .utf8) else {
            return nil
        }
        // 优先按字典；若顶层是数组/其他，解析失败返 nil 让业务侧降级到 placeholder
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return GenericCustomAttachment(rawDict: dict, rawJSON: content)
    }
}
