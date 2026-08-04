import SwiftUI

/// SwiftUI `AsyncImage` 替代品：内存 + 磁盘缓存命中后立即同步显示，无闪烁。
///
/// 命中策略：
/// - body 渲染时先同步查 `ImageCache.shared.cached(url)` 立即赋初值
///   → 内存里有图就**首次渲染就是最终图**，看不到 placeholder 闪烁
/// - .task(id: url) 兜底：URL 变化或首次拉取走网络
///
/// 用法（与 AsyncImage 类似）：
/// ```
/// CachedAsyncImage(url: vm.iconURL, contentMode: .fill) {
///     Color.gray.opacity(0.3)  // placeholder
/// }
/// ```
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// 是否写入持久缓存（NSCache + URLCache）。
    /// `true`（默认）：本人头像 / 相册 / 视频封面 / 礼物图等需要跨 view 持久的资源
    /// `false`：他人头像等不需要持久化的临时资源 —— view dismount 后即丢
    var persistent: Bool = true
    var templateRenderingMode: Image.TemplateRenderingMode?
    let placeholder: () -> Placeholder
    /// 礼物图等不含账号私密内容的公共资源，使用独立文件缓存，登出后继续复用。
    private let usesPublicAssetCache: Bool

    @State private var image: UIImage?
    @State private var lastLoadedURL: URL?

    init(url: URL?,
         contentMode: ContentMode = .fill,
         persistent: Bool = true,
         cdn: (size: CDNImageSize, mode: CDNImageMode)? = nil,
         renderingMode: Image.TemplateRenderingMode? = nil,
         /// `true` 用于可跨账号复用的运营图；账号头像、相册等保持默认 `false`。
         publicAsset: Bool = false,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        // 若指定了 CDN 参数则拼装缩放 URL；缓存 key 也用改造后的 URL，按分档独立缓存
        // 同时强制 http/https scheme 白名单：URLSession 会响应 file:// / data:// 等,
        // 后端污染 URL(string: "file:///...") 可读 sandbox 文件并写入 URLCache 磁盘层
        let finalURL = url.flatMap { u -> URL? in
            guard let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            guard let cdn else { return u }
            return u.cdnScaled(cdn.size, mode: cdn.mode)
        }
        self.url = finalURL
        self.contentMode = contentMode
        self.persistent = persistent
        self.templateRenderingMode = renderingMode
        self.placeholder = placeholder
        if let cdn, case .gift = cdn.size {
            usesPublicAssetCache = true
        } else {
            usesPublicAssetCache = publicAsset
        }
        // 同步预填：无论 persistent 都查 NSCache（读不写）。这样 persistent=false 的
        // 调用方（如他人头像）若 URL 恰好等于本人头像（已被 persistent=true 写入缓存），
        // 仍能复用而非重拉。
        if let finalURL, let cached = ImageCache.shared.cached(for: finalURL) {
            _image = State(initialValue: cached)
            _lastLoadedURL = State(initialValue: finalURL)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: rendered(image))
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func rendered(_ image: UIImage) -> UIImage {
        guard let templateRenderingMode else { return image }
        let mode: UIImage.RenderingMode = templateRenderingMode == .template ? .alwaysTemplate : .alwaysOriginal
        return image.withRenderingMode(mode)
    }

    private func load() async {
        guard let url else {
            image = nil
            lastLoadedURL = nil
            return
        }
        if url == lastLoadedURL, image != nil { return }
        // 无论 persistent，先查内存（命中即用，复用他人传 false 时本人头像缓存）
        if let cached = ImageCache.shared.cached(for: url) {
            image = cached
            lastLoadedURL = url
            return
        }
        // 未命中走网络：persistent 决定是否写入 NSCache + URLCache
        let fetched: UIImage?
        if usesPublicAssetCache {
            fetched = await ImageCache.shared.fetchPublicAsset(url)
        } else if persistent {
            fetched = await ImageCache.shared.fetch(url)
        } else {
            fetched = await ImageCache.shared.fetchEphemeral(url)
        }
        if self.url == url {
            image = fetched
            lastLoadedURL = url
        }
    }
}

/// CDN-only wrapper for public application assets.
///
/// These files are deliberately absent from the app bundle. A successful CDN
/// response is persisted in the shared public disk cache; a failed response
/// leaves the view empty instead of silently restoring a bundled copy.
struct CDNAssetImage: View {
    let name: String
    var contentMode: ContentMode = .fit
    private var templateRenderingMode: Image.TemplateRenderingMode?

