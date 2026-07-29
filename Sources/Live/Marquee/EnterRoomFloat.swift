import SwiftUI
import UIKit

/// 用户进场飘屏（对齐 H5 userEntranceFloat.vue）
///
/// 位置：屏幕顶部 38%；优先级为守护 > 活跃大 R > 普通等级。
/// 动画：右侧 0.6 秒滑入，按身份停留 1.2/3 秒，再向左 0.6 秒滑出。
struct EnterRoomFloat: View {
    @ObservedObject var queue: EnterRoomFloatQueue
    @State private var phase: AnimPhase = .initial

    private enum AnimPhase {
        case initial
        case staying
        case leaving
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let item = queue.current {
                    content(item)
                        .frame(maxWidth: max(0, geo.size.width - 24), alignment: .leading)
                        .offset(x: offset(for: geo.size.width))
                        .padding(.top, geo.size.height * 0.38)
                        .id(item.id)
                        .task(id: item.id) { await play(item) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 0)
        .allowsHitTesting(false)
        .zIndex(20)
    }

    private func content(_ item: EnterRoomFloatQueue.Item) -> some View {
        HStack(spacing: 6) {
            if item.isActiveTycoon && item.guardianLevel == 0 {
                AvatarView(urlString: item.avatarUrl, size: 36, kind: .user)
            }
            if item.userLevel > 0 { UserLevelBadge(level: item.userLevel, size: .small) }
            if item.isVip { VIPBadge(size: .small) }
            EnterRoomTextMarquee(
                nickname: item.nickname,
                enteredText: L10n.publicScreenEnteredRoom
            )
        }
        .padding(.leading, leadingInset(for: item))
        .padding(.trailing, trailingInset(for: item))
        .frame(height: height(for: item))
        .frame(minWidth: minimumWidth(for: item))
        .background { background(for: item) }
        .clipShape(Capsule())
        .padding(.leading, 12)
        .padding(.top, 0)
    }

    private func play(_ item: EnterRoomFloatQueue.Item) async {
        phase = .initial
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.6)) { phase = .staying }
        let stay: TimeInterval = item.guardianLevel > 0 || item.isActiveTycoon ? 3 : 1.2
        guard await sleep(0.6 + stay) else { return }
        withAnimation(.easeIn(duration: 0.6)) { phase = .leaving }
    }

    private func offset(for width: CGFloat) -> CGFloat {
        switch phase {
        case .initial: return width
        case .staying: return 0
        case .leaving: return -width
        }
    }

    @ViewBuilder
    private func background(for item: EnterRoomFloatQueue.Item) -> some View {
        if item.isActiveTycoon, item.guardianLevel == 0 {
            Image("liveUserTycoonEntrance")
                .resizable()
                .scaledToFill()
        } else if let url = backgroundURL(for: item) {
            CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
                backgroundFallback(for: item)
            }
        } else {
            backgroundFallback(for: item)
        }
    }

    private func backgroundFallback(for item: EnterRoomFloatQueue.Item) -> some View {
        LinearGradient(
            colors: item.isActiveTycoon
                ? [Color(hex: 0xFFBB02, opacity: 0.9), Color(hex: 0xFFE600, opacity: 0.6)]
                : [normalLevelColor(item.userLevel), normalLevelColor(item.userLevel, opacity: 0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func backgroundURL(for item: EnterRoomFloatQueue.Item) -> URL? {
        if item.guardianLevel > 0 {
            let level: String
            switch item.guardianLevel {
            case 3: level = "gold"
            case 2: level = "silver"
            default: level = "bronze"
            }
            return URL(string: "https://img.hnhily.link/mstatic/guardian/bg_guardian_enter_\(level).webp")
        }
        guard item.userLevel >= 46 else { return nil }
        let tier: Int
        switch item.userLevel {
        case 46...50: tier = 7
        case 51...55: tier = 8
        case 56...60: tier = 9
        case 61...65: tier = 10
        default: tier = 12
        }
        return URL(string: "https://img.hnhily.link/mstatic/live/level_border_\(tier).webp")
    }

    private func normalLevelColor(_ level: Int, opacity: Double = 1) -> Color {
        guard level > 0 else { return .clear }
        let color: UInt
        switch level {
        case 1: color = 0x5F8FBC
        case 2...10: color = 0x5E5ACF
        case 11...20: color = 0xDE8484
        case 21...30: color = 0xBF865E
        case 31...40: color = 0xDD6D9B
        default: color = 0xE8629A
        }
        return Color(hex: color, opacity: opacity)
    }

    private func height(for item: EnterRoomFloatQueue.Item) -> CGFloat {
        item.guardianLevel > 0 ? 35 : (item.isActiveTycoon ? 44 : 28)
    }

    private func minimumWidth(for item: EnterRoomFloatQueue.Item) -> CGFloat {
        item.guardianLevel > 0 ? 240 : (item.isActiveTycoon ? 220 : 0)
    }

    private func leadingInset(for item: EnterRoomFloatQueue.Item) -> CGFloat {
        item.guardianLevel > 0 ? 40 : (item.isActiveTycoon ? 4 : 10)
    }

    private func trailingInset(for item: EnterRoomFloatQueue.Item) -> CGFloat {
        item.guardianLevel > 0 ? 26 : (item.isActiveTycoon ? 16 : 10)
    }

    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// H5 `userEntranceFloat.vue`：文本超出可视区时在当前展示周期内从左向右完整滚动一次。
private struct EnterRoomTextMarquee: View {
    let nickname: String
    let enteredText: String
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, contentWidth - geo.size.width)
            HStack(spacing: 4) {
                Text(nickname)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: 0x1AFFCD))
                Text(enteredText)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .task(id: "\(nickname)|\(enteredText)|\(geo.size.width)") {
                offset = 0
                guard overflow > 1 else { return }
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: 2.1)) { offset = -overflow }
                } catch {
                    return
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 16, maxHeight: 16)
    }

    private var contentWidth: CGFloat {
        let nicknameWidth = (nickname as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .bold)]
        ).width
        let enteredWidth = (enteredText as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
        ).width
        return nicknameWidth + 4 + enteredWidth
    }
}
