import SwiftUI

/// 派对房背景图选择通用 sheet（create + settings 复用）。
///
/// **背景**：v7.13 前 create 侧和 settings 侧各自维护一份 `bgCard`/`backgroundCard`，
/// 同款 UI 陷阱（`.aspectRatio(.fill) + .clipShape` 缺 `.clipped()`）在一处修好另一处
/// 遗漏，反复出问题。抽公共组件后 pattern 只有一份。
///
/// **交互**：card 用**同款 v7.13 GeometryReader + explicit frame + .clipped() + .clipShape**
/// 硬矩形裁剪；点 grid card 只更新本地 selectedId；底部 Confirm 按钮 callback 上抛
/// 选中的 background 给父层处理（create 侧本地暂存到 submit / settings 侧调
/// setBackground API 即时保存）。
///
/// **参数**：
/// - `backgrounds` 完整背景列表（父层负责加载）
/// - `isLoading` 拉取中态（展示 ProgressView）
/// - `initialSelectedId` 首次打开时预选（父层传 store.selectedBackground?.id）
/// - `onConfirm` Confirm 上抛，父层负责保存 + 关闭 sheet；nil 表示无 Confirm（保留扩展）
///
/// **不管**：sheet 高度/presentationDetents 由父层挂 `.sheet` 时决定
/// （create + settings 都用 `.fraction(0.8)`）；空态文案外部通过 L10n 已本地化。
struct PartyBackgroundPickerSheet: View {
    let backgrounds: [PartyBackground]
    let isLoading: Bool
    let initialSelectedId: Int?
    let onConfirm: (PartyBackground) -> Void

    /// 本地暂存 —— 用户 tap grid card 只更新此 State，Confirm 时通过 `onConfirm` 上抛。
    @State private var selectedId: Int?

    // LazyVGrid 垂直 spacing + 每列 GridItem spacing 都要设水平/垂直间距才对称
    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 12) {
                Text(L10n.Party.createSectionBackground)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                content
                Spacer(minLength: 80)
            }
            confirmButton
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        // 打开 sheet 时用外部 initialSelectedId 初始化本地 selectedId
        .task(id: initialSelectedId) {
            if selectedId == nil { selectedId = initialSelectedId }
        }
    }

    // MARK: - Content 三态：loading / empty / grid

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                .padding(.top, 40)
        } else if backgrounds.isEmpty {
            Text(L10n.Party.createBgEmpty)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .padding(.top, 40)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(backgrounds) { bg in
                        backgroundCard(bg)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Card（v7.13 pattern：GeometryReader + explicit frame + clipped）

    private func backgroundCard(_ bg: PartyBackground) -> some View {
        let selected = selectedId == bg.id
        return Button {
            selectedId = bg.id
        } label: {
            // GeometryReader 拿 card 精确 w×h；image explicit .frame(w:h:) + .clipped() 硬矩形
            // clip layout；.clipShape 只 clip 圆角视觉。缺 .clipped() 图片以 .fill 撑大后超出参与
            // 父视图布局（v7.13 反悔教训）
            GeometryReader { geo in
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.partyCreateTempFill)

                    if let urlStr = bg.imgUrl ?? bg.bigImgUrl,
                       !urlStr.isEmpty,
                       let u = URL(string: urlStr) {
                        CachedAsyncImage(url: u, contentMode: .fill, persistent: true, cdn: (.avatarLarge, .fill)) {
                            Color.clear
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if selected {
                        Image("partyTemplateSelected")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .padding(6)
                    }
                    if !bg.isPermanent, let d = bg.duration, d > 0 {
                        VStack {
                            Spacer()
                            HStack {
                                Text("\(d)s")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.black.opacity(0.55)))
                                Spacer()
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Confirm

    private var confirmButton: some View {
        Button {
            guard let id = selectedId,
                  let bg = backgrounds.first(where: { $0.id == id }) else { return }
            onConfirm(bg)
        } label: {
            HStack {
                Spacer()
                Text(L10n.Party.createConfirm)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedId == nil)
        .opacity(selectedId == nil ? 0.5 : 1)
    }
}
