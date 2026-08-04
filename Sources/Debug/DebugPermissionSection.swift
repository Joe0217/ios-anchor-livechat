#if DEBUG
import SwiftUI
import UIKit
import os

private let debugCDNUploaderLogger = Logger(subsystem: "com.anchor.livechat", category: "cdn-upload")

/// DEBUG-only：Settings 页里的权限测试 section。真机 QA 期间快速切换 userType 观察三层 gate 效果。
///
/// **不入 Release 包**（整个文件 `#if DEBUG` 门）。
///
/// **UI 交互**：直接列 8 个 Button rows（对齐 SettingsView `settingsRow` pattern），点击 row 立即切换。
/// **不用 Picker.menu** —— iOS 16 List 里 Picker 默认 `.menu` style 只右侧 chevron 是 tap 区，
/// 左侧 label 文字点不动（SwiftUI 已知陷阱）。改 Button + `.contentShape(Rectangle())` 让整 row 都是热区
/// （对齐 rule swiftui-button-plain-hitarea）。
///
/// 数据源：
/// - `DebugPermissionOverride.shared`：本地注入通道（写入）
/// - `SessionStore.shared.user?.userType`：真实值（对照显示）
/// - `SelfPermissionBridge.shared`：派生权限（观察三层 gate 效果）
struct DebugPermissionSection: View {
    @State private var selection: Preset = .real
    /// SelfPermissionBridge 是单例；观察 @Published 让 canX 变化时 body 重算
    @ObservedObject private var permission = SelfPermissionBridge.shared
    /// SessionStore user 变化时（如切账号）重算 "Real" 显示值
    @ObservedObject private var session = SessionStore.shared

    var body: some View {
        Section("Debug · Permission (userType 注入)") {
            ForEach(Preset.allCases) { preset in
                Button {
                    apply(preset)
                } label: {
                    HStack {
                        Text(preset.label)
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                        Spacer()
                        if selection == preset {
                            Image(systemName: "checkmark")
                                .foregroundColor(.pink)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            infoRow(title: "Effective", value: effectiveText, mono: true)
            infoRow(title: "Call / Live / Party", value: permissionsText, mono: true)
            infoRow(title: "Gift / Wallet / WD / EX", value: economyPermissionsText, mono: true)
            infoRow(title: "Lot / Game / Item / Home / Work / H5", value: reviewPermissionsText, mono: true)
            infoRow(title: "Msg / Social / Notice / Party Video", value: isolationPermissionsText, mono: true)
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
        .onAppear { syncSelectionFromOverride() }
    }

    private func apply(_ preset: Preset) {
        selection = preset
        DebugPermissionOverride.shared.override = (preset == .real) ? nil : preset.rawValue
    }

    private func infoRow(title: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.white.opacity(0.8))
                .font(.system(size: 12))
            Spacer()
            Text(value)
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 12, design: mono ? .monospaced : .default))
        }
    }

    private var effectiveText: String {
        if let ov = DebugPermissionOverride.shared.override {
            return "\(ov) (override)"
        }
        let real = session.user?.userType.map(String.init) ?? "nil"
        return "\(real) (real)"
    }

    private var permissionsText: String {
        "\(mark(permission.canCall)) / \(mark(permission.canLive)) / \(mark(permission.canParty))"
    }

    private var economyPermissionsText: String {
        "\(mark(permission.canGiftSending)) / \(mark(permission.canWallet)) / \(mark(permission.canWithdrawal)) / \(mark(permission.canCurrencyExchange))"
    }

    private var reviewPermissionsText: String {
        "\(mark(permission.canLottery)) / \(mark(permission.canPartyGames)) / \(mark(permission.canPartyLuckyNumber)) / \(mark(permission.canPartyFreeGames)) / \(mark(permission.canVirtualItems)) / \(mark(permission.canHomeDiscovery)) / \(mark(permission.canWorkDashboard)) / \(mark(permission.canPartyActivities))"
    }

    private var isolationPermissionsText: String {
        "\(mark(permission.canDirectMessages)) / \(mark(permission.canProfileSocial)) / \(mark(permission.canSystemAnnouncements)) / \(mark(permission.canPartyVideo))"
    }

    private func mark(_ v: Bool) -> String { v ? "✓" : "✗" }

    /// 从 DebugPermissionOverride 反向同步 selection（进入 Settings 时保持一致）
    private func syncSelectionFromOverride() {
        if let ov = DebugPermissionOverride.shared.override,
           let preset = Preset(rawValue: ov) {
            selection = preset
        } else {
            selection = .real
        }
    }

    // MARK: - Preset

    private enum Preset: Int, CaseIterable, Identifiable, Hashable {
        case real = 0
        case v101 = 101
        case v102 = 102
        case v103 = 103
        case v104 = 104
        case v105 = 105
        case v106 = 106
        case v107 = 107

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .real: return "Real (SessionStore)"
            case .v101: return "101 · 屏通话+匹配"
            case .v102: return "102 · 屏直播"
            case .v103: return "103 · 屏 Party"
            case .v104: return "104 · 屏通话+匹配+直播"
            case .v105: return "105 · 屏通话+匹配+Party"
            case .v106: return "106 · 屏直播+Party"
            case .v107: return "107 · Party-only"
            }
        }
    }
}

