import SwiftUI

/// PK Arena 布局常量（LiveRoomView 需要读取以对 CameraPreview 定尺寸，故 public）。
///
/// 对齐 H5 [pkBattleView.vue:633](../../../.././anchor-livechat-h5/src/views/liveSetting/components/pkLive/pkBattleView.vue) `h-374 w-full` —— PK 视频区**固定高度**，不是全屏。
enum PKArenaLayout {
    /// 视频区顶部起始 y（让开 LiveRoomHeroTopArea：safe area top + 主播胶囊 + 徽章 row ≈ 130pt）。
    /// 2026-07-07 v2：从 200 下调 140 —— 用户反馈"视频容器应与 progressBar 同一水平线"，
    /// progressBar 移到 videoContainer 顶部作 overlay，视频从更靠上位置开始
    static let topOffset: CGFloat = 144
    /// 视频区高度（对齐 H5 h-374；iOS pt 约 300）
    static let videoHeight: CGFloat = 300
}

/// G 里程碑 spec §6 / M3-5：PK 对战 overlay（分屏右半对手 canvas + 顶部/底部装饰）。
///
/// **架构分工**（2026-07-06 用户反馈"视频画面截小"根因修正）：
/// - **LiveRoomView** 负责 CameraPreview 尺寸控制（PK 中缩到左半 videoHeight）+ 底层背景色
/// - **PKArenaView** 只叠加：右半对手 canvas + progressBar + countdown + Top3 + 静音/nickname + 结果动画
/// - 不再在本 view 内做"上下黑遮罩"—— 底色由 LiveRoomView 底层 `Theme.Palette.liveBottomDark` 承担
///
/// 【铁律 §3】本端 CameraPreview 由 LiveRoomView 渲染；【铁律 §1】外层 if 链 + `.id("pkArena")` 锁 identity。
struct PKArenaView: View {
    @ObservedObject var store: PKStore
    let agora: AgoraManager

    @State private var isOpponentMuted: Bool = false
    /// PK 贡献榜 sheet 呈现 side（对齐 H5 pkBattleViewTop3Contributors.vue @click showMyRankList/showOpponentRankList）
    @State private var rankSheetSide: PKRankSide?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // 2026-07-07 v4：对手视频容器已迁到 LiveRoomView 与本端 CameraPreview 同一 HStack
                // （追证据链头：两 sibling GeometryReader 无法保证坐标系严格一致→架构级根治齐平问题）
                // 本 view 只保留 6 个 overlay 装饰：progressBar / countdown / 静音按钮 / nickname 胶囊 / Top3 / 结果动画