    init(_ name: String, contentMode: ContentMode = .fit) {
        self.name = name
        self.contentMode = contentMode
    }

    var body: some View {
        CachedAsyncImage(
            url: CDNAssetURL.url(for: name),
            contentMode: contentMode,
            renderingMode: templateRenderingMode,
            publicAsset: true
        ) { Color.clear }
    }

    /// Compatibility no-op: the wrapper is already resizable internally.
    /// Returning the concrete type keeps existing modifier chains compiling.
    func resizable() -> CDNAssetImage { self }

    func scaledToFit() -> some View {
        aspectRatio(contentMode: .fit)
    }

    func scaledToFill() -> some View {
        aspectRatio(contentMode: .fill)
    }

    func renderingMode(_ mode: Image.TemplateRenderingMode) -> CDNAssetImage {
        var copy = self
        copy.templateRenderingMode = mode
        return copy
    }

}

enum CDNAssetURL {
    private static let baseURL = "https://file.lovetravel.link/iosAnchor/assets/v20260804"
    private static let beautyNames: Set<String> = [
        "bailiang1", "fennen1", "gexing1", "heibai1", "lengsediao1", "mitao1",
        "nuansediao1", "origin", "xiaoqingxin1", "zhiganhui1", "ziran1",
    ]

    static func url(for name: String) -> URL? {
        let resourceName = normalizedName(name)
        let module = module(for: resourceName)
        let path = module == "common"
            ? "common/\(resourceName).png"
            : "common/\(module)/\(resourceName).png"
        return URL(string: "\(baseURL)/\(path)")
    }

    /// GIF / WebP 使用上传时保留的原始文件名，和静态图片目录分开。
    static func animatedURL(name: String, fileExtension: String) -> URL? {
        guard !name.isEmpty, !fileExtension.isEmpty else { return nil }
        return URL(string: "\(baseURL)/gif/\(name).\(fileExtension)")
    }

    /// 当前 App 内置的 SVGA 都位于 PK 子目录；保留参数以便后续新增模块资源。
    static func svgaURL(resource: String, subdirectory: String = "pk") -> URL? {
        guard !resource.isEmpty else { return nil }
        return URL(string: "\(baseURL)/svga/\(subdirectory)/\(resource).svga")
    }

    static var publicAssetURLs: [URL] {
        bundledImageNames.compactMap(url(for:))
            + bundledAnimationResources.compactMap { animatedURL(name: $0.name, fileExtension: $0.extension) }
            + bundledSVGAResources.compactMap { svgaURL(resource: $0) }
    }

    private static func normalizedName(_ name: String) -> String {
        let prefix = "BeautyFilterThumbnails/"
        guard name.hasPrefix(prefix) else { return name }
        return String(name.dropFirst(prefix.count))
    }

    private static func module(for name: String) -> String {
        if beautyNames.contains(name) { return "beauty" }
        let lower = name.lowercased()
        let prefixes: [(String, String)] = [
            ("auth", "auth"), ("call", "call"), ("chat", "chat"), ("guardian", "guardian"),
            ("home", "home"), ("invite", "invite"), ("live", "live"), ("match", "match"),
            ("message", "message"), ("beauty", "beauty"), ("mob", "beauty"), ("party", "party"), ("pk", "pk"),
            ("profile", "profile"), ("roulette", "roulette"), ("stat", "stats"), ("tab", "tabs"),
            ("task", "task"), ("tool", "tools"), ("wish", "wishlist"),
        ]
        return prefixes.first(where: { lower.hasPrefix($0.0) })?.1 ?? "common"
    }

    private static let bundledAnimationResources: [(name: String, extension: String)] = [
        ("diamond-yellow", "gif"), ("party-list-animation", "gif"),
        ("pk-progress-draw", "webp"), ("pk-progress-loss", "webp"),
        ("pk-progress-win", "webp"), ("roomlist-top3-box-new", "webp"),
    ]

    private static let bundledSVGAResources = [
        "pk-countdown-5s", "pk-matching-15s", "pk-preparing-countdown",
        "pk-result-draw", "pk-result-loss", "pk-result-win",
    ]

