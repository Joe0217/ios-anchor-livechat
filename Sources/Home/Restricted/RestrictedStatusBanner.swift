import SwiftUI

/// 未审核账号受限首屏顶部审核提示 banner。
///
/// 对齐 H5 蓝本 [mineRestricted/index.vue:104-107](../../../anchor-livechat-h5/src/views/mineRestricted/index.vue) 与
/// [newsRestricted/index.vue:115-128](../../../anchor-livechat-h5/src/views/newsRestricted/index.vue):
/// - **背景色**按审核态派生 3 档(H5 `inviteColor.value`):
///   - `#CC6600` 橘褐 → 审核中 / 封禁(可申诉类)
///   - `#8B0000` 深红 → 审核未通过(可 Resubmit)
///   - `#24A600` 深绿 → 审核通过(kill-app-restart 提示)
/// - **文案**分 5 态,支持 mine 页短提示 / news 页完整长文两种
///
/// - Parameter user: LoginResult(登录响应)审核字段(valid/onReview/banAlways/bannedSubType/type)
/// - Parameter variant: `.mine` 短提示 / `.news` 完整长文(带 WhatsApp/联系提示)
struct RestrictedStatusBanner: View {
    let user: LoginResult?
    var variant: Variant = .mine

    enum Variant {
        /// mineRestricted 短提示(拒绝原因 + 提示到 mine 页查看/修正)
        case mine
        /// newsRestricted 完整长文(含 WhatsApp/admin 联系入口引导)
        case news
    }

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bannerBackgroundColor)
            )
    }

    /// 派生 banner 文案(供 view 层拿原文调 Translate 用;body message 内部复用同一逻辑)
    var message: String { Self.derive(user: user, variant: variant) }

    /// static 版本:让不持有 view 实例的调用方(如 Translate handler)也能拿到当前审核态原文。
    static func derive(user: LoginResult?, variant: Variant) -> String {
        guard let u = user else { return "" }
        switch (u.valid, u.type, u.onReview, u.banAlways) {
        case (0, _, _, true):
            return "Your account has been suspended permanently."
        case (0, _, _, _):
            if variant == .mine {
                return "Your account has been suspended. If you have any questions, please contact us within the app or add us on WhatsApp below. If you meet the requirements, you can withdraw your balance in [Wallet]"
            }
            let hours = u.bannedSubType ?? 0
            return "Your account has been suspended for \(hours) hours."
        case (1, let t, _, _) where t == 2 || t == 9:
            return "Congratulations, your review has been approved. Please kill the app and restart it to enter"
        case (1, _, true, _):
            return "your profile is under review"
        case (1, _, _, _):
            // 审核未通过(mine/news 文案相同,H5 蓝本两处 hardcoded 同款,合并去 dead branch)
            return "Hello, your application is temporarily rejected due to content that needs to be revised. Please check the reason for rejection on the [Mine] homepage, make the necessary corrections, and resubmit.\nReason for rejection:\nBelow is our app's official WhatsApp. Feel free to contact us through the admin account in the app or via WhatsApp if you have any questions."
        default:
            return ""
        }
    }

    /// 对齐 H5 `inviteColor.value` 3 档:#CC6600 橘褐 / #8B0000 深红 / #24A600 深绿
    /// 复用项目公共 `Color(hex: UInt)` init(Theme.swift:1149),对齐 prefer-shared-component-over-adhoc rule。
    private var bannerBackgroundColor: Color {
        guard let u = user else { return Color(hex: 0xCC6600) }
        // 审核通过(kill-app-restart)
        if u.valid == 1 && (u.type == 2 || u.type == 9) {
            return Color(hex: 0x24A600)
        }
        // 审核未通过(可 Resubmit)
        if u.valid == 1 && u.onReview != true && u.type != 2 && u.type != 9 {
            return Color(hex: 0x8B0000)
        }
        // 其他(审核中/封禁) — 橘褐
        return Color(hex: 0xCC6600)
    }
}
