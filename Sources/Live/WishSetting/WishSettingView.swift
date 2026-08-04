import SafariServices
import SwiftUI

/// 愿望单设置页（L-spec-愿望单设置页 v1，stage 2 视觉对齐设计稿 `/Users/joe/Downloads/开播设置.png`）。
///
/// **stage 2 修订**（对齐设计稿 6 处差异）：
/// - 新增 Review status 卡片（顶部第 1 张卡）+ 右上 Record 按钮（stage 1 disabled）
/// - Wish theme 字数上限为 H5 当前规则的 15 个字符
/// - Select template：3 chip 卡片（大图标 + 主标题 + 副标题）替代文字胶囊；用切图 wishTemplateCommon/Private/NoText
/// - Add wish gift：礼物行改为**横向 layout**（图 + 名 + 价 + 数量输入 + ✕）替代 tile 网格
/// - Save 按钮改为紫→红渐变
/// - 合规规范卡：checkmark 用系统 SF Symbols（Group 109517 切图肉眼分辨不出）
struct WishSettingView: View {
    @StateObject private var store = WishSettingStore()
    @Environment(\.dismiss) private var dismiss

    @State private var showTemplateDropdown = false
    @State private var showGiftPicker = false
    @State private var showAuditRecords = false
    @State private var shouldShowAuditRecordsAfterSuccess = false
    @State private var ruleGuidelinesPresentation: WishCommitmentGuidelinesPresentation?
    @State private var isOpeningRuleGuidelines = false

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
        .sheet(item: $ruleGuidelinesPresentation) { presentation in
            WishCommitmentSafariView(url: presentation.url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showAuditRecords) {
            WishSettingAuditRecordsSheet()
                .sheetTopInset()
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.7)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $store.showSubmitSuccessAlert, onDismiss: {
            guard shouldShowAuditRecordsAfterSuccess else { return }
            shouldShowAuditRecordsAfterSuccess = false
            showAuditRecords = true
        }) {
            WishSettingSubmitSuccessSheet(
                onGoToAuditRecords: {
                    shouldShowAuditRecordsAfterSuccess = true
                }
            )
            .presentationDetents([.height(460)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled()
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
                Button { showAuditRecords = true } label: {
                    Text(L10n.wishSettingRecord)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.pink.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
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
                    .onChange(of: store.wishTheme) { value in
                        if value.count > WishSettingStore.themeMaxLen {
                            store.wishTheme = String(value.prefix(WishSettingStore.themeMaxLen))
                        }
                    }

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
            // H5 切换任一类型都会立即收起旧类型的模板列表，不能等异步拉取结束。
            showTemplateDropdown = false
            Task {
                await store.changeType(type)
            }
        } label: {
            VStack(spacing: 6) {
                CDNAssetImage(iconAsset)
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
                        showTemplateDropdown = await store.shouldOpenTemplateDropdown(
                            currentlyOpen: showTemplateDropdown
                        )
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
                        templateRow(tpl,
                                    isSelected: store.promiseTemplateId == tpl.id,
                                    deletable: false) {
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
                        templateRow(tpl,
                                    isSelected: store.promiseText == tpl.content,
                                    deletable: true) {
                            store.pickPrivateTemplate(tpl)
                            showTemplateDropdown = false
                        }
                    }
                }
            }
        }
    }

    private func templateRow(_ tpl: WishTemplate,
                             isSelected: Bool,
                             deletable: Bool,
                             onSelect: @escaping () -> Void) -> some View {
        HStack {
            Button(action: onSelect) {
                Text(tpl.content).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.pink)
            } else if deletable {
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
                                Image(systemName: "plus")
                                    .font(.title3).foregroundStyle(.pink)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
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
                    CDNAssetImage("coins")
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
                        Task { await openCommitmentGuidelines() }
                    } label: {
                        Text(L10n.wishSettingRuleLink)
                            .font(.caption.bold())
                            .foregroundStyle(.pink)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpeningRuleGuidelines)
                    Spacer()
                }

                Text(L10n.wishSettingRuleFooter)
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// H5 从 `wish_commitment_standard` 配置读取承诺规范地址；未配置或请求失败仅提示。
    private func openCommitmentGuidelines() async {
        guard !isOpeningRuleGuidelines else { return }
        isOpeningRuleGuidelines = true
        defer { isOpeningRuleGuidelines = false }

        do {
            let configs = try await AppConfigService.fetch(keys: ["wish_commitment_standard"])
            guard let rawURL = configs["wish_commitment_standard"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                store.showToast(L10n.wishSettingNoTemplateAvailable)
                return
            }
            ruleGuidelinesPresentation = WishCommitmentGuidelinesPresentation(url: url)
        } catch {
            store.showToast(L10n.wishSettingNoTemplateAvailable)
        }
    }

    // MARK: - Save bar（渐变按钮）

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            Button {
                // P0-1：Save 按钮始终可点；tap 后按 canSave 4 项失败原因分层给具体 toast（对齐 H5 index.vue:351-364）
                // P1-2：成功保存 → toast "Saved" → 600ms 延迟 pop（对齐 H5 index.vue:396-397）
                Task {
                    if await store.submitTapped() == .saved {
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
            .disabled(store.isSubmittingSave)
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

private struct WishCommitmentGuidelinesPresentation: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 自由承诺送审成功反馈，对齐 H5 `wishlist-submit-success-modal.vue`。
private struct WishSettingSubmitSuccessSheet: View {
    let onGoToAuditRecords: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.commonClose))
            }

            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(Color(hex: 0x6F3BD6), in: Circle())
                .padding(.top, 2)

            Text(L10n.wishSettingSubmitSuccessTitle)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 14)
            Text(L10n.wishSettingSubmitSuccessSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                infoRow(icon: "checklist", label: L10n.wishSettingSubmitSuccessReviewStatus,
                        value: L10n.wishSettingSubmitSuccessPendingReview, highlighted: true)
                Divider().overlay(Color.white.opacity(0.12))
                infoRow(icon: "clock", label: L10n.wishSettingSubmitSuccessReviewTime,
                        value: L10n.wishSettingSubmitSuccessReviewTimeValue)
                Divider().overlay(Color.white.opacity(0.12))
                infoRow(icon: "bell", label: L10n.wishSettingSubmitSuccessNotify,
                        value: L10n.wishSettingSubmitSuccessNotifyValue)
            }
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Text(L10n.wishSettingSubmitSuccessTip)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Button(action: dismiss.callAsFunction) {
                Text(L10n.giftPickerConfirm)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Button {
                onGoToAuditRecords()
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.wishSettingSubmitSuccessGoToWishlist)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xE88BFF))
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x2A1248).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func infoRow(icon: String, label: String, value: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? Color(hex: 0xFF9F3E) : .white)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// iOS 没有 H5 的 iframe 路由时，以应用内 Safari 承载后台配置的规范页。
private struct WishCommitmentSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// H5 `wishlist-audit-records.vue` 的审核记录 sheet：All / Pending / Approved / Rejected 四档筛选。
private struct WishSettingAuditRecordsSheet: View {
    private struct Filter: Identifiable {
        let status: Int?
        let title: String
        var id: String {
            guard let status else { return "all" }
            return String(status)
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedStatus: Int?
    @State private var items: [WishPromiseAuditItem] = []
    @State private var isLoading = false

    private let statuses: [Filter] = [
        Filter(status: nil, title: L10n.wishSettingAuditAll),
        Filter(status: 0, title: L10n.wishSettingAuditPending),
        Filter(status: 1, title: L10n.wishSettingAuditApproved),
        Filter(status: 2, title: L10n.wishSettingAuditRejected),
    ]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L10n.wishSettingAuditRecords)
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(statuses) { filter in
                    Button { selectedStatus = filter.status } label: {
                        Text(filter.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(selectedStatus == filter.status ? Color.pink : Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Group {
                if isLoading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text(L10n.wishSettingAuditEmpty)
                        .font(.footnote).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                recordRow(item)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .task(id: selectedStatus) { await load() }
        .preferredColorScheme(.dark)
    }

    private func recordRow(_ item: WishPromiseAuditItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(item.content).font(.system(size: 14)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(statusTitle(item.status))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor(item.status))
            }
            if item.status == 2, let reason = item.rejectReason, !reason.isEmpty {
                Text("\(L10n.wishSettingAuditRejectReason): \(reason)")
                    .font(.system(size: 11)).foregroundStyle(Color.red.opacity(0.9))
            }
            if let time = item.auditTime ?? item.createTime, !time.isEmpty {
                Text(time).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await WishSettingService.getPromiseAuditList(status: selectedStatus)
        } catch {
            items = []
        }
    }

    private func statusTitle(_ status: Int) -> String {
        switch status {
        case 0: return L10n.wishSettingAuditPending
        case 1: return L10n.wishSettingAuditApproved
        case 2: return L10n.wishSettingAuditRejected
        default: return ""
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 0: return .orange
        case 1: return Color(hex: 0x17DC74)
        case 2: return .red
        default: return .white.opacity(0.5)
        }
    }
}

#if DEBUG
#Preview("editing") {
    NavigationStack { WishSettingView() }
        .preferredColorScheme(.dark)
}
#endif
