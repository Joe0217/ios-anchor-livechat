import SwiftUI

/// 本地 MC 标识，避免房间麦位依赖远端装饰图才能区分接待位。
struct PartyMCSeatBadge: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            Image(systemName: "crown.fill")
                .font(.system(size: compact ? 8 : 10, weight: .bold))
            Text("MC")
                .font(.system(size: compact ? 8 : 10, weight: .bold))
        }
        .foregroundColor(Color(hex: 0xFFE08A))
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(Color(hex: 0x5A1537).opacity(0.94)))
        .overlay {
            Capsule().stroke(Color(hex: 0xFFE08A).opacity(0.7), lineWidth: 0.5)
        }
        .accessibilityLabel("MC seat")
    }
}
