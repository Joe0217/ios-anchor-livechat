import SwiftUI

/// H5 主播端 CActiveTycoonBadge / 用户端 1758252289621.webp 金色 VIP 标
/// Phase 1 用 SF Symbol crown.fill 占位（未来接切图）
struct PublicChatVipBadge: View {
    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 8))
            .foregroundColor(.yellow)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(width: 32, height: 12)
            .background(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.85, blue: 0.2),
                             Color(red: 0.85, green: 0.55, blue: 0.05)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}
