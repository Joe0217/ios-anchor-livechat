import SwiftUI

/// Work（工作台）整屏：周等级 + 概览卡 + 今日收益 + 工具区。
/// 深色背景，纵向滚动，左右安全边距 12pt，区块间距 16pt。
///
/// 在线开关悬浮在右下角，距 tabbar 上边 180pt。
/// 点 Offline 弹自定义确认卡（对齐 H5 useStandardPopup 视觉 + 逻辑）：
/// - confirm(Yes turn offline) → 真下线
/// - cancel(No turn offline) → 保持在线
/// - 点空白 dim → 保持在线
///
/// path 由 MainTabView 上抬持有；WorkRoute 路由表注册在 MainTabView 根 NavigationStack。
struct WorkView: View {
    @StateObject private var vm = WorkViewModel()
    @Binding var path: NavigationPath

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Metric.sectionSpacing) {
                    WeeklyLevelHeader(vm: vm)
                    StatCardsRow(vm: vm)
                    TodayIncomeCard(vm: vm)
                    ToolsSection(showNewbie: vm.showNewbie, showBigR: vm.showBigR)
                }
                .padding(.horizontal, Theme.Metric.screenMargin)
                .padding(.top, 8)
                // 预留 ≥ 180(overlay 距 tabbar) + 开关高度 ≈ 44 + 余 8
                .padding(.bottom, 232)
            }
            .scrollIndicators(.hidden)
        }
        // 悬浮开关：overlay 精确定位，距 tabbar 上边 180pt（用户 2 次指定共 +100pt）
        .overlay(alignment: .bottomTrailing) {
            FloatingOnlineToggle(vm: vm)
                .padding(.trailing, 16)
                .padding(.bottom, 180)
        }
        // 下线确认：H5 useStandardPopup 自定义视觉（紫色渐变卡 + 双按钮 + dim 遮罩）
        .overlay {
            if vm.showOfflineConfirm {
                OfflineConfirmDialog(
                    onConfirm: { vm.confirmGoOffline() },
                    onCancel: { vm.showOfflineConfirm = false }
                )
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.showOfflineConfirm)
        .preferredColorScheme(.dark)
    }
}

/// 悬浮在右下的在线开关。开态紫→红渐变；关态深灰。
/// 读 shared `OnlineStatusStore` 保证与 Home 顶部圆点状态一致。
private struct FloatingOnlineToggle: View {
    @ObservedObject var vm: WorkViewModel
    @ObservedObject private var status = OnlineStatusStore.shared

    var body: some View {
        Button {
            vm.requestToggleOnline()
        } label: {
            HStack(spacing: 5) {
                if status.userSetOnline {
                    Text(L10n.workOnline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    knob
                } else {
                    knob
                    Text(L10n.workOffline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .padding(5)
            .background(
                Capsule().fill(status.userSetOnline
                               ? AnyShapeStyle(LinearGradient(
                                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                    startPoint: .leading, endPoint: .trailing))
                               : AnyShapeStyle(Color(hex: 0x272727)))
            )
            .overlay(
                Capsule().stroke(Color(hex: 0xFA06F4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.workOnline)
        .accessibilityValue(status.userSetOnline ? L10n.workOnlineOn : L10n.workOnlineOff)
    }

    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: 22, height: 22)
            .overlay(
                Circle().stroke(Color(hex: 0xD000D7).opacity(0.35), lineWidth: 1.5)
                    .padding(2)
            )
    }
}

/// 下线确认弹窗，视觉对齐 H5 useStandardPopup：
/// - 遮罩：黑 60% 透明 + 点击关闭（= cancel = 保持在线）
/// - 卡片：319 宽，圆角 16，紫色渐变 (#5300A1 → #3800A0)，粉色发光边（≈ inset shadow rgba(250,6,244,0.5)）
/// - message 16pt 白色，行高 20，左对齐
/// - 按钮组 gap 12：左半透白 cancel / 右紫→红渐变 confirm，皆 40h 圆角 8
private struct OfflineConfirmDialog: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // dim 遮罩，点击 = cancel（对齐 H5 onUpdate:show=false → resolve(false)）
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(spacing: 20) {
                Text(L10n.offlineConfirmMessage)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    // Cancel：半透白（H5 rgba(255,255,255,0.2)）
                    Button(action: onCancel) {
                        Text(L10n.offlineConfirmNo)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Confirm：紫→红渐变（H5 linear-gradient(90deg, #8515FF, #E40132)）
                    Button(action: onConfirm) {
                        Text(L10n.offlineConfirmYes)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(width: 319)
            // 卡片主背景：紫色渐变
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // 粉色发光边（≈ H5 inset shadow rgba(250,6,244,0.5)）
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: 0xFA06F4).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0xFA06F4).opacity(0.35), radius: 8, y: 2)
        }
    }
}

/// Work 子页路由。
/// - `.pocDebug`：DEBUG 期 POC 调试台
/// - `.firstLiveRule`：首次开播规则阅读页（对齐 H5 `/liveRule?type=3`，10s 倒计时）
/// - `.liveSettings`：开播设置页（B-spec-开播设置页）
/// - `.wishSetting`：愿望单设置页（L-spec-愿望单设置页）
/// - `.beautySettings`：美颜设置页（K-spec-美颜设置页）
/// - `.giftMessage`：私密媒体解锁（H-2）
/// - `.newbie` / `.bigR`：入口对齐 H5，页面 J 里程碑落地（当前占位）
enum WorkRoute: Hashable {
    case pocDebug
    case firstLiveRule
    case liveSettings
    case wishSetting
    case beautySettings
    case giftMessage        // H-2 私密媒体解锁
    case newbie             // J 里程碑：新手任务
    case bigR               // J 里程碑：Star User 大 R 名单
    /// 直播结果页（B spec v7 从 fullScreenCover 改为 push 页面；LiveRoomView state=.ended 触发切 tab + path 重建）。
    /// 关联字段：begin/endTimestamp（毫秒）+ endType（强制下播原因；nil 表示用户主动 endLive）
    case liveResult(begin: Int64, end: Int64, endType: Int?)
}

/// Work 里 J 里程碑未落地页面的占位视图（保持 H5 视觉入口对齐）。
struct WorkComingSoonView: View {
    let title: String

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "hourglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Coming Soon")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    WorkView(path: .constant(NavigationPath()))
}
