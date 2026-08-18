import Foundation

private extension CodingUserInfoKey {
    static let reviewPlaceholderVideoMatched = CodingUserInfoKey(
        rawValue: "hily.reviewPlaceholderVideoMatched"
    )!
}

/// 网络响应对审核模式条件的三态证据。`isResolved == false` 表示接口没有提供
/// 可用于判断的资料媒体，不能把 `placeholderMatched == false` 解释为全功能账号。
private struct ReviewModeNetworkEvidence {
    let isResolved: Bool
    let placeholderMatched: Bool
}

/// 登录响应中的相册媒体。这里只保留会话权限判定和首屏资料所需字段；登录响应完整时
/// 可同步定案，字段缺失时使用同账号模式缓存，缓存也缺失才保守进入 107。
struct LoginMediaItem: Codable, Hashable {
    let assetId: Int?
    let mediaUrl: String?
    let mediaType: Int?
    let videoCover: String?
    let vaild: Int?

    private enum CodingKeys: String, CodingKey {
        case assetId = "id"
        case mediaUrl, url, videoUrl, mediaType, videoCover, coverUrl, vaild
    }

    init(assetId: Int?, mediaUrl: String?, mediaType: Int?, videoCover: String?, vaild: Int?) {
        self.assetId = assetId
        self.mediaUrl = mediaUrl
        self.mediaType = mediaType
        self.videoCover = videoCover
        self.vaild = vaild
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() {
                assetId = nil
                mediaUrl = nil
                mediaType = nil
                videoCover = nil
                vaild = nil
                return
            }
            if let url = try? single.decode(String.self) {
                assetId = nil
                mediaUrl = url
                mediaType = nil
                videoCover = nil
                vaild = nil
                return
            }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = c.decodeFlexibleInt(forKey: .assetId)
        mediaUrl = Self.firstNonEmpty(
            c.decodeFlexibleString(forKey: .mediaUrl),
            c.decodeFlexibleString(forKey: .url),
            c.decodeFlexibleString(forKey: .videoUrl)
        )
        mediaType = c.decodeFlexibleInt(forKey: .mediaType)
        videoCover = Self.firstNonEmpty(
            c.decodeFlexibleString(forKey: .videoCover),
            c.decodeFlexibleString(forKey: .coverUrl)
        )
        vaild = c.decodeFlexibleInt(forKey: .vaild)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(assetId, forKey: .assetId)
        try c.encodeIfPresent(mediaUrl, forKey: .mediaUrl)
        try c.encodeIfPresent(mediaType, forKey: .mediaType)
        try c.encodeIfPresent(videoCover, forKey: .videoCover)
        try c.encodeIfPresent(vaild, forKey: .vaild)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }
}

/// 数组内单个异常元素不能让整份登录媒体丢失。具体异常形态由下面的原始 JSON
/// 结构日志记录，这里只保留能够独立解码的条目。
private struct LossyLoginMediaItem: Decodable {
    let value: LoginMediaItem?

    init(from decoder: Decoder) throws {
        value = try? LoginMediaItem(from: decoder)
    }
}

/// 登录结果的脱敏结构证据。只记录 JSON 类型、字段名和匹配布尔值，不保留任何响应值。
private struct LoginModeRawEvidence {
    let rootShape: String
    let topLevelKeys: String
    let picListShape: String
    let videosShape: String
    let latestMediaShape: String
    let profileMediaEvidenceResolved: Bool
    let profileMediaExactPlaceholderMatch: Bool
    let anywhereExactPlaceholderMatch: Bool
    let canonicalPlaceholderMatch: Bool
    let placeholderFilenameMatch: Bool
    let urlStringCount: Int
    let mediaPayloadMalformed: Bool

    static func inspect(_ data: Data) -> LoginModeRawEvidence {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return LoginModeRawEvidence(
                rootShape: "invalid-json",
                topLevelKeys: "-",
                picListShape: "unavailable",
                videosShape: "unavailable",
                latestMediaShape: "unavailable",
                profileMediaEvidenceResolved: false,
                profileMediaExactPlaceholderMatch: false,
                anywhereExactPlaceholderMatch: false,
                canonicalPlaceholderMatch: false,
                placeholderFilenameMatch: false,
                urlStringCount: 0,
                mediaPayloadMalformed: true
            )
        }