                // 1) 静音按钮独立 overlay（贴对方视频右上，对齐 H5 inset-ie-12 top-32）
                opponentMuteButton
                    .padding(.trailing, 12)
                    .padding(.top, PKArenaLayout.topOffset + 32)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)

                // 2) progressBar 与视频顶齐平 + countdown 紧贴 bar 底沿（对齐 H5 pkBattleView.vue L395-417
                //    `absolute top-0` overlay + `absolute top-20` countdown 语义）
                //    2026-07-07 v3：padding.top: topOffset - 20 → topOffset（progressBar container 顶 = video 顶 y）;
                //    PKBattleProgressBar 外框由 handshakeSize(28) 改回 barHeight(20)，handshake 用 position 悬出
                //    上下 4pt overflow 不占布局空间 → Countdown 紧贴 bar 底沿真无 gap
                VStack(spacing: 0) {
                    PKBattleProgressBar(myPkValue: store.scores?.pkCounter ?? 0,
                                        opponentPkValue: store.scores?.oppositePkCounter ?? 0)
                        .padding(.horizontal, 16)
                    if store.state == .inPK {
                        PKBattleCountdown(remainingSeconds: store.pkRemainingSeconds,
                                          isPunishment: false)
                    } else if store.state == .punishing {
                        PKBattleCountdown(remainingSeconds: store.punishRemainingSeconds,
                                          isPunishment: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, PKArenaLayout.topOffset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // 3) 对手 nickname 胶囊（贴对手视频右下外侧，H5 `absolute inset-ie-0 bottom-8`）
                if let nickname = store.ctx?.oppositeNickname, !nickname.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        opponentNicknameChip(nickname: nickname)
                            // trailing padding = 0，胶囊右缘贴屏幕右边（对齐 H5 `inset-ie-0`）
                    }
                    // 胶囊 24pt 高 + 距视频底 8pt = 顶偏 32pt
                    .padding(.top, PKArenaLayout.topOffset + PKArenaLayout.videoHeight - 32)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }

                // 4) 视频区正下方 Top3 贡献榜（2026-07-10 起两侧整块 tap 拉起对应贡献榜 sheet）
                VStack(spacing: 0) {
                    Spacer().frame(height: PKArenaLayout.topOffset + PKArenaLayout.videoHeight + 4)
                    PKBattleTop3Contributors(myTop3: store.scores?.top3Users ?? [],
                                             opponentTop3: store.scores?.oppositeTop3Users ?? [],
                                             onTapSide: handleRankSideTap)
                        .frame(height: 32)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // 5) 惩罚开始 WIN/LOSE/DRAW 弹跳动画（居中于视频区）
                VStack {
                    Spacer().frame(height: PKArenaLayout.topOffset + (PKArenaLayout.videoHeight - 105) / 2)
                    PKBattleResultAnimation(store: store)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        // 2026-07-07 v3 修 Q4 对方视频与本端未齐平根因：
        // 原 `.ignoresSafeArea(.keyboard)` 仅忽略键盘 safe area，导致 GeometryReader.size 减去 top safe area (~47pt)，
        // 而 LiveRoomView 的 GeometryReader 用外层 `.ignoresSafeArea()` 全忽略 → 两 view 基准差 47pt → 对方视频比本端低 47pt
        // 改为无参数 `.ignoresSafeArea()` 让 PKArenaView 内部 GeometryReader 与 LiveRoomView 走完全相同尺寸基准
        .ignoresSafeArea()
        // PK 贡献榜 sheet（对齐 H5 pkRankListPopup.vue h-559 固定半屏）
        .sheet(item: $rankSheetSide) { side in
            pkRankSheet(side: side)
                .presentationDetents([.fraction(0.5)])
        }
    }

    // MARK: - PK 贡献榜 sheet 接线

    /// Top3 一侧被点击（H5 showMyRankList / showOpponentRankList）。
    /// ctx.pkId 缺失时（starting/matching 边界瞬时态）忽略 tap 兜底避免拉空接口。
    @MainActor
    private func handleRankSideTap(_ side: PKRankSide) {
        guard store.ctx?.pkId != nil else { return }
        rankSheetSide = side
    }

    /// side → 主播上下文映射（对齐 H5 pkRankListPopup.vue `currentAnchorInfo`）：
    /// - `.my`：AnchorInfoStore（session 主播）+ PKStore.ownAnchorId
    /// - `.opponent`：PKContext（对手 uid + nickname + avatar）
    @MainActor @ViewBuilder
    private func pkRankSheet(side: PKRankSide) -> some View {
        if let ctx = store.ctx {
            switch side {
            case .my:
                let anchorInfo = AnchorInfoStore.shared
                PKRankSheetView(
                    side: .my,
                    pkId: ctx.pkId,
                    anchorId: store.ownAnchorId,
                    anchorAvatarURL: anchorInfo.iconURL?.absoluteString,
                    anchorNickname: anchorInfo.displayName
                )
            case .opponent:
                PKRankSheetView(
                    side: .opponent,
                    pkId: ctx.pkId,
                    anchorId: ctx.oppositeUserId,
                    anchorAvatarURL: ctx.oppositeAvatar,
                    anchorNickname: ctx.oppositeNickname ?? ""
                )
            }
        }
    }

    // MARK: - 对手静音按钮

    private var opponentMuteButton: some View {
        Button {
            isOpponentMuted.toggle()
            // 2026-07-07 v6：接入真 API（原 TODO 消化）。PKStore.handleMute 内部已 guard state==.inPK；
            // 非 PK 态点击 no-op 无副作用。API 失败已在 handleMute 内 catch logger.warning 兜底，UI 状态不回滚
            Task { await store.handleMute(isOpponentMuted) }
        } label: {
            Group {
                if isOpponentMuted {
                    Image("pkBattleMuteIcon")
                        .resizable()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
            }
            .contentShape(Circle())
        }
        .accessibilityLabel(Text(isOpponentMuted ? L10n.PK.opponentUnmute : L10n.PK.opponentMute))
    }

    // MARK: - 对手 nickname 胶囊

    /// 对齐 H5 pkBattleView.vue L354-367：`w-118 rounded-is-20 bg-black/40 p-4 backdrop-blur-10`
    /// LTR 下 `rounded-is-20` = 左半圆角 20pt（右侧接屏幕右边）
    private func opponentNicknameChip(nickname: String) -> some View {
        HStack(spacing: 6) {
            AvatarView(urlString: nil, size: 24, kind: .user)
            Text(nickname)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(width: 118, alignment: .leading)   // H5 `w-118`
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20,
                                                      bottomLeading: 20))
                .fill(Color.black.opacity(0.4))
        )
        .accessibilityElement(children: .combine)
    }
}

/// AgoraManager.oppositeRemoteView 桥到 SwiftUI（铁律 §2 稳定单例 UIView）。
///
/// **2026-07-07 反悔**：原方案包一层 container UIView + Auto Layout 约束把 oppositeRemoteView
/// 铺满 container，看似合理但**破坏了 SDK 的 frame-based 渲染子 view 布局**——
/// SDK `setupRemoteVideoEx` 内部向 canvas.view (=oppositeRemoteView) 添加 frame-based 渲染子视图，
/// 这些子视图**不响应** Auto Layout resize；当 SwiftUI 重建 container 时子视图 frame 保留旧值 →
/// 用户看到"对手画面只显示右下一小块"。
///
/// 正解**对齐 1v1 通话 [RemoteVideoView](../../Agora/RemoteVideoView.swift)** 模式：
/// makeUIView 直接返回单例 oppositeRemoteView，SwiftUI 直接控制其 frame，
/// SDK 渲染子视图随单例 UIView 布局自然 layout（autoresizesSubviews 默认 true）。
///
/// **2026-07-07 v4 可见性**：private → internal —— LiveRoomView 需在 PK 分屏 HStack 中直接使用，
/// 让对方视频与本端 CameraPreview 位于同一 HStack sibling，SwiftUI 保证严格共坐标系。
struct PKOppositeContainer: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
