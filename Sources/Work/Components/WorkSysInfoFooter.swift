import SwiftUI
import UIKit
import Combine

/// Work 页底部系统信息 —— 对齐 H5 [work/sysInfo.vue](anchor-livechat-h5/src/views/work/sysInfo.vue)。
///
/// 内容:
/// - 服务器时间(Asia/Shanghai UTC+8;每秒 tick,onDisappear 停)
/// - 官方 WhatsApp 联系方式(号码从 WorkViewModel.whatsappPhone 派生;空则整行隐藏)
/// - copy 图标 —— 点击复制号码到剪贴板 + Toast 提示
///
/// 时区固定 Asia/Shanghai 与 CLAUDE.md "任务重置/倒计时等业务用 Asia/Shanghai 固定时区" 约束一致。
struct WorkSysInfoFooter: View {
    let whatsapp: String

    @State private var serverTimeText: String = "--"
    @State private var timerCancellable: AnyCancellable?

    var body: some View {
        VStack(spacing: 8) {
            // 服务器时间(Asia/Shanghai UTC+8 每秒 tick)
            HStack(spacing: 4) {
                Text(L10n.systemServerTime + ":")
                Text(serverTimeText)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))

            // WhatsApp + copy(号码空时整行隐藏 —— fail-silent)
            if !whatsapp.isEmpty {
                HStack(spacing: 4) {
                    Text(String(format: L10n.contactOfficialWhatsapp, whatsapp))
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { copyPhone() }
                .accessibilityElement(children: .combine)
                .accessibilityHint(L10n.commonCopySuccess)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .onAppear { startTicking() }
        .onDisappear { timerCancellable?.cancel(); timerCancellable = nil }
    }

    // MARK: - server time timer

    private func startTicking() {
        updateServerTime()   // 首帧显示
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in updateServerTime() }
    }

    private func updateServerTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")   // 固定 POSIX,不受用户 locale 影响
        serverTimeText = formatter.string(from: Date())
    }

    // MARK: - copy

    private func copyPhone() {
        UIPasteboard.general.string = whatsapp
        AppToastCenter.shared.show(L10n.commonCopySuccess)
    }
}
