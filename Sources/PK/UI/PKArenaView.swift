import SwiftUI

/// G 里程碑 spec §6 / M3-5：PK 对战分屏容器（屏幕右半边对手画面 + 顶部分数条 + Top3 + 倒计时 + End PK）。
///
/// **铁律 §3**：本端 CameraPreview 不在此 view 内重建（由 LiveRoomView 主层全屏渲染）；
/// 本端预览自然透过左半边显示，PKArenaView 只接管右半边的对手画面挂载位 + 上层 UI 装饰。
///
/// **铁律 §1**：本 view 在 LiveRoomView 内必须用 if 链跨 `.starting/.inPK/.punishing` 三态承载 +
/// `.id("pkArena")` 锁 identity，避免 dismantleUIView 反复触发让 AgoraRtcVideoCanvas.view 黑屏。
struct PKArenaView: View {
    @ObservedObject var store: PKStore
    let agora: AgoraManager

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack(alignment: .top) {
                // 屏幕右半 对手画面挂载位（覆盖在本端 CameraPreview 之上）
                HStack(spacing: 0) {
                    Color.clear.frame(width: half)
                    PKOppositeContainer(view: agora.oppositeRemoteView)
                        .frame(width: half)
                }

                VStack(spacing: 0) {
                    Spacer().frame(height: 96)
                    scoreBar(myScore: store.scores?.pkCounter ?? 0,
                             oppositeScore: store.scores?.oppositePkCounter ?? 0)
                        .padding(.horizontal, 12)
                    HStack(alignment: .top, spacing: 0) {
                        topUsers(store.scores?.top3Users ?? [], align: .leading)
                            .frame(width: half)
                        topUsers(store.scores?.oppositeTop3Users ?? [], align: .trailing)
                            .frame(width: half)
                    }
                    .padding(.top, 8)
                    Spacer()
                    if store.state == .inPK {
                        countdownChip
                        endPKButton
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                    }
                }
                .frame(width: geo.size.width)
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    private func scoreBar(myScore: Int, oppositeScore: Int) -> some View {
        let total = max(1, myScore + oppositeScore)
        let myRatio = CGFloat(myScore) / CGFloat(total)
        return ZStack(alignment: .leading) {
            GeometryReader { g in
                Capsule().fill(.gray.opacity(0.4))
                Capsule()
                    .fill(LinearGradient(colors: [.pink, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * myRatio)
                HStack {
                    Text("\(myScore)").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white).padding(.leading, 10)
                    Spacer()
                    Text("\(oppositeScore)").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white).padding(.trailing, 10)
                }
            }
        }
        .frame(height: 22)
    }

    private func topUsers(_ users: [PKTopUser], align: HorizontalAlignment) -> some View {
        HStack(spacing: 4) {
            if align == .trailing { Spacer() }
            ForEach(Array(users.prefix(3).enumerated()), id: \.offset) { _, u in
                AsyncImage(url: URL(string: u.displayAvatar ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Circle().fill(.white.opacity(0.2))
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1))
            }
            if align == .leading { Spacer() }
        }
        .padding(.horizontal, 12)
    }

    private var countdownChip: some View {
        Text(formatTime(store.pkRemainingSeconds))
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(store.pkRemainingSeconds <= 5 ? .red : .white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
    }

    private var endPKButton: some View {
        Button {
            Task { await store.endPKActive() }
        } label: {
            Text(L10n.PK.arenaEndPK)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(.red.opacity(0.85), in: Capsule())
        }
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 把 AgoraManager.oppositeRemoteView（UIView 单例）桥到 SwiftUI；不在内重建实例。
private struct PKOppositeContainer: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // oppositeRemoteView 是 AgoraManager 内单例，不需要每次 update
    }
}
