import SwiftUI

/// 守护规则 FAQ。文案来自 H5 主播端的六段规则，作为展示说明，不引入用户端购买操作。
struct GuardianRulesView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, body: String)] = [
        (L10n.guardianRulesQuestion1, L10n.guardianRulesAnswer1),
        (L10n.guardianRulesQuestion2, L10n.guardianRulesAnswer2),
        (L10n.guardianRulesQuestion3, L10n.guardianRulesAnswer3),
        (L10n.guardianRulesQuestion4, L10n.guardianRulesAnswer4),
        (L10n.guardianRulesQuestion5, L10n.guardianRulesAnswer5),
        (L10n.guardianRulesQuestion6, L10n.guardianRulesAnswer6)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("guardianRulesDecoration")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 228, height: 21)
                    .padding(.top, 12)

                Text(L10n.guardianRulesTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ruleSection(at: 0)
                        ruleSection(at: 1)
                        levelSection
                        privilegesSection
                        durationSection
                        rankingSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.38))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.commonClose)
            .padding(.top, 2)
            .padding(.leading, 5)
        }
    }

    @ViewBuilder
    private func ruleSection(at index: Int) -> some View {
        let section = sections[index]
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
            Text(section.body)
                .font(.system(size: 12))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections[2].title)
                .font(.system(size: 15, weight: .bold))
            Text(sections[2].body)
                .font(.system(size: 12))
            ForEach(GuardianLevel.displayOrder) { level in
                HStack(spacing: 6) {
                    Image(GuardianArtwork.tabIcon(for: level))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text(GuardianArtwork.levelName(level))
                        .font(.system(size: 12, weight: .bold))
                }
            }
            Text(L10n.guardianRulesLevelExtra)
                .font(.system(size: 12))
                .padding(.top, 2)
        }
        .foregroundStyle(.black)
    }

    private var privilegesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections[3].title)
                .font(.system(size: 15, weight: .bold))
            Text(sections[3].body)
                .font(.system(size: 12))
            Image("guardianRulesPrivileges")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            Text(L10n.guardianRulesPrivilegesExtra)
                .font(.system(size: 12))
        }
        .foregroundStyle(.black)
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections[4].title)
                .font(.system(size: 15, weight: .bold))
            Text(sections[4].body)
                .font(.system(size: 12))
            Text(L10n.guardianRulesDuration7)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesDuration30)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesDuration365)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesDurationExtra)
                .font(.system(size: 12))
                .padding(.top, 2)
        }
        .foregroundStyle(.black)
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections[5].title)
                .font(.system(size: 15, weight: .bold))
            Text(sections[5].body)
                .font(.system(size: 12))
            Text(L10n.guardianRulesRank1)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesRank2)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesRank3)
                .font(.system(size: 12, weight: .bold))
            Text(L10n.guardianRulesRankExtra)
                .font(.system(size: 12))
                .padding(.top, 2)
        }
        .foregroundStyle(.black)
    }
}

/// 已开启的权益才可预览。静态图、SVGA 和 MP4 分流复用项目现有渲染组件。
struct GuardianPrivilegePreviewView: View {
    let context: GuardianPrivilegePreviewContext

    @Environment(\.dismiss) private var dismiss
    @State private var showsFullscreen = false

    var body: some View {
        ZStack {
            Color.clear

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(GuardianArtwork.privilegeName(context.privilege))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: 0x222222))
                    Text(String(format: L10n.guardianPrivilegePreviewSubtitleFormat, GuardianArtwork.privilegeName(context.privilege)))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x6E6E85).opacity(0.7))
                        .multilineTextAlignment(.center)

                    GuardianPrivilegeMediaView(context: context, playsAudio: false)
                        .frame(width: 150, height: 150)
                        .padding(.top, 8)

                    if context.privilege == .mount {
                        Button {
                            showsFullscreen = true
                        } label: {
                            Label(L10n.guardianPrivilegePreview, systemImage: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 9)
                                .background(Color(hex: 0x9856E5), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 320)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0xBB9BFC), .white, .white],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.24), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.commonClose)
            }
        }
        .fullScreenCover(isPresented: $showsFullscreen) {
            GuardianFullscreenPreview(context: context)
        }
    }
}

private struct GuardianFullscreenPreview: View {
    let context: GuardianPrivilegePreviewContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            GuardianPrivilegeMediaView(context: context, playsAudio: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}

private struct GuardianPrivilegeMediaView: View {
    let context: GuardianPrivilegePreviewContext
    let playsAudio: Bool

    private var preferredURL: URL? {
        URL(string: context.dynamicImageURL ?? context.staticImageURL ?? "")
    }

    private var rawURL: String {
        context.dynamicImageURL ?? context.staticImageURL ?? ""
    }

    var body: some View {
        let normalized = rawURL.lowercased()
        if normalized.contains(".svga") {
            RemoteSVGAImageView(url: preferredURL, loops: 0, contentMode: .scaleAspectFit)
        } else if normalized.contains(".mp4") || normalized.contains(".webm") {
            LoopingVideoView(url: preferredURL, isMuted: !playsAudio)
        } else if let preferredURL {
            CachedAsyncImage(url: preferredURL, contentMode: .fit, persistent: true) {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(context.privilege == .gift
              ? GuardianArtwork.giftPreview(for: context.level)
              : GuardianArtwork.privilegeIcon(for: context.privilege, level: context.level, available: true))
            .resizable()
            .scaledToFit()
            .padding(18)
    }
}
