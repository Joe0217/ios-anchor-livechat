import SwiftUI

/// Party 房间正在说话视觉反馈。
///
/// H5 对于已佩戴的声纹头像框，会在用户说话且麦克风可用时循环播放该 SVGA；
/// 未佩戴时则展示普通声波。这里复用 `RemoteSVGAImageView`，避免和礼物、表情的
/// 一次性播放器争抢生命周期。

/// `vfxUrl` 语义即专属 SVGA。签名或下载接口的 URL 可能不含文件后缀，
/// 因此只校验可播放的 HTTP(S) 地址；实际解析失败时由下方回退默认声纹。
private func isPartyVoicePrintURL(_ raw: String?) -> Bool {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return false
    }
    return true
}

/// 小语音位：优先播放服务端配置的声纹 SVGA，否则回退到普通双环声波。
/// 禁麦或用户自行关麦时，两种说话动效都必须停止，不能以原始音量状态回退显示声波。
struct PartySmallSeatSpeakingEffect: View {
    let isSpeaking: Bool
    let isVoicePrintActive: Bool
    let vfxURL: String?
    /// 头像实际直径；默认声纹从此边界开始向外扩散。
    let avatarDiameter: CGFloat
    /// 声纹扩散到的最大直径（SVGA 同样使用该尺寸）。
    let diameter: CGFloat

    @State private var didFailToLoadVoicePrint = false
    @State private var isVoicePrintReady = false

    var body: some View {
        let isActive = isSpeaking && isVoicePrintActive
        Group {
            if isPartyVoicePrintURL(vfxURL), !didFailToLoadVoicePrint {
                ZStack {
                    // 专属资源首次下载期间仍显示默认声纹；加载成功后在下一帧无缝切换。
                    PartySmallSeatSpeakingRing(
                        isSpeaking: isActive && !isVoicePrintReady,
                        avatarDiameter: avatarDiameter,
                        maximumDiameter: diameter
                    )
                    PartyVoicePrintFrame(
                        isActive: isActive,
                        urlString: vfxURL ?? "",
                        size: CGSize(width: diameter, height: diameter),
                        onLoadSuccess: {
                            isVoicePrintReady = true
                        },
                        onLoadFailure: {
                            didFailToLoadVoicePrint = true
                            isVoicePrintReady = false
                        }
                    )
                }
            } else {
                PartySmallSeatSpeakingRing(
                    isSpeaking: isActive,
                    avatarDiameter: avatarDiameter,
                    maximumDiameter: diameter
                )
            }
        }
        .onChange(of: vfxURL) { _ in
            didFailToLoadVoicePrint = false
            isVoicePrintReady = false
        }
        .onChange(of: isActive) { active in
            // 下次重新说话时允许重试专属资源，覆盖临时 CDN 或网络失败。
            if active {
                didFailToLoadVoicePrint = false
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 专属声纹在麦位存在期间保持挂载完成预加载；视觉层只在有效说话状态显示，
/// 避免 500ms 音量回调的短暂空档取消正在进行的 SVGA 解析。
private struct PartyVoicePrintFrame: View {
    let isActive: Bool
    let urlString: String
    let size: CGSize
    let onLoadSuccess: () -> Void
    let onLoadFailure: () -> Void

    var body: some View {
        RemoteSVGAImageView(
            url: URL(string: urlString),
            loops: 0,
            isPlaying: isActive,
            contentMode: .scaleAspectFit,
            onLoadFailure: onLoadFailure,
            onLoadSuccess: onLoadSuccess
        )
            .frame(width: size.width, height: size.height)
            .clipped()
            // 保持播放器挂载以完成预加载；静音时只隐藏视觉层，不显示声纹。
            .opacity(isActive ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isActive)
    }
}

/// Party Call 的麦位提示。数据源是 room seat 的 `showBubble`，语音位在头像上方显示箭头，
/// 视频位在卡片内顶部显示，避免被视频容器裁切。
struct PartySeatCallBubble: View {
    enum Placement {
        case aboveSeat
        case insideSeat
    }

    let isVisible: Bool
    let placement: Placement

    @State private var marqueeOffset: CGFloat = 42

    var body: some View {
        Group {
            if isVisible {
                bubble
                    .transition(.opacity)
                    .task {
                        marqueeOffset = 42
                        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                            marqueeOffset = -42
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityLabel(Text(L10n.Party.privateCallSeatBubble))
    }

    private var bubble: some View {
        HStack(spacing: 4) {
            Image(systemName: "phone.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.black.opacity(0.7)))

            GeometryReader { proxy in
                Text(L10n.Party.privateCallSeatBubble)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: marqueeOffset)
                    .frame(width: proxy.size.width, alignment: .leading)
            }
            .frame(height: 14)
            .clipped()
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .frame(width: 88, height: 22)
        .background(Capsule().fill(Color(hex: 0xFF659E)))
        .overlay(alignment: .bottom) {
            if placement == .aboveSeat {
                Triangle()
                    .fill(Color(hex: 0xFF659E))
                    .frame(width: 9, height: 4)
                    .offset(y: 4)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// 小语音位普通声波：从头像边缘开始向外扩散的两道主题玫红环。
/// 与 `partySeatRing` 同心；不改变布局尺寸（用 overlay 挂）。
struct PartySmallSeatSpeakingRing: View {
    let isSpeaking: Bool
    let avatarDiameter: CGFloat
    let maximumDiameter: CGFloat

    @State private var animate: Bool = false

    private var expansionScale: CGFloat {
        max(maximumDiameter / max(avatarDiameter, 1), 1)
    }

    var body: some View {
        ZStack {
            // 外环 · 相位 0
            Circle()
                .stroke(Theme.Palette.brandPink.opacity(0.9), lineWidth: 2)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .scaleEffect(animate ? expansionScale : 1.0)
                .opacity(animate ? 0.0 : 0.6)
                .animation(
                    .easeOut(duration: 0.8).repeatForever(autoreverses: false),
                    value: animate
                )
            // 内环 · 相位 0.2s 延迟（交错扩散效果）
            Circle()
                .stroke(Theme.Palette.brandPink.opacity(0.9), lineWidth: 2)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .scaleEffect(animate ? expansionScale : 1.0)
                .opacity(animate ? 0.0 : 0.6)
                .animation(
                    .easeOut(duration: 0.8)
                        .repeatForever(autoreverses: false)
                        .delay(0.2),
                    value: animate
                )
        }
        .opacity(isSpeaking ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isSpeaking)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { animate = true }
    }
}