        let dictionary = root as? [String: Any]
        let keys = dictionary?.keys.sorted().prefix(40).joined(separator: ",") ?? "-"
        var anywhereExactMatch = false
        var canonicalMatch = false
        var filenameMatch = false
        var urlCount = 0
        scan(
            root,
            exactMatch: &anywhereExactMatch,
            canonicalMatch: &canonicalMatch,
            filenameMatch: &filenameMatch,
            urlCount: &urlCount
        )
        var profileMediaExactMatch = false
        var unusedCanonicalMatch = false
        var unusedFilenameMatch = false
        var unusedURLCount = 0
        for key in ["picList", "videos"] {
            guard let value = dictionary?[key] else { continue }
            scan(
                value,
                exactMatch: &profileMediaExactMatch,
                canonicalMatch: &unusedCanonicalMatch,
                filenameMatch: &unusedFilenameMatch,
                urlCount: &unusedURLCount
            )
        }

        let picListShape = fieldShape("picList", in: dictionary)
        let videosShape = fieldShape("videos", in: dictionary)
        let malformed = isMalformedMediaPayload(dictionary)
        let hasUsableMediaField = ["picList", "videos"].contains { key in
            isResolvedMediaField(key, in: dictionary)
        }

        return LoginModeRawEvidence(
            rootShape: shape(of: root, includeArrayItems: false),
            topLevelKeys: keys,
            picListShape: picListShape,
            videosShape: videosShape,
            latestMediaShape: fieldShape("latestIconAndCallVideo", in: dictionary),
            profileMediaEvidenceResolved: profileMediaExactMatch || (hasUsableMediaField && !malformed),
            profileMediaExactPlaceholderMatch: profileMediaExactMatch,
            anywhereExactPlaceholderMatch: anywhereExactMatch,
            canonicalPlaceholderMatch: canonicalMatch,
            placeholderFilenameMatch: filenameMatch,
            urlStringCount: urlCount,
            mediaPayloadMalformed: malformed
        )
    }

    func decisionReason(for result: LoginResult) -> String {
        guard result.userId.map({ $0 > 0 }) == true else { return "missing-user-info" }
        if profileMediaExactPlaceholderMatch { return "raw-profile-placeholder-exact" }
        if result.permissionModeMediaURLs.contains(where: ReviewAccountModePolicy.isPlaceholderVideoURL) {
            return "decoded-placeholder-exact"
        }
        if canonicalPlaceholderMatch { return "canonical-only-not-applied" }
        if placeholderFilenameMatch { return "filename-only-not-applied" }
        if mediaPayloadMalformed { return "media-malformed" }
        if picListShape == "missing" && videosShape == "missing" { return "media-absent" }
        return "placeholder-not-found"
    }

    private static func fieldShape(_ key: String, in dictionary: [String: Any]?) -> String {
        guard let dictionary else { return "root-not-object" }
        guard let value = dictionary[key] else { return "missing" }
        return shape(of: value, includeArrayItems: true)
    }

    private static func shape(of value: Any, includeArrayItems: Bool) -> String {
        if value is NSNull { return "null" }
        if let array = value as? [Any] {
            guard includeArrayItems, !array.isEmpty else { return "array(\(array.count))" }
            let itemShapes = array.prefix(6).map { itemShape(of: $0) }
            let suffix = array.count > itemShapes.count ? ",..." : ""
            return "array(\(array.count))[\(itemShapes.joined(separator: ","))\(suffix)]"
        }
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted().prefix(12).joined(separator: "|")
            return "object(\(dictionary.count)){\(keys)}"
        }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        return "other"
    }

    private static func itemShape(of value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted().prefix(10).joined(separator: "|")
            return "object{\(keys)}"
        }
        return shape(of: value, includeArrayItems: false)
    }

    private static func isMalformedMediaPayload(_ dictionary: [String: Any]?) -> Bool {
        guard let dictionary else { return true }
        return isMalformedArrayField("picList", in: dictionary)
            || isMalformedArrayField("videos", in: dictionary)
    }

    private static func isMalformedArrayField(
        _ key: String,
        in dictionary: [String: Any]
    ) -> Bool {
        guard let value = dictionary[key], !(value is NSNull) else { return false }
        return !isResolvedMediaValue(value)
    }

    private static func isResolvedMediaField(
        _ key: String,
        in dictionary: [String: Any]?
    ) -> Bool {
        guard let value = dictionary?[key], !(value is NSNull) else { return false }
        return isResolvedMediaValue(value)
    }

    private static func isResolvedMediaValue(_ value: Any) -> Bool {
        if let array = value as? [Any] {
            return array.isEmpty || array.allSatisfy(isValidMediaItem)
        }
        return isValidMediaItem(value)
    }

    private static func isValidMediaItem(_ value: Any) -> Bool {
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let dictionary = value as? [String: Any] else { return false }
        return ["mediaUrl", "url", "videoUrl"].contains { key in
            guard let string = dictionary[key] as? String else { return false }
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func scan(
        _ value: Any,
        exactMatch: inout Bool,
        canonicalMatch: inout Bool,
        filenameMatch: inout Bool,
        urlCount: inout Int
    ) {
        if let string = value as? String {
            let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            if URLComponents(string: candidate)?.scheme != nil { urlCount += 1 }
            if candidate == ReviewAccountModePolicy.placeholderReviewVideoURL {
                exactMatch = true
            }
            if matchesPlaceholderIgnoringQueryAndFragment(candidate) {
                canonicalMatch = true
            }
            if URLComponents(string: candidate)?.path.split(separator: "/").last
                == URLComponents(string: ReviewAccountModePolicy.placeholderReviewVideoURL)?
                    .path.split(separator: "/").last {
                filenameMatch = true
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                scan(
                    item,
                    exactMatch: &exactMatch,
                    canonicalMatch: &canonicalMatch,
                    filenameMatch: &filenameMatch,
                    urlCount: &urlCount
                )
            }
            return
        }
        if let dictionary = value as? [String: Any] {
            for item in dictionary.values {
                scan(
                    item,
                    exactMatch: &exactMatch,
                    canonicalMatch: &canonicalMatch,
                    filenameMatch: &filenameMatch,
                    urlCount: &urlCount
                )
            }
        }
    }

    private static func matchesPlaceholderIgnoringQueryAndFragment(_ candidate: String) -> Bool {
        guard let lhs = URLComponents(string: candidate),
              let rhs = URLComponents(string: ReviewAccountModePolicy.placeholderReviewVideoURL)
        else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && lhs.path == rhs.path
    }
}

/// 登录响应（/api/login/v4/login 解密后的 result，取关键字段）。
///
/// H5 蓝本 `loginSuccess(res)` 直接用登录响应本身设 mineInfo（`src/stores/modules/user.js:74-131`），
/// 登录响应中的审核媒体是最高优先级输入；字段缺失时读取同账号的版本化双向模式缓存。
/// 两者都不可用时 fail-closed 到 107；资料接口只更新下次认证缓存，不热切当前会话。
///
/// ⚠️ 2026-07-17 tap-fix 真根因:后端登录响应对未审核账号可能只返 `type`(审核结果类型),不返 `userType`
/// → iOS auto synthesized CodingKeys 只匹配 `userType` key → 解得 nil → `RootView.isRestricted` guard-let
/// 兜底 false → 用户被路由到 MainTabView(而非 RestrictedTabView),tap 无反应 + view log 一条不 fire。
///
/// **修复**:手写 `init(from:)` 让 `userType` **双 key 兜底**(`userType` → fallback `type`),同款 fallback
/// 也覆盖到 `type` 字段。真机首次登录后打 log 抓取真实字段名,若与 userType/type 都不匹配再补 alias。
struct LoginResult: Codable {
    let userId: Int?
    let token: String?
    let loginUuid: String?
    let yxAccid: String?      // 云信 IM 账号
    let imToken: String?      // 云信 IM token
    let userType: Int?        // 2=已审核主播 9=代理，其他=未审核/审核中/被拒
    let nickname: String?
    let icon: String?
    /// H5 `loginSuccess(res) -> setMineInfo(res)` 直接消费登录响应中的 picList。
    /// 它也是 107 / 全功能模式的同步判定源，并随 LoginResult 一起写入 Keychain。
    let picList: [LoginMediaItem]?
    /// 注册响应可能暂时回显提交体中的 videos，而不是归一化后的 picList，保留作兼容回退。
    let videos: [String]?
    /// H5 `mineInfo.userLevel`；登录响应可能直接携带，供 Work 首屏即时展示。
    let userLevel: String?
    /// H5 `mineInfo.chatBubble`：当前穿戴的 Chat Skin URL。
    let chatBubble: String?
    /// 守护 Chat Skin 的等级；主播本人在自己直播间发言时不广播这类皮肤。
    let chatBubbleGuardianLevel: Int?

    // MARK: - 审核态字段（受限首屏 banner 派生源；对齐 H5 newsRestricted/mineRestricted）

    /// 账号状态：0=封禁 / 1=正常（正常态下再由 onReview/type 细分审核中/通过/拒绝）
    let valid: Int?
    /// 审核中标记（true=资料审核中）；对齐 H5 `mineInfo.onReview`
    let onReview: Bool?
    /// 永久封禁（valid=0 时判定）；对齐 H5 `mineInfo.banAlways`
    let banAlways: Bool?
    /// 临时封禁时长（小时数）；对齐 H5 `mineInfo.bannedSubType`
    let bannedSubType: Int?
    /// 审核结果类型（type=2 通过 / type=9 代理 / 其他=拒绝或未审核）；对齐 H5 `mineInfo.type`
    /// 与 userType 语义相近但独立字段——H5 restricted 页用 type 判"审核通过 kill-app-restart"
    let type: Int?
    /// 网络登录结果的原始 JSON 是否精确包含审核占位视频。该值不含 URL，随会话持久化，
    /// 用于覆盖未知字段名或部分媒体元素解码失败的情况；旧版缓存缺少此字段时为 nil。
    let reviewPlaceholderVideoMatched: Bool?
    /// `true` 表示已经从登录/注册/同账号资料缓存获得明确媒体证据；`false` 表示登录响应
    /// 根本没有提供可判定的媒体字段。旧版缓存没有该字段时通过现有媒体内容兼容推导。
    let reviewModeResolved: Bool?
    /// 无媒体明细的最小模式缓存必须带版本，避免把旧构建曾错误写入的
    /// `resolved=true/placeholder=false` 当成可信的全功能证据。
    let reviewModeEvidenceVersion: Int?

    /// Memberwise init 保留供 test/preview 构造
    init(userId: Int?, token: String?, loginUuid: String?, yxAccid: String?, imToken: String?,
         userType: Int?, nickname: String?, icon: String?, userLevel: String? = nil,
         chatBubble: String? = nil, chatBubbleGuardianLevel: Int? = nil,
         valid: Int? = nil, onReview: Bool? = nil, banAlways: Bool? = nil,
         bannedSubType: Int? = nil, type: Int? = nil,
         picList: [LoginMediaItem]? = nil, videos: [String]? = nil,
         reviewPlaceholderVideoMatched: Bool? = nil,
         reviewModeResolved: Bool? = nil,
         reviewModeEvidenceVersion: Int? = nil) {
        self.userId = userId
        self.token = token
        self.loginUuid = loginUuid
        self.yxAccid = yxAccid
        self.imToken = imToken
        self.userType = userType
        self.nickname = nickname
        self.icon = icon
        self.picList = picList
        self.videos = videos
        self.userLevel = userLevel
        self.chatBubble = chatBubble
        self.chatBubbleGuardianLevel = chatBubbleGuardianLevel
        self.valid = valid
        self.onReview = onReview
        self.banAlways = banAlways
        self.bannedSubType = bannedSubType
        self.type = type
        self.reviewPlaceholderVideoMatched = reviewPlaceholderVideoMatched
        self.reviewModeResolved = reviewModeResolved
        self.reviewModeEvidenceVersion = reviewModeEvidenceVersion
    }

    /// 2026-07-17 tap-fix v4:手写 init(from:) 让 `userType` 与 `type` **互为兜底**——后端对未审核账号可能只
    /// 返其中一个 key。`RootView.isRestricted` 依赖 `userType != 2 && != 9`,任一 key 拿到值即可正确分流。
    ///
    /// 同款 flexible 兜底也扩到 audit 字段(valid/onReview/banAlways/bannedSubType) —— 用 `decodeFlexibleInt`
    /// 支持 String/Int 混发(对齐 `ios-decode-userid-compat.md` rule)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = c.decodeFlexibleInt(forKey: .userId)
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
        self.loginUuid = try c.decodeIfPresent(String.self, forKey: .loginUuid)
        self.yxAccid = try c.decodeIfPresent(String.self, forKey: .yxAccid)
        self.imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
        self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        if (try? c.decodeNil(forKey: .picList)) == true {
            self.picList = nil
        } else if let media = try? c.decode([LossyLoginMediaItem].self, forKey: .picList) {
            self.picList = media.compactMap(\.value)
        } else if let media = try? c.decode(LoginMediaItem.self, forKey: .picList) {
            self.picList = [media]
        } else {
            self.picList = nil
        }
        if (try? c.decodeNil(forKey: .videos)) == true {
            self.videos = nil
        } else if let media = try? c.decode([LossyLoginMediaItem].self, forKey: .videos) {
            self.videos = media.compactMap(\.value).compactMap(\.mediaUrl)
        } else if let media = try? c.decode(LoginMediaItem.self, forKey: .videos),
                  let url = media.mediaUrl {
            self.videos = [url]
        } else if let url = try? c.decode(String.self, forKey: .videos) {
            self.videos = [url]
        } else {
            self.videos = nil
        }
        self.userLevel = c.decodeFlexibleString(forKey: .userLevel)
        self.chatBubble = try c.decodeIfPresent(String.self, forKey: .chatBubble)
        self.chatBubbleGuardianLevel = c.decodeFlexibleInt(forKey: .chatBubbleGuardianLevel)

        // userType / type 双 key 互为兜底 —— 后端可能只返一个(H5 mineInfo 两者都用,H5 App.vue 用 userType 分流,
        // H5 mineRestricted 用 type 判 kill-app-restart)。iOS RootView.isRestricted 读 userType,统一 alias。
        let rawUserType = c.decodeFlexibleInt(forKey: .userType)
        let rawType = c.decodeFlexibleInt(forKey: .type)
        self.userType = rawUserType ?? rawType
        self.type = rawType ?? rawUserType

        // 审核态字段 flexible decode(Bool/0/1/String 兼容)
        self.valid = c.decodeFlexibleInt(forKey: .valid)
        self.onReview = c.decodeFlexibleBool(forKey: .onReview)
        self.banAlways = c.decodeFlexibleBool(forKey: .banAlways)
        self.bannedSubType = c.decodeFlexibleInt(forKey: .bannedSubType)
        if let networkEvidence = decoder.userInfo[.reviewPlaceholderVideoMatched]
            as? ReviewModeNetworkEvidence {
            self.reviewModeResolved = networkEvidence.isResolved
            self.reviewPlaceholderVideoMatched = networkEvidence.isResolved
                ? networkEvidence.placeholderMatched
                : nil
            self.reviewModeEvidenceVersion = networkEvidence.isResolved
                ? ReviewAccountModePolicy.currentEvidenceVersion
                : nil
        } else {
            self.reviewModeResolved = try c.decodeIfPresent(Bool.self, forKey: .reviewModeResolved)
            self.reviewPlaceholderVideoMatched = try c.decodeIfPresent(
                Bool.self,
                forKey: .reviewPlaceholderVideoMatched
            )
            self.reviewModeEvidenceVersion = c.decodeFlexibleInt(
                forKey: .reviewModeEvidenceVersion
            )
        }
    }

    /// 网络接口统一从这里解码，先检查解密后的原始 JSON，再进入 Codable。这样未知字段名或
    /// 单个异常媒体项不会让审核占位视频证据在解码阶段消失。
    static func decodeNetworkResponse(from data: Data, source: String) throws -> LoginResult {
        let evidence = LoginModeRawEvidence.inspect(data)
        let decoder = JSONDecoder()
        decoder.userInfo[.reviewPlaceholderVideoMatched] = ReviewModeNetworkEvidence(
            isResolved: evidence.profileMediaEvidenceResolved,
            placeholderMatched: evidence.profileMediaExactPlaceholderMatch
        )
        let result = try decoder.decode(LoginResult.self, from: data)

        #if DEBUG
        let effectiveType = ReviewAccountModePolicy.effectiveUserType(userInfo: result) ?? -1
        let reason = evidence.decisionReason(for: result)
        AppLogger.auth.info(
            "[PermissionModeInput] source=\(source, privacy: .public) root=\(evidence.rootShape, privacy: .public) keys=\(evidence.topLevelKeys, privacy: .public) picList=\(evidence.picListShape, privacy: .public) videos=\(evidence.videosShape, privacy: .public) latest=\(evidence.latestMediaShape, privacy: .public) urlStrings=\(evidence.urlStringCount, privacy: .public) mediaResolved=\(evidence.profileMediaEvidenceResolved, privacy: .public) profileExact=\(evidence.profileMediaExactPlaceholderMatch, privacy: .public) anywhereExact=\(evidence.anywhereExactPlaceholderMatch, privacy: .public) canonical=\(evidence.canonicalPlaceholderMatch, privacy: .public) filename=\(evidence.placeholderFilenameMatch, privacy: .public) malformed=\(evidence.mediaPayloadMalformed, privacy: .public) decodedPic=\(result.picList?.count ?? -1, privacy: .public) decodedVideos=\(result.videos?.count ?? -1, privacy: .public) reason=\(reason, privacy: .public) serverUserType=\(result.userType ?? -1, privacy: .public) effectiveUserType=\(effectiveType, privacy: .public)"
        )
        #endif
        return result
    }

    /// `nil` 与空数组语义不同：字段缺失/解码失败时不能证明账号不含占位视频；
    /// 明确返回空数组才表示服务端已提供资料媒体且当前没有视频。
    var hasPermissionVideoInfo: Bool {
        picList != nil || videos != nil
    }

    /// 旧缓存没有 `reviewModeResolved` 时，只信任明确的占位命中或实际媒体字段。
    /// 旧版本曾把“字段缺失”写成 `reviewPlaceholderVideoMatched=false`，该值不能用于放行。
    /// 即使旧缓存把 `reviewModeResolved` 错写成 `true`，只要没有媒体字段、没有明确的
    /// 占位命中且没有当前证据版本，仍按未解析处理。
    var isReviewModeResolved: Bool {
        if reviewPlaceholderVideoMatched == true { return true }
        if hasPermissionVideoInfo { return reviewModeResolved ?? true }
        return reviewModeResolved == true
            && (
                reviewModeEvidenceVersion == ReviewAccountModePolicy.currentEvidenceVersion
                    || reviewModeEvidenceVersion == ReviewAccountModePolicy.cachedModeEvidenceVersion
            )
    }

    var resolvedReviewPlaceholderMatch: Bool? {
        guard isReviewModeResolved else { return nil }
        return reviewPlaceholderVideoMatched == true
            || permissionModeMediaURLs.contains(where: ReviewAccountModePolicy.isPlaceholderVideoURL)
    }

    /// 用于审核模式判定的资料视频。来电视频不属于注册资料视频，不参与该条件。
    var permissionVideoURLs: [String] {
        let fromPicList = (picList ?? []).compactMap { item -> String? in
            guard item.mediaType == 2 || item.mediaType == nil else { return nil }
            guard let url = item.mediaUrl,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return url
        }
        let legacyURLs = (videos ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var seen = Set<String>()
        return (fromPicList + legacyURLs).filter { seen.insert($0).inserted }
    }

    /// 审核模式只关心占位 URL 是否出现在本人资料媒体中，不能依赖 `mediaType`。
    /// H5 注册回填会直接把 `picList` 最后一项当视频，说明旧数据的 mediaType 并不可靠。
    var permissionModeMediaURLs: [String] {
        let picListURLs = (picList ?? []).compactMap(\.mediaUrl)
        let legacyURLs = videos ?? []
        var seen = Set<String>()
        return (picListURLs + legacyURLs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 旧版 Keychain 会话可能没有媒体字段。仅在字段确实缺失时用同账号资料缓存迁移；
    /// 服务端明确返回空数组时，空值本身就是权威结果，不能再被旧缓存覆盖。
    func usingPermissionVideoURLsIfMissing(_ fallbackURLs: [String]) -> LoginResult {
        let normalizedFallback = fallbackURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !hasPermissionVideoInfo, !normalizedFallback.isEmpty else { return self }
        return resolvingPermissionVideoURLs(normalizedFallback)
    }

    /// `/api/anchor/userInfo` 已明确返回媒体字段后，用其视频证据完成先前未解析的模式。
    /// 空数组也是有效证据，表示当前账号不含审核占位视频。
    func resolvingPermissionVideoURLs(_ resolvedURLs: [String]) -> LoginResult {
        var seen = Set<String>()
        let normalizedURLs = resolvedURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let placeholderMatched = normalizedURLs.contains(
            where: ReviewAccountModePolicy.isPlaceholderVideoURL
        )
        return LoginResult(
            userId: userId,
            token: token,
            loginUuid: loginUuid,
            yxAccid: yxAccid,
            imToken: imToken,
            userType: userType,
            nickname: nickname,
            icon: icon,
            userLevel: userLevel,
            chatBubble: chatBubble,
            chatBubbleGuardianLevel: chatBubbleGuardianLevel,
            valid: valid,
            onReview: onReview,
            banAlways: banAlways,
            bannedSubType: bannedSubType,
            type: type,
            picList: picList,
            videos: normalizedURLs,
            reviewPlaceholderVideoMatched: placeholderMatched,
            reviewModeResolved: true,
            reviewModeEvidenceVersion: ReviewAccountModePolicy.currentEvidenceVersion
        )
    }

    /// 登录响应缺媒体时使用同一 userId、当前版本的持久化模式证据。
    func applyingCachedReviewPlaceholderMatch(_ placeholderMatched: Bool) -> LoginResult {
        return LoginResult(
            userId: userId,
            token: token,
            loginUuid: loginUuid,
            yxAccid: yxAccid,
            imToken: imToken,
            userType: userType,
            nickname: nickname,
            icon: icon,
            userLevel: userLevel,
            chatBubble: chatBubble,
            chatBubbleGuardianLevel: chatBubbleGuardianLevel,
            valid: valid,
            onReview: onReview,
            banAlways: banAlways,
            bannedSubType: bannedSubType,
            type: type,
            picList: picList,
            videos: videos,
            reviewPlaceholderVideoMatched: placeholderMatched,
            reviewModeResolved: true,
            reviewModeEvidenceVersion: ReviewAccountModePolicy.cachedModeEvidenceVersion
        )
    }

    /// 首次交互式登录没有媒体字段和同账号缓存时，用登录 token 预拉到的本人资料补齐模式。
    /// 这里只持久化“是否命中占位视频”的判定，不把资料接口的照片 URL 塞进登录模型的
    /// `videos`，避免权限证据被 Profile UI 误当成用户视频展示。
    func applyingFreshProfilePermissionEvidence(_ permissionVideoURLs: [String]) -> LoginResult {
        let placeholderMatched = permissionVideoURLs.contains(
            where: ReviewAccountModePolicy.isPlaceholderVideoURL
        )
        return LoginResult(
            userId: userId,
            token: token,
            loginUuid: loginUuid,
            yxAccid: yxAccid,
            imToken: imToken,
            userType: userType,
            nickname: nickname,
            icon: icon,
            userLevel: userLevel,
            chatBubble: chatBubble,
            chatBubbleGuardianLevel: chatBubbleGuardianLevel,
            valid: valid,
            onReview: onReview,
            banAlways: banAlways,
            bannedSubType: bannedSubType,
            type: type,
            picList: picList,
            videos: videos,
            reviewPlaceholderVideoMatched: placeholderMatched,
            reviewModeResolved: true,
            reviewModeEvidenceVersion: ReviewAccountModePolicy.currentEvidenceVersion
        )
    }

    /// 计算认证建立时的权限模式。登录/注册响应永远优先；响应缺少媒体时，跨会话
    /// 缓存按同一 userId 恢复 107 或全开放。两类缓存都缺失时先保持未解析（有效模式为
    /// 107）；交互式登录会在进入主界面前预拉本人资料，冷启动恢复则继续 fail-closed。
    func resolvingInitialPermissionMode(
        cachedPermissionVideoURLs: [String]?,
        cachedPlaceholderMatched: Bool?
    ) -> (user: LoginResult, source: String) {
        if resolvedReviewPlaceholderMatch != nil {
            return (
                self,
                hasPermissionVideoInfo ? "session-media" : "session-mode-cache"
            )
        }

        // 两份同账号缓存发生冲突时，明确包含审核占位视频的资料证据必须优先收紧。
        // 这可覆盖旧的 full-mode 布尔记录，避免资料缓存已证明是 107 时仍误开放一帧。
        if let cachedPermissionVideoURLs,
           cachedPermissionVideoURLs.contains(where: ReviewAccountModePolicy.isPlaceholderVideoURL) {
            return (
                applyingCachedReviewPlaceholderMatch(true),
                "profile-cache-review"
            )
        }

        if let cachedPlaceholderMatched {
            return (
                applyingCachedReviewPlaceholderMatch(cachedPlaceholderMatched),
                cachedPlaceholderMatched ? "mode-cache-review" : "mode-cache-full"
            )
        }

        if cachedPermissionVideoURLs != nil {
            return (
                applyingCachedReviewPlaceholderMatch(false),
                "profile-cache-full"
            )
        }

        return (self, "unresolved")
    }

    /// 注册/重录请求中的 videos 已被服务端接受，是本次会话权限模式的权威提交值。
    /// 响应可能仍回显提交前的占位视频，因此不能把旧视频或原始匹配证据并入新会话。
    func includingSubmittedPermissionVideoURLs(_ submittedURLs: [String]) -> LoginResult {
        let normalizedSubmitted = submittedURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedSubmitted.isEmpty else { return self }

        var seen = Set<String>()
        let authoritativeVideos = normalizedSubmitted.filter { seen.insert($0).inserted }
        let submittedPlaceholderMatched = authoritativeVideos.contains(
            where: ReviewAccountModePolicy.isPlaceholderVideoURL
        )
        // 有效邀请码提交真实视频时，接口偶尔仍回显旧占位视频。保留照片和其他资料，
        // 但移除与本次成功提交相冲突的旧占位项，避免它继续参与模式判定或首屏展示。
        let currentPicList = submittedPlaceholderMatched ? picList : picList?.filter { item in
            guard let url = item.mediaUrl else { return true }
            return !ReviewAccountModePolicy.isPlaceholderVideoURL(url)
        }
        return LoginResult(
            userId: userId,
            token: token,
            loginUuid: loginUuid,
            yxAccid: yxAccid,
            imToken: imToken,
            userType: userType,
            nickname: nickname,
            icon: icon,
            userLevel: userLevel,
            chatBubble: chatBubble,
            chatBubbleGuardianLevel: chatBubbleGuardianLevel,
            valid: valid,
            onReview: onReview,
            banAlways: banAlways,
            bannedSubType: bannedSubType,
            type: type,
            picList: currentPicList,
            videos: authoritativeVideos,
            reviewPlaceholderVideoMatched: submittedPlaceholderMatched,
            reviewModeResolved: true,
            reviewModeEvidenceVersion: ReviewAccountModePolicy.currentEvidenceVersion
        )
    }
}