/// DEBUG-only：通过现有 OSS 上传链路验证 CDN 目录和 MIME 配置。
/// 只上传少量代表性资源，凭证由登录态自动获取且不会落盘或写日志。
struct DebugCDNAssetUploadSection: View {
    @ObservedObject private var session = SessionStore.shared
    @StateObject private var uploader = DebugCDNAssetUploadStore()

    var body: some View {
        Section("Debug · CDN Asset Upload") {
            Button {
                uploader.start()
            } label: {
                HStack {
                    Image(systemName: uploader.isUploading ? "arrow.triangle.2.circlepath" : "arrow.up.circle")
                        .foregroundColor(.pink)
                        .frame(width: 22)
                    Text("Upload all CDN image assets")
                        .foregroundColor(.white)
                    Spacer()
                    if !session.isLoggedIn {
                        Text("Login required")
                            .foregroundColor(.white.opacity(0.45))
                            .font(.system(size: 12))
                    } else if !uploader.isUploading {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.isLoggedIn || uploader.isUploading)

            Button {
                uploader.uploadPreviouslyFailedAssets()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.orange)
                        .frame(width: 22)
                    Text("Upload remaining 6 failed assets")
                        .foregroundColor(.white)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.isLoggedIn || uploader.isUploading)

            if uploader.isUploading {
                HStack {
                    ProgressView()
                        .tint(.pink)
                    Text(uploader.statusText)
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 12))
                    Spacer()
                    Button("Cancel") {
                        uploader.cancel()
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
                }
            } else if !uploader.statusText.isEmpty {
                Text(uploader.statusText)
                    .foregroundColor(uploader.didFail ? .red.opacity(0.9) : .white.opacity(0.65))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }

            ForEach(uploader.uploadedURLs, id: \.self) { url in
                Text(url)
                    .foregroundColor(.green.opacity(0.85))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }
}

@MainActor
private final class DebugCDNAssetUploadStore: ObservableObject {
    @Published private(set) var statusText = ""
    @Published private(set) var uploadedURLs: [String] = []
    @Published private(set) var isUploading = false
    @Published private(set) var didFail = false
    @Published private(set) var succeededCount = 0
    @Published private(set) var failedCount = 0

    private var task: Task<Void, Never>?
    private var failedSamples: [DebugCDNAssetSample] = []

    func start() {
        begin(samples: DebugCDNAssetSample.all)
    }

    func retryFailed() {
        guard !failedSamples.isEmpty else { return }
        begin(samples: failedSamples)
    }

    func uploadPreviouslyFailedAssets() {
        begin(samples: DebugCDNAssetSample.remainingFailed)
    }

    private func begin(samples: [DebugCDNAssetSample]) {
        guard task == nil else { return }
        isUploading = true
        didFail = false
        succeededCount = 0
        failedCount = 0
        failedSamples = []
        statusText = "Requesting upload permission..."
        uploadedURLs = []

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await OssCredentialService.shared.getOssUploadParam()
                let batchSize = 4
                var completed = 0
                while completed < samples.count {
                    try Task.checkCancellation()
                    let end = min(completed + batchSize, samples.count)
                    let batch = Array(samples[completed..<end])
                    let outcomes = await withTaskGroup(of: UploadOutcome.self, returning: [UploadOutcome].self) { group in
                        for (offset, sample) in batch.enumerated() {
                            group.addTask {
                                do {
                                    let data = try await sample.loadData()
                                    let url = try await OssUploadService.shared.uploadPublicFile(
                                        fileData: data,
                                        credential: credential,
                                        objectKey: sample.objectKey,
                                        contentType: sample.contentType
                                    )
                                    return .success(index: completed + offset, url: url)
                                } catch {
                                    return .failure(index: completed + offset, message: Self.safeMessage(for: error))
                                }
                            }
                        }
                        var collected: [UploadOutcome] = []
                        for await outcome in group { collected.append(outcome) }
                        return collected.sorted { $0.index < $1.index }
                    }
                    for outcome in outcomes {
                        switch outcome {
                        case .success(_, let url):
                            succeededCount += 1
                            uploadedURLs.append(url)
                            if uploadedURLs.count > 20 { uploadedURLs.removeFirst() }
                        case .failure(let index, let message):
                            failedCount += 1
                            didFail = true
                            failedSamples.append(samples[index])
                            debugCDNUploaderLogger.error("asset upload failed path=\(samples[index].relativePath, privacy: .public) error=\(message, privacy: .public)")
                            statusText = "Last failure: \(message)"
                        }
                    }
                    completed = end
                    statusText = "Uploading \(completed)/\(samples.count) (failed \(failedCount))"
                }
                statusText = "Upload complete: \(succeededCount)/\(samples.count) (failed \(failedCount))"
            } catch {
                if Task.isCancelled {
                    statusText = "Upload cancelled"
                } else {
                    didFail = true
                    statusText = "Upload failed: \(Self.safeMessage(for: error))"
                }
            }
            isUploading = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private enum UploadOutcome {
        case success(index: Int, url: String)
        case failure(index: Int, message: String)

        var index: Int {
            switch self {
            case .success(let index, _), .failure(let index, _): return index
            }
        }
    }

    private nonisolated static func safeMessage(for error: Error) -> String {
        switch error {
        case let error as OssUploadError:
            switch error {
            case .http(let statusCode, _): return "HTTP \(statusCode)"
            case .network: return "network error"
            case .invalidRequest: return "invalid upload request"
            }
        case let error as APIError:
            return error.message
        default:
            return error.localizedDescription
        }
    }
}

private struct DebugCDNAssetSample {
    enum Source {
        case assetCatalog(name: String)
        case bundle(name: String, ext: String, subdirectory: String?)
    }

    let relativePath: String
    let contentType: String
    let source: Source

    var objectKey: String {
        "iosAnchor/assets/v\(Self.version)/\(relativePath)"
    }

    func loadData() async throws -> Data {
        switch source {
        case .assetCatalog(let name):
            return try await MainActor.run {
                if let image = UIImage(named: name) {
                    if let data = image.pngData() { return data }
                    let format = UIGraphicsImageRendererFormat.default()
                    format.scale = image.scale
                    return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
                        image.draw(in: CGRect(origin: .zero, size: image.size))
                    }
                }
                guard let size = Self.webPAssetPixelSizes[name] else {
                    throw DebugCDNAssetError.resourceUnavailable(name)
                }
                let renderer = ImageRenderer(
                    content: Image(name)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                )
                renderer.scale = 1
                guard let cgImage = renderer.cgImage,
                      let data = UIImage(cgImage: cgImage).pngData() else {
                    throw DebugCDNAssetError.resourceUnavailable(name)
                }
                return data
            }
        case .bundle(let name, let ext, let subdirectory):
            let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
                ?? Bundle.main.url(forResource: name, withExtension: ext)
            guard let url else { throw DebugCDNAssetError.resourceUnavailable("\(name).\(ext)") }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }

    static let all: [DebugCDNAssetSample] = assetCatalogNames.map(assetCatalogSample) + [
        DebugCDNAssetSample(relativePath: "gif/diamond-yellow.gif", contentType: "image/gif", source: .bundle(name: "diamond-yellow", ext: "gif", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "gif/party-list-animation.gif", contentType: "image/gif", source: .bundle(name: "party-list-animation", ext: "gif", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "gif/pk-progress-draw.webp", contentType: "image/webp", source: .bundle(name: "pk-progress-draw", ext: "webp", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "gif/pk-progress-loss.webp", contentType: "image/webp", source: .bundle(name: "pk-progress-loss", ext: "webp", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "gif/pk-progress-win.webp", contentType: "image/webp", source: .bundle(name: "pk-progress-win", ext: "webp", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "gif/roomlist-top3-box-new.webp", contentType: "image/webp", source: .bundle(name: "roomlist-top3-box-new", ext: "webp", subdirectory: "GIFs")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-countdown-5s.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-countdown-5s", ext: "svga", subdirectory: "SVGA/pk")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-matching-15s.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-matching-15s", ext: "svga", subdirectory: "SVGA/pk")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-preparing-countdown.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-preparing-countdown", ext: "svga", subdirectory: "SVGA/pk")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-result-draw.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-result-draw", ext: "svga", subdirectory: "SVGA/pk")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-result-loss.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-result-loss", ext: "svga", subdirectory: "SVGA/pk")),
        DebugCDNAssetSample(relativePath: "svga/pk/pk-result-win.svga", contentType: "application/octet-stream", source: .bundle(name: "pk-result-win", ext: "svga", subdirectory: "SVGA/pk")),
    ]

    static let remainingFailed: [DebugCDNAssetSample] = [
        "blackTriangle", "lightning", "moneyBag", "upArrow", "yellowDiamond", "yellowRoundArrow",
    ].map(assetCatalogSample)

    private static func assetCatalogSample(_ name: String) -> DebugCDNAssetSample {
        let catalogName = beautyThumbnailNames.contains(name) ? "BeautyFilterThumbnails/\(name)" : name
        let module = category(for: name)
        return DebugCDNAssetSample(
            relativePath: module == "common" ? "common/\(name).png" : "common/\(module)/\(name).png",
            contentType: "image/png",
            source: .assetCatalog(name: catalogName)
        )
    }

    private static func category(for name: String) -> String {
        if beautyThumbnailNames.contains(name) { return "beauty" }
        let lower = name.lowercased()
        let prefixes: [(String, String)] = [
            ("auth", "auth"), ("call", "call"), ("chat", "chat"), ("guardian", "guardian"),
            ("home", "home"), ("invite", "invite"), ("live", "live"), ("match", "match"),
            ("message", "message"), ("mob", "beauty"), ("party", "party"), ("pk", "pk"),
            ("profile", "profile"), ("roulette", "roulette"), ("stat", "stats"), ("tab", "tabs"),
            ("task", "task"), ("tool", "tools"), ("wish", "wishlist"),
        ]
        return prefixes.first(where: { lower.hasPrefix($0.0) })?.1 ?? "common"
    }

    private static let beautyThumbnailNames: Set<String> = [
        "bailiang1", "fennen1", "gexing1", "heibai1", "lengsediao1", "mitao1",
        "nuansediao1", "origin", "xiaoqingxin1", "zhiganhui1", "ziran1",
    ]

    private static let webPAssetPixelSizes: [String: CGSize] = [
        "blackTriangle": CGSize(width: 36, height: 20),
        "lightning": CGSize(width: 32, height: 32),
        "moneyBag": CGSize(width: 114, height: 100),
        "upArrow": CGSize(width: 16, height: 16),
        "yellowDiamond": CGSize(width: 40, height: 40),
        "yellowRoundArrow": CGSize(width: 32, height: 32),
    ]

    private static let assetCatalogNames: [String] = """
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

    private static var version: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }
}

private enum DebugCDNAssetError: LocalizedError {
    case resourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .resourceUnavailable(let name): return "resource unavailable: \(name)"
        }
    }
}
#endif
