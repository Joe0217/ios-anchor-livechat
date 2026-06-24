import SwiftUI

/// G 里程碑 spec §6 / M3-7：PK 结束结果弹窗。
///
/// 监听 `PKStoreObserver.didEndPK`，由父 view 控制显示；本期仅展示分数 + Top3 + 确认。
/// 富文本 HTML 白名单清洗复用 B 里程碑 NIMChatroomManager 规则（H 落地真实富文本时接）。
struct PKResultOverlay: View {
    @Binding var isPresented: Bool
    let myScore: Int
    let oppositeScore: Int
    let top3: [PKTopUser]

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(L10n.PK.resultTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    resultBadge

                    HStack(spacing: 24) {
                        scoreCol(title: "Me", value: myScore, color: .pink)
                        Text("VS").font(.headline).foregroundStyle(.white.opacity(0.7))
                        scoreCol(title: "Opp", value: oppositeScore, color: .blue)
                    }
                    .padding(.vertical, 12)

                    if !top3.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Top 3").font(.caption).foregroundStyle(.white.opacity(0.7))
                            ForEach(Array(top3.prefix(3).enumerated()), id: \.offset) { idx, u in
                                HStack(spacing: 8) {
                                    Text("#\(idx + 1)").font(.caption).foregroundStyle(.yellow)
                                    Text(u.nickName ?? "Anonymous").font(.caption).foregroundStyle(.white)
                                    Spacer()
                                    Text("\(u.value ?? 0)").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    Button { isPresented = false } label: {
                        Text(L10n.PK.resultConfirm)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(LinearGradient(colors: [.pink, .purple],
                                                      startPoint: .leading, endPoint: .trailing),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 32)
            }
            .transition(.opacity)
        }
    }

    private var resultBadge: some View {
        Group {
            if myScore > oppositeScore {
                Text("🏆 WIN").font(.system(size: 22, weight: .black)).foregroundStyle(.yellow)
            } else if myScore < oppositeScore {
                Text("😭 LOSE").font(.system(size: 22, weight: .black)).foregroundStyle(.red)
            } else {
                Text("🤝 DRAW").font(.system(size: 22, weight: .black)).foregroundStyle(.cyan)
            }
        }
    }

    private func scoreCol(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
            Text("\(value)").font(.system(size: 24, weight: .bold)).foregroundStyle(color)
        }
    }
}