    private static let bundledImageNames: [String] = """
CallAnchorBadgeSS
CallBtnChat
CallBtnGift
CallBtnMore
CallGiftIncomeIcon
CallHangupCircle
CallIncomeIcon
CallPillIconGift
CallPillIconPhone
CallPipShadow
CallSignalBars
ChatBottomPhoto
ChatBottomPrivate
ChatBottomVideo
ChatBottomVoice
EmptyStatePlaceholder
MobDayan
MobDuanlian
MobEt
MobHongrun
MobLy
MobMeibai
MobMeiya
MobMopi
MobQflw
MobQhyq
MobQingxi
MobRuihua
MobSb
MobShoueg
MobShouxeg
MobVlian
MobWglt
MobXb
MobXiaolian
MobYuanyan
MobZhailian
RewardBoxCoin
RewardRecord
authEyeClosed
authEyeOpen
authLoginBackground
authLoginTitle
authLogoHily
bailiang1
blackTriangle
callsToday
coins
defaultAvatar
defaultUserAvatar
diamondGiftDiamond
diamondGiftFloatBackground
diamondGiftMvp
diamondGiftPendant
diamondGiftPurpleDiamond
diamondGiftScreenIcon
diamondYellow
diamonds
fennen1
gems
gexing1
giftPanelBalanceCoin
guardianDiamond
guardianEmpty
guardianGiftPreviewBronze
guardianGiftPreviewGold
guardianGiftPreviewSilver
guardianPrivilegeBadge
guardianPrivilegeBroadcastBronze
guardianPrivilegeBroadcastGold
guardianPrivilegeBroadcastSilver
guardianPrivilegeChat
guardianPrivilegeFrame
guardianPrivilegeGift
guardianPrivilegeGiftBronze
guardianPrivilegeGiftGold
guardianPrivilegeGiftSilver
guardianPrivilegeHighlight
guardianPrivilegeMount
guardianPrivilegeNotice
guardianPrivilegeNoticeBronze
guardianPrivilegeNoticeGold
guardianPrivilegeNoticeSilver
guardianRulesDecoration
guardianRulesPrivileges
guardianShield
guardianTabBronze
guardianTabGold
guardianTabSelected
guardianTabSilver
guardianTabUnselected
guardianTopFrameBronze
guardianTopFrameGold
guardianTopFrameSilver
guardianTopGlow
heibai1
homeCpAvatarFrame
homeCpBackground
homeCpCardBottomOrnament
homeCpCardTopOrnament
homeCpDayActive
homeCpDayDefault
homeCpDefaultUser
homeCpHeartDivider
homeCpHeartGlow
homeCpListItem
homeCpNameDivider
homeCpRewardBottom
homeCpRewardCenter
homeCpRewardDot
homeCpRewardHost
homeCpRewardTop
homeCpRewardUser
homeCpRoseLarge
homeCpRoseSmall
homeCpSelfRank
homeCpTop1Badge
homeCpTop1FrameBlue
homeCpTop1FramePink
homeCpTop2Badge
homeCpTop3Badge
homeCpTopCard
homeCpWeekActive
homeCpWeekDefault
homeCpWingLeft
homeCpWingRight
homeCpWreathBlue
homeCpWreathPink
homeFloatGoLive
homePointsBackground
homePointsPodium
homePointsTop1
homePointsTop2
homePointsTop3
homeRankCharmBackground
homeRankDiamondPurple
homeRankIntegral
homeRankRewardDiamond
homeRankTop1
homeRankTop2
homeRankTop3
homeRankWealthBackground
ic_backpack
inviteAnchorBackground
inviteAnchorRewardBackground
inviteDashboardBackground
inviteDashboardTableBackground
inviteIncomeBackground
inviteLast7Days
inviteMetricAverage
inviteMetricCall
inviteMetricGift
inviteMetricLevel
inviteMetricOnline
inviteMetricRank
inviteMetricRate
inviteMetricReward
inviteMetricTotal
inviteNavBackground
inviteStepHost
inviteStepUser
inviteUserBackground
inviteUserRewardBackground
lengsediao1
lightning
liveBackground
liveBadge
liveDiamondGift
liveListBackground
liveListChat
liveListLevelIcon
liveListLiveAction
liveListLocation
liveListMatch
liveListOfflineToggle
liveListVideoCall
liveListVipBadge
liveMarqueeDiamond
livePkIcon
liveRankBadge
liveRefresh
liveResultBack
liveResultCallUnfollow
liveResultDiamond
liveResultMessage
liveResultUnfollow
liveRoomAnchorAvatar
liveRoomChatLevelIcon10
liveRoomCloseButton
liveRoomDiamondBadge
liveRoomHotIcon
liveRoomPKIcon
liveRoomPrivateCallButton
liveRoomRankIcon
liveRoomRouletteMsgIcon
liveRoomSendButton
liveRoomTaskBadge
liveRoomToolGiftBadge
liveRoomToolMessageBadge
liveRoomToolSettingBadge
liveRoomTopViewer1
liveRoomTopViewer2
liveRoomViewerCountIcon
liveRoomWishlistCoin
liveRoomWishlistGift
liveSignal
liveTabIndicator
liveUserTycoonEntrance
liveViewerCount
luckyGiftNoticeBadge
luckyGiftNoticeDiamond
matchBackgroundHigh
matchButtonOff
matchButtonOn
matchHeroVisual
matchIconRanking
matchIconRefresh
matchIconSignal
matchMarqueeCallIcon
matchTabSelectedIndicator
messageBadgeCpTask
messageBadgeMassTexting
messageInboxAdmin
messageInboxNotification
messageInboxStation
messageListBackground
messageNavClear
messageNavHistory
messageReadCheckmarkGray
messageReadCheckmarkGreen
mitao1
moneyBag
nuansediao1
origin
partyArrowYellow
partyBadgeBubble
partyCreatePlus
partyFollowCheck
partyFollowUnchecked
partyGems
partyHotTaskChest
partyIconAnnouncement
partyIconEmoji
partyIconFire
partyIconGame
partyIconGift
partyIconLevel
partyIconManagement
partyIconMicMuted
partyIconMicOn
partyIconMore
partyIconShare
partyIconSpeaker
partyIconViewer
partyListEmpty
partyLobbyRoomBackground
partyLuckyNumberIcon
partyLuckyNumberWinning
partyManagerBadge
partyOwnerCrown
partyPkBattleMarker
partyPkBlueSeatAdd
partyPkBlueSofa
partyPkCenterLogo
partyPkGem
partyPkGiftTabBlue
partyPkGiftTabRed
partyPkLogo
partyPkProgressOverlay
partyPkRedSeatAdd
partyPkRedSofa
partyPkRule
partyPkSettlementHero
partyPkStartButton
partyPkWaitingBackground
partyRoomBg
partyRoomCover
partyRoomTop1Background
partyRoomTop2Background
partyRoomTop3Background
partySeatEmpty
partySeatRing
partyTemplate10Mic
partyTemplate15Mic
partyTemplate1Video
partyTemplate20Mic
partyTemplate2Video
partyTemplate3Video
partyTemplate5Mic
partyTemplate6Mic
partyTemplateSelected
partyTrophy
partyUserCardAdminAdd
partyUserCardAdminRemove
partyUserCardCopy
partyUserCardFollow
partyUserCardKickMic
partyUserCardKickOut
partyUserCardMute
partyUserCardSendGift
partyUserCardTakeMic
partyUserCardUnmute
partyVideoSeatEmpty
pinkClock
pkBattleBadgeLeft
pkBattleBadgeRight
pkBattleHandshake
pkBattleMVP
pkBattleMuteIcon
pkBattleProgressDecor
pkBattleRank2
pkBattleRank3
pkBattleTop1Crown
pkBattleVolumeCircle
profileAgeIcon
profileChevronRight
profileEditIcon
profileGenderIcon
profileLocationIcon
profileSettingsIcon
profileTopBg
profileVideoPlay
restrictedNewsHeader
rouletteClose
rouletteIntroBackground
rouletteIntroGame
rouletteIntroRps
rouletteIntroWheel
rouletteOpen
statAvgCallDuration
statCalls
statOnlineTime
statRating
statRevenue
tabHome
tabHomeActive
tabMessages
tabMessagesActive
tabParty
tabPartyActive
tabProfile
tabProfileActive
tabWork
tabWorkActive
taskExpandChevron
taskModuleIconLive
taskModuleIconPoints
taskModuleIconTycoon
taskRankCardBg
taskRankMedal
taskRankTrophy
taskTierDotClaimable
taskTierDotCurrent
taskTierDotLocked
taskTopBg
toolBackpack
toolBeauty
toolBigR
toolGiftMessage
toolGoLive
toolInvite
toolLiveData
toolMatch
toolMyGuardian
toolNewbie
toolPartyData
toolPoints
toolProfileUpdate
toolTask
toolWorkingGuide
toolsMatchGrey
upArrow
wishTemplateCommon
wishTemplateNoText
wishTemplatePrivate
xiaoqingxin1
yellowDiamond
yellowRoundArrow
zhiganhui1
ziran1
""".split(separator: "\n").map(String.init)
}
