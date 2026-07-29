import Foundation

/// 全局图片配置分类（H5 `getAppPicByType` type 参数）。
/// 参考 H5 `stores/modules/home.js:436` 注释：
///   1: 启动页 / 2: banner / 3: 游戏 / 4: 挂件 / 5: 导量弹窗 / 6: 榜单 / 7: 分类贴图
enum AppPictureType: Int, CaseIterable {
    case splash = 1
    case banner = 2
    case game = 3
    case pendant = 4
    case guidePopup = 5
    case ranking = 6
    case categorySticker = 7
}

/// 通用图片配置条目。
///
/// H5 一份接口喂多种业务位（首页 banner / 榜单 / 挂件 …），字段大部分是可空的。
/// 只把当前 iOS 已经用的字段声明进来；其他字段保留 raw 副本，未来接入时再展开 Codable。
struct AppPictureItem: Identifiable, Equatable {
    let id: String
    let picUrl: String?
    let directUrl: String?
    /// H5 用逗号分隔的多值字符串（如 "首页,榜单"），iOS 拆成数组。
    let bannerPosition: [String]

    /// 非全局图片配置接口也可适配到统一的 `LiveBanner` 外观与轮播行为。
    init(id: String, picUrl: String?, directUrl: String?, bannerPosition: [String] = []) {
        self.id = id
        self.picUrl = picUrl
        self.directUrl = directUrl
        self.bannerPosition = bannerPosition
    }

    var picURL: URL? {
        guard let s = picUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var directURL: URL? {
        guard let s = directUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// 判定图片位归属（对齐 H5 `bannerPosition?.includes('首页')`）。
    func belongsTo(position: String) -> Bool {
        bannerPosition.contains(position)
    }
}

extension AppPictureItem {
    /// 从字典解码。id 后端可能为 Number/String（H5 `type.ts` 声明不可信，
    /// 参 `.claude/rules/ios-decode-userid-compat.md`）。
    init?(from dict: [String: Any]) {
        let rawId: String
        if let s = dict["id"] as? String, !s.isEmpty {
            rawId = s
        } else if let n = dict["id"] as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType == "c" || cType == "B" { return nil }
            rawId = n.stringValue
        } else {
            return nil
        }

        let positions: [String]
        if let raw = dict["bannerPosition"] as? String {
            positions = raw
                .split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else if let arr = dict["bannerPosition"] as? [String] {
            positions = arr
        } else {
            positions = []
        }

        self.id = rawId
        self.picUrl = dict["picUrl"] as? String
        self.directUrl = dict["directUrl"] as? String
        self.bannerPosition = positions
    }
}

// MARK: - Service protocol

/// AppPicture 数据层协议——真集成走 `AppPictureService.shared`，单测注入 Fake。
protocol AppPictureServiceProtocol {
    /// 按 type 查询图片配置。
    /// - Returns: `[type: [item]]` — H5 响应形如 `{"2": [...]}`。
    func fetchPictures(types: [AppPictureType]) async throws -> [AppPictureType: [AppPictureItem]]
}
