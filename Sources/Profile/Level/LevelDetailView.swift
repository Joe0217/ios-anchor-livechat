import SwiftUI

/// 段位详情页：当前段位、分数、距下一档差距、彩虹光谱条。
///
/// 入口：ProfileHeader SS 段位旁箭头点击。
/// 复用 Theme 的 tierSpectrum + Gradients.rainbow 渲染光谱条。
struct LevelDetailView: View {
    @StateObject private var vm = LevelDetailViewModel()

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    switch vm.loadState {
                    case .idle, .loading:
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 60)
                    case .error(let msg):
                        errorView(msg)
                    case .loaded:
                        if let info = vm.info {
                            currentTierCard(info)
                            tierSpectrumCard(info)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle(L10n.levelDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if vm.info == nil { await vm.reload() }
        }
    }

    private func currentTierCard(_ info: LevelInfo) -> some View {
        VStack(spacing: 12) {
            Text(L10n.levelDetailCurrent)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Text(info.levelName ?? Self.tierName(forLevel: info.level ?? 0))
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(Theme.Gradients.rainbow)
            Text("\(L10n.workScorePrefix)\(info.score ?? 0)")
                .font(.system(size: 14))
                .foregroundColor(.white)
            if let need = info.scoreToNextLevel, need > 0 {
                Text(String(format: L10n.workNeedMoreFormat, need))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tierSpectrumCard(_ info: LevelInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.levelDetailSpectrum)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))

            // 彩虹光谱条 + 进度小三角
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Gradients.rainbow)
                    .frame(height: 12)
                GeometryReader { geo in
                    let p = max(0, min(1, info.progress ?? Self.estimateProgress(info)))
                    Triangle()
                        .fill(Color.white)
                        .frame(width: 10, height: 8)
                        .offset(x: geo.size.width * p - 5, y: -10)
                }
                .frame(height: 12)
            }

            // 段位刻度名称
            HStack {
                ForEach(Self.tierNames, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button { Task { await vm.reload() } } label: {
                Text(L10n.profileRetry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 60)
    }

    private static let tierNames = ["D", "C", "NEW", "B", "A", "S", "SS"]

    private static func tierName(forLevel level: Int) -> String {
        level >= 0 && level < tierNames.count ? tierNames[level] : String(level)
    }

    /// 后端无 progress 字段时的估算：当前段位刻度位置 + score/nextScore 内插
    private static func estimateProgress(_ info: LevelInfo) -> Double {
        guard let lvl = info.level, lvl >= 0, lvl < tierNames.count else { return 0 }
        let base = Double(lvl) / Double(max(tierNames.count - 1, 1))
        if let s = info.score, let n = info.nextScore, n > 0 {
            let partial = min(1.0, Double(s) / Double(n))
            return min(1.0, base + partial / Double(tierNames.count))
        }
        return base
    }
}

/// LevelDetail VM：包一层 reload 状态机。
@MainActor
final class LevelDetailViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle, loading, loaded, error(String)
    }
    @Published private(set) var info: LevelInfo?
    @Published private(set) var loadState: LoadState = .idle

    func reload() async {
        loadState = .loading
        do {
            info = try await LevelService.getUserLevel()
            loadState = .loaded
        } catch let e as APIError {
            loadState = .error(e.message)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }
}

/// 向下指示三角（光谱进度指示）
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
