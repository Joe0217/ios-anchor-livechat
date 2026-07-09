import SwiftUI

/// Live H5 主播消息带 host icon（messageScroller L435 附近）
struct PublicChatHostBadge: View {
    var body: some View {
        Text("Host")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(red: 254/255, green: 0, blue: 222/255), in: Capsule())  // #FE00DE
    }
}
