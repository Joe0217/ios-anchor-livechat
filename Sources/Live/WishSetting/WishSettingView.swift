import SwiftUI

/// 愿望单设置页（L-spec-愿望单设置页 v1，stage 2 视觉对齐设计稿 `/Users/joe/Downloads/开播设置.png`）。
///
/// **stage 2 修订**（对齐设计稿 6 处差异）：
/// - 新增 Review status 卡片（顶部第 1 张卡）+ 右上 Record 按钮（stage 1 disabled）
/// - Wish theme 字数上限 15 → 20（对齐设计稿 "(0/20)"；H5 code 15 已过时）
/// - Select template：3 chip 卡片（大图标 + 主标题 + 副标题）替代文字胶囊；用切图 wishTemplateCommon/Private/NoText
/// - Add wish gift：礼物行改为**横向 layout**（图 + 名 + 价 + 数量输入 + ✕）替代 tile 网格
/// - Save 按钮改为紫→红渐变
/// - 合规规范卡：checkmark 用系统 SF Symbols（Group 109517 切图肉眼分辨不出）
struct WishSettingView: View {
    @StateObject private var store = WishSettingStore()
    @Environment(\.dismiss) private var dismiss

    @State private var showTemplateDropdown = false
    @State private var showGiftPicker = false

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    if case let .error(msg) = store.state {
                        errorBanner(msg)
                    }
                    reviewStatusCard        // 新增（对齐设计稿）
                    wishThemeCard
                    templateSelectionCard   // 3 chip 卡片
                    if store.promiseType != .none {
                        templateDropdownCard
                    }
                    wishlistCard
                    ruleCard
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            // P1-2 toast 覆盖层（对齐 H5 showToast + LiveSettingsView 同 pattern）
            // 承诺审核中（20004）等可修正边界提示；无 hit test，2s 自清
            if let toast = store.toastMessage {
                VStack {
                    Text(toast).toastStyle()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: store.toastMessage)
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .navigationTitle(L10n.wishSettingNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGiftPicker) {
            // H-4 迁移：心愿单 gift+count picker → CommonGiftPanel（tabs=[.popular], footer=.confirm, stepper=.visible(1...99)）
            CommonGiftPanel(config: .wishGift(onConfirm: { gift, count in
                store.addGift(gift, count: count)
            }))
            .sheetTopInset()
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $store.showRuleDoc) {
            ruleDocSheet.giftPanelSheetBackground()
        }
        .alert(L10n.wishSettingSubmittedForReview, isPresented: $store.showSubmitSuccessAlert) {
            Button(L10n.giftPickerConfirm, role: .cancel) { }
        }
        .task { await store.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Cards

    /// Review status 卡（设计稿顶部新卡）：审核状态显示 + 右上 Record 按钮
    private var reviewStatusCard: some View {
        cardBlock {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(L10n.wishSettingReviewStatus)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Image(systemName: "gift.fill")
                            .font(.caption).foregroundStyle(.pink)
                    }
                    Text(L10n.wishSettingReviewStatusIntro)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // Record 按钮（stage 1 disabled + Coming Soon，走独立 Audit Records M spec）
                Text(L10n.wishSettingRecord)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.pink.opacity(0.35), in: Capsule())
            }
        }
    }

    private var wishThemeCard: some View {
        cardBlock {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.wishSettingThemeTitle).font(.subheadline.bold()).foregroundStyle(.white)
                        Text(L10n.wishSettingThemeIntro)
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // 右上 Submit 按钮（对齐设计稿）
                    Button {
                        Task { await store.submitWishTheme() }
                    } label: {
                        HStack(spacing: 4) {
                            if store.state == .submittingTheme { ProgressView().tint(.white).scaleEffect(0.7) }
                            Text(L10n.wishSettingSubmit)
                                .font(.caption.bold()).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.pink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.state == .submittingTheme || store.wishTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ZStack(alignment: .bottomTrailing) {
                    TextField(
                        "",
                        text: $store.wishTheme,
                        prompt: Text(L10n.liveSettingsBioPlaceholder).foregroundColor(.white.opacity(0.4)),
                        axis: .vertical
                    )
                    .foregroundStyle(.white)
                    .padding(10)
                    .padding(.trailing, 46)   // 让位给右下计数
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(store.state == .submittingTheme)

                    Text("(\(store.wishTheme.count)/\(WishSettingStore.themeMaxLen))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        .padding(10)
                }
            }
        }
    }

    /// 3 chip 大卡（Common / Private / No text）—— 用切图作为大图标
    private var templateSelectionCard: some View {
        cardBlock {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.wishSettingSelectTemplate)
                    .font(.subheadline.bold()).foregroundStyle(.white)
                HStack(spacing: 10) {
                    templateChip(
                        type: .common,
                        iconAsset: "wishTemplateCommon",
                        titleKey: L10n.wishSettingTypeCommon,
                        subtitleKey: L10n.wishSettingTypeCommonSub
                    )
                    templateChip(
                        type: .private_,
                        iconAsset: "wishTemplatePrivate",
                        titleKey: L10n.wishSettingTypePrivate,
                        subtitleKey: L10n.wishSettingTypePrivateSub
                    )
                    templateChip(
                        type: .none,
                        iconAsset: "wishTemplateNoText",
                        titleKey: L10n.wishSettingTypeNoText,
                        subtitleKey: L10n.wishSettingTypeNoTextSub
                    )
                }
            }
        }
    }

    private func templateChip(type: PromiseType, iconAsset: String, titleKey: String, subtitleKey: String) -> some View {
        let selected = store.promiseType == type
        return Button {
            Task {
                await store.changeType(type)
                if type == .none { showTemplateDropdown = false }
            }
        } label: {
            VStack(spacing: 6) {
                Image(iconAsset)
                    .resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                Text(titleKey)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                Text(subtitleKey)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.pink.opacity(0.18) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.pink : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var templateDropdownCard: some View {
        cardBlock {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task {
                        if !showTemplateDropdown {
                            if store.promiseType == .common && store.commonTemplates.isEmpty {
                                await store.fetchCommonTemplates()
                            } else if store.promiseType == .private_ && store.privateTemplates.isEmpty {
                                await store.fetchPrivateTemplates()
                            }
                        }
                        showTemplateDropdown.toggle()
                    }
                } label: {
                    HStack {
                        Text(store.promiseText.isEmpty ? L10n.wishSettingChooseTemplate : store.promiseText)
                            .font(.footnote)
                            .foregroundStyle(store.promiseText.isEmpty ? .white.opacity(0.4) : .white)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: showTemplateDropdown ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if showTemplateDropdown { dropdownList }
            }
        }
    }

    @ViewBuilder
    private var dropdownList: some View {
        if store.promiseType == .common {
            if store.loadingTemplates {
                ProgressView().tint(.white).padding(10)
            } else if store.commonTemplates.isEmpty {
                Text(L10n.wishSettingNoTemplateAvailable)
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).padding(10)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.commonTemplates) { tpl in
                        templateRow(tpl, deletable: false) {
                            store.pickCommonTemplate(tpl)
                            showTemplateDropdown = false
                        }
                    }
                }
            }
        } else if store.promiseType == .private_ {
            if store.loadingPrivate {
                ProgressView().tint(.white).padding(10)
            } else if store.privateTemplates.isEmpty {
                Text(L10n.wishSettingNoTemplateAvailable)
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).padding(10)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.privateTemplates) { tpl in
                        templateRow(tpl, deletable: true) {
                            store.pickPrivateTemplate(tpl)
                            showTemplateDropdown = false
                        }
                    }
                }
            }
        }
    }

    private func templateRow(_ tpl: WishTemplate, deletable: Bool, onSelect: @escaping () -> Void) -> some View {
        HStack {
            Button(action: onSelect) {
                Text(tpl.content).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if deletable {
                Button {
                    Task { await store.deletePrivateTemplate(tpl) }
                } label: {
                    Image(systemName: "trash").foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Wishlist card（礼物行横向 layout）

    private var wishlistCard: some View {
        cardBlock {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.liveSettingsWishlistTitle)
                        .font(.subheadline.bold()).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: L10n.wishSettingAddedFormat, store.wishlist.count, store.wishGiftMaxNum))
                        .font(.caption).foregroundStyle(.pink)
                }
                Text(L10n.liveSettingsWishlistIntro)
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(store.wishlist) { g in
                        wishGiftRow(g)
                    }
                    if store.canAddMoreGift {
                        Button { showGiftPicker = true } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .frame(height: 44)
                                Image(systemName: "plus")
                                    .font(.title3).foregroundStyle(.pink)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 礼物行横向 layout（对齐设计稿）：图 + 名 + 价 + 数量输入 + ✕
    private func wishGiftRow(_ g: WishGift) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: g.giftSmallImg),
                             contentMode: .fit,
                             persistent: true,
                             cdn: (.gift, .fit)) {
                Color.white.opacity(0.06)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(g.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Image("coins")
                        .resizable()
                        .frame(width: 10, height: 10)
                    Text("\(g.giftPrice)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()

            // 数量步进器
            HStack(spacing: 4) {
                Button { store.changeGiftNum(id: g.id, delta: -1) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(g.giftNum > 1 ? .pink : .white.opacity(0.3))
                }
                .buttonStyle(.plain).disabled(g.giftNum <= 1)
                Text("\(g.giftNum)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20)
                Button { store.changeGiftNum(id: g.id, delta: 1) } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(g.giftNum < 99 ? .pink : .white.opacity(0.3))
                }
                .buttonStyle(.plain).disabled(g.giftNum >= 99)
            }

            Button { store.removeGift(id: g.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Rule check

    private var ruleCard: some View {
        cardBlock {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.wishSettingRuleTitle)
                    .font(.subheadline.bold()).foregroundStyle(.white)
                Text(L10n.wishSettingRuleAgree)
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 8) {
                    Button { store.ruleChecked.toggle() } label: {
                        Image(systemName: store.ruleChecked ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(store.ruleChecked ? .pink : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    Text(L10n.wishSettingRuleAgreeShort)
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                    Button {
                        store.showRuleDoc = true
                    } label: {
                        Text(L10n.wishSettingRuleLink)
                            .font(.caption.bold())
                            .foregroundStyle(.pink)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Text(L10n.wishSettingRuleFooter)
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ruleDocSheet: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.screenBackground.ignoresSafeArea()
                ScrollView {
                    Text(L10n.wishSettingRuleDoc)
                        .font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .padding(16)
                }
            }
            .navigationTitle(L10n.wishSettingRuleLink)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.giftPickerConfirm) { store.showRuleDoc = false }.foregroundStyle(.pink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Save bar（渐变按钮）

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            Button {
                // P0-1：Save 按钮始终可点；tap 后按 canSave 4 项失败原因分层给具体 toast（对齐 H5 index.vue:351-364）
                // P1-2：成功保存 → toast "Saved" → 600ms 延迟 pop（对齐 H5 index.vue:396-397）
                if store.submitTapped() == .saved {
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        dismiss()
                    }
                }
            } label: {
                Text(L10n.wishSettingSave)
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(
                        // 紫→红渐变（对齐设计稿 + Work 悬浮开关同渐变色 #8515FF → #E40132）
                        LinearGradient(
                            colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    // 视觉：canSave 未满足时按钮半透明作弱提示，但**不 disabled**（tap 后走 submitTapped 给具体 toast）
                    .opacity(store.canSave ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.Palette.screenBackground)
    }

    // MARK: - Helpers

    /// 通用 card 容器（无 title 版；title 由内部 layout 自行渲染，因为设计稿多张卡有右上按钮）
    private func cardBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(msg).font(.footnote).foregroundStyle(.white).lineLimit(3)
            Spacer()
            Button { store.clearErrorIfNeeded() } label: {
                Image(systemName: "xmark").foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

#if DEBUG
#Preview("editing") {
    NavigationStack { WishSettingView() }
        .preferredColorScheme(.dark)
}
#endif
