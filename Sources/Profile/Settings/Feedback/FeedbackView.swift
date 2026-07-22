import SwiftUI
import PhotosUI

/// 反馈页 UI（对齐 H5 `src/views/settings/feedBack/index.vue`）。
///
/// 表单结构（垂直）：
/// 1. 4 类型单选 wrap（App Error / Account Error / Suggestion / Other）
/// 2. Message textarea（最多 2000 字，show char counter）
/// 3. Email 输入框（正则校验，提交时校验）
/// 4. 图片上传（最多 3 张，PhotosPicker 选完立即入 pending 队列）
/// 5. 底部固定 Confirm 按钮（`canSubmit` 控制 disabled）
struct FeedbackView: View {
    @StateObject private var vm: FeedbackViewModel
    @State private var pickerItems: [PhotosPickerItem] = []
    @Binding var path: NavigationPath

    init(path: Binding<NavigationPath>, vm: FeedbackViewModel? = nil) {
        self._path = path
        _vm = StateObject(wrappedValue: vm ?? FeedbackViewModel())
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Card 1（对齐 H5 CCard 空 title）：4 chip wrap + textarea
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            typeSection
                            messageSection
                        }
                    }
                    // Card 2（对齐 H5 CCard title="Email"）：Email label + input + 3 图上传
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Email")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                            emailInput
                            photosSection
                        }
                    }
                    Spacer(minLength: 100)   // 让开底部 Confirm 按钮
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
        }
        .overlay(alignment: .bottom) { submitButton }
        .overlay(alignment: .top) { toastOverlay }
        .navigationTitle(L10n.settingsFeedback)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: pickerItems) { newItems in
            Task { await loadPickerData(newItems) }
        }
        // 提交成功后延迟 dismiss（让用户看到 toast）
        .onChange(of: vm.state) { newState in
            if newState == .success {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if !path.isEmpty { path.removeLast() }
                }
            }
        }
    }

    // MARK: - Card container（对齐 H5 CCard 视觉分组）

    /// 卡片背景 + inner padding。H5 CCard 默认深色卡 + `mt-10 pt-10`
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(Theme.Palette.cardFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Sections

    private var typeSection: some View {
        // 4 类型 wrap 单选（对齐 H5 单排 flex wrap）
        FlowLayoutRow(spacing: 10) {
            ForEach(FeedbackType.allCases) { type in
                typeChip(type)
            }
        }
    }

    /// H5 `.item { padding: 10px 20px; border-radius: 5px; }` + `.normal / .selected` 色板
    private func typeChip(_ type: FeedbackType) -> some View {
        let selected = vm.selectedType == type
        return Button {
            vm.selectedType = type
        } label: {
            Text(type.displayName)
                .font(.system(size: 14))
                .foregroundColor(selected ? .white : Color(hex: 0x9E7DDC))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    selected
                        ? Color(hex: 0xFA06F4)
                        : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// H5 `.message { border-radius: 8px; background: rgba(15, 14, 15, 0.8) }` + textarea rows=4 + show-word-limit
    private var messageSection: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                // TextEditor 原生无 placeholder，用 ZStack 覆盖
                if vm.message.isEmpty {
                    Text(L10n.feedbackMessagePlaceholder)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.message)
                    .frame(minHeight: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .scrollContentBackground(.hidden)
                    .foregroundColor(.white)
                    .tint(Theme.Palette.blocklistName)
                    .onChange(of: vm.message) { newValue in
                        if newValue.count > FeedbackViewModel.maxMessageLength {
                            vm.message = String(newValue.prefix(FeedbackViewModel.maxMessageLength))
                        }
                    }
            }
            .background(Color(hex: 0x0F0E0F).opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // H5 show-word-limit：`%d/%d` 计数器
            Text("\(vm.message.count)/\(FeedbackViewModel.maxMessageLength)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    /// H5 `.emial { border-radius: 5px; padding: 4px 10px; background: rgba(15,14,15,0.8) }`
    private var emailInput: some View {
        TextField("", text: $vm.email, prompt: Text(L10n.feedbackEmailPlaceholder).foregroundColor(.white.opacity(0.35)))
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(hex: 0x0F0E0F).opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundColor(.white)
            .tint(Theme.Palette.blocklistName)
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(vm.uploadedPicUrls.enumerated()), id: \.offset) { idx, url in
                    uploadedThumb(url: url, onRemove: { vm.removeUploadedPhoto(at: idx) })
                }
                ForEach(Array(vm.pendingPhotos.enumerated()), id: \.offset) { idx, data in
                    pendingThumb(data: data, onRemove: { vm.removePendingPhoto(at: idx) })
                }
                if (vm.uploadedPicUrls.count + vm.pendingPhotos.count) < FeedbackViewModel.maxPhotoCount {
                    addPhotoTile
                }
                Spacer()
            }
        }
    }

    /// 加号 tile（对齐 H5 CUploadImgsAndVideos 空槽样式）
    private var addPhotoTile: some View {
        let remaining = FeedbackViewModel.maxPhotoCount - vm.uploadedPicUrls.count - vm.pendingPhotos.count
        return PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: remaining,
            matching: .images
        ) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }
        }
    }

    private func uploadedThumb(url: String, onRemove: @escaping () -> Void) -> some View {
        thumbFrame(content: {
            CachedAsyncImage(url: URL(string: url), contentMode: .fill, persistent: true) {
                Color.gray.opacity(0.3)
            }
        }, onRemove: onRemove)
    }

    private func pendingThumb(data: Data, onRemove: @escaping () -> Void) -> some View {
        thumbFrame(content: {
            if let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }, onRemove: onRemove)
    }

    private func thumbFrame<Content: View>(@ViewBuilder content: () -> Content,
                                            onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - Submit

    private var submitButton: some View {
        HStack {
            Button {
                Task { await vm.submit() }
            } label: {
                HStack {
                    Spacer()
                    if vm.state == .submitting {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.settingsConfirm)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(vm.canSubmit ? Color(hex: 0x7C3EDD) : Color.gray.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!vm.canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(Color(hex: 0x1E1C21).opacity(0.9).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let msg = vm.toast {
            Text(msg)
                .toastStyle()
                .transition(Toast.transition)
                .task(id: msg) {
                    do {
                        try await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        try Task.checkCancellation()
                    } catch { return }
                    vm.clearToast()
                }
        }
    }

    // MARK: - PhotosPicker → Data loader

    private func loadPickerData(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await MainActor.run { vm.addPhoto(data) }
            }
        }
        await MainActor.run { pickerItems.removeAll() }
    }
}

/// 简易 flow layout（对齐 H5 flex wrap 单选布局）—— SwiftUI iOS 16 Layout API。
private struct FlowLayoutRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
