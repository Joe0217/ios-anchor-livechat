import Foundation

/// CDN 图片按需缩放尺寸档位。
///
/// **设计原则**：档位越少缓存命中率越高。同一头像 URL 在列表 48pt 和详情 56pt
/// 都拉同一档 w_180，命中同一份缓存 —— 避免"档位过细反而多拉图"的反效果。
///
/// - 头像 2 档（分界 72pt）：小档覆盖列表/评论头像，大档覆盖 Profile 大头图
/// - 礼物 1 档：icon 尺寸集中在 40-62pt，一档 w_200 兜住
/// - 其余（背景/九宫格/封面/朋友圈九宫格等）用 `.custom(width:)`
enum CDNImageSize {
    /// 小头像 w_180（<72pt，列表/评论/入口）
    case avatarSmall
    /// 大头像 w_420（>=72pt，Profile 大头图 / 详情页头像）
    case avatarLarge
    /// 礼物 icon w_200（40-62pt 礼物 icon 统一档）
    case gift
    /// 自定义宽度（直播卡背景/朋友圈九宫格/封面等非头像非礼物尺寸）
    case custom(width: Int)

    fileprivate var query: String {
        switch self {
        case .avatarSmall: return "w_180"
        case .avatarLarge: return "w_420"
        case .gift: return "w_200"
        case .custom(let w): return "w_\(w)"
        }
    }
}

/// CDN 缩放模式（对齐阿里云 OSS resize m_ 参数）。
enum CDNImageMode: String {
    /// 等比缩放（默认，可能留白）
    case fit = "m_lfit"
    /// 等比缩放并居中裁剪（用于头像等要充满容器的位置）
    case fill = "m_fill"
}

extension URL {
    /// 按 OSS 图片处理规则拼装缩放参数，对齐 H5 `filters/general.ts` 的 `replaceResourceUrl`。
    ///
    /// 结果形如：`{原URL}?x-oss-process=image/resize,w_180,m_fill`
    ///
    /// - 非 http(s) scheme（asset://、file://）短路返回原 URL
    /// - 已有 query 保留，仅追加/覆盖同名 `x-oss-process`
    /// - URL 解析失败原样返回
    func cdnScaled(_ size: CDNImageSize, mode: CDNImageMode = .fit) -> URL {
        guard let scheme = scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return self
        }
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "x-oss-process" }
        items.append(URLQueryItem(
            name: "x-oss-process",
            value: "image/resize,\(size.query),\(mode.rawValue)"
        ))
        components.queryItems = items
        return components.url ?? self
    }
}
