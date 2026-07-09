import Foundation

/// 直播公告 model（对齐 H5 liveAnnouncementPopup.vue）
struct LiveAnnouncement: Equatable {
    let content: String
}

/// 公告 API 错误（对齐 H5 code=1070 敏感词）
enum AnnouncementError: Error {
    case sensitiveWords(hits: [String])   // code=1070 敏感词命中
    case generic(String)                   // 其他业务错误
}

/// 公告最大字数（对齐 H5 textarea `maxlength=120`）
let announcementCharLimit = 120
