import SwiftUI
import PhotosUI

/// 发布朋友圈页（J spec §4 / Step 1b）。
///
/// **结构**：
/// - NavigationStack：title "Post" / 左 Cancel / 右 Release（条件 enable）
/// - 编辑区：TextEditor + 字数计数（实时）+ 图片网格（≤9 张，PhotosPicker 触发选图）
/// - 上传遮罩：覆盖编辑区禁交互 + 居中 ProgressView + "Posting..."（对齐 H5，spec v3 Q10）
/// - Toast：复用 [BlocklistView 模式](../../Profile/Settings/Blocklist/BlocklistView.swift#L201-L226)
///   `.overlay + .task(id: msg)` + 2s 自动消失
/// - Confirm dialog：上传中切走 → `.confirmationDialog "放弃发布?"`（spec R11/R12）
///
/// **不变量**（[.claude/rules/swiftui-camera-preview.md](../../../.claude/rules/swiftui-camera-preview.md) 规则 1）：
/// 状态机分支必须在同一 identity 槽位避免 dismantle 重建。
struct PostPublishView: View {
    @ObservedObject var viewModel: PostPublishViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showDiscardConfirm: Bool = false

    var body: some View {
        NavigationStack {
            content
                .background(Theme.Palette.screenBackground.ignoresSafeArea())
                .navigationTitle(L10n.Publish.navTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.Publish.cancel) {
                            handleCancelRequest()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.Publish.release) {
                            viewModel.publish()
                        }
                        .disabled(!viewModel.canPublish)
                        .fontWeight(.semibold)
                    }
                }
        }
        // R11/R12：上传中切走弹 confirm
        .confirmationDialog(L10n.Publish.discardTitle,
                            isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button(L10n.Publish.discardConfirm, role: .destructive) {
                viewModel.cancelInflightForDismiss()
                dismiss()
            }
            Button(L10n.Publish.discardKeep, role: .cancel) { }
        } message: {
            Text(L10n.Publish.discardMessage)
        }
        // 自动 dismiss：发布成功
        .onChange(of: viewModel.state) { newState in
            if case .success = newState {
                // 给 toast 时间显示 + 用户看到再退
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    dismiss()
                }
            }
        }
        // 同步 PhotosPicker 选图回流
        .onChange(of: pickerItems) { newItems in
            handlePickerItems(newItems)
        }
        // toast 复用 BlocklistView 模式：`.overlay + .task(id:)`，2s 自动消失
        .overlay(alignment: .top) {
            transientErrorToast
        }
    }

    // MARK: - 主体内容

    @ViewBuilder
    private var content: some View {
        ZStack {
            VStack(spacing: 12) {
                textEditor
                charCounter
                imageGrid
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 上传遮罩（spec v3 Q10：居中 ProgressView，对齐 H5 简陋设计）
            if isInProgress {
                progressOverlay
            }
        }
    }

    private var textEditor: some View {
        TextEditor(text: $viewModel.text)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))
            )
            .foregroundStyle(.white)
            .frame(minHeight: 100, maxHeight: 200)
            .overlay(alignment: .topLeading) {
                if viewModel.text.isEmpty {
                    Text(L10n.Publish.placeholder)
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(L10n.Publish.placeholder)
    }

    private var charCounter: some View {
        HStack {
            Spacer()
            Text(String(format: L10n.Publish.charCountFormat, viewModel.text.count))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    /// 3 列网格，最多 9 张 + 1 个 "+" 按钮
    private var imageGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(viewModel.imageDataList.indices, id: \.self) { idx in
                imageThumbnail(idx: idx)
            }
            if viewModel.imageDataList.count < PostPublishLimits.maxImageCount {
                addImageButton
            }
        }
    }

    @ViewBuilder
    private func imageThumbnail(idx: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: viewModel.imageDataList[idx]) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            Button {
                viewModel.removeImage(at: idx)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Publish.removeImage)
        }
        .allowsHitTesting(!isInProgress)
    }

    private var addImageButton: some View {
        PhotosPicker(selection: $pickerItems,
                     maxSelectionCount: PostPublishLimits.maxImageCount - viewModel.imageDataList.count,
                     matching: .images) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white.opacity(0.45))
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .disabled(isInProgress)
        .accessibilityLabel(L10n.Publish.addImage)
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
                Text(L10n.Publish.posting)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
        }
        .allowsHitTesting(true)  // 阻止下层交互
    }

    /// Toast：复用 BlocklistView 模式（.overlay + .task(id:)）
    @ViewBuilder
    private var transientErrorToast: some View {
        if let msg = viewModel.transientError {
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85), in: Capsule())
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: msg) {
                    // 与 BlocklistView 同款 2s 自动消失
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    viewModel.transientError = nil
                }
        }
    }

    // MARK: - 派生 / 辅助

    /// 是否处于上传/create 进行中（disable 输入 + 显示 overlay）
    private var isInProgress: Bool {
        switch viewModel.state {
        case .uploadingImages, .creatingPost: return true
        default: return false
        }
    }

    /// 用户点 Cancel：editing 直接 dismiss；进行中弹 confirm（R11）
    private func handleCancelRequest() {
        switch viewModel.state {
        case .editing, .failed:
            // 有内容也不弹 confirm（编辑态 cancel 直接走，符合 H5 简陋设计）
            viewModel.cancelInflightForDismiss()
            dismiss()
        case .uploadingImages, .creatingPost:
            showDiscardConfirm = true
        case .success:
            dismiss()
        }
    }

    /// PhotosPicker 选图回流：加载 Data + 喂给 ViewModel
    private func handlePickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let captured = items
        Task {
            for item in captured {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        viewModel.appendImage(rawData: data)
                    }
                }
            }
            await MainActor.run {
                pickerItems = []  // 清空让用户可再次选
            }
        }
    }
}

#if DEBUG
struct PostPublishView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PostPublishView(viewModel: .preview(state: .editing,
                                                text: "Hello world",
                                                imageDataList: []))
                .previewDisplayName("editing - 空 imgs (Release disabled)")

            PostPublishView(viewModel: .preview(state: .editing,
                                                text: String(repeating: "a", count: 500),
                                                imageDataList: Array(repeating: Data([0x00]), count: 9)))
                .previewDisplayName("editing - 500 字 + 9 图")

            PostPublishView(viewModel: .preview(state: .uploadingImages(progress: 2, total: 5, uploadedUrls: [0: "u0", 1: "u1"]),
                                                text: "Publishing",
                                                imageDataList: Array(repeating: Data([0x00]), count: 5)))
                .previewDisplayName("uploadingImages - overlay 显示")

            PostPublishView(viewModel: .preview(state: .creatingPost(imgUrls: ["u0", "u1"]),
                                                text: "Creating",
                                                imageDataList: Array(repeating: Data([0x00]), count: 2)))
                .previewDisplayName("creatingPost - overlay 显示")

            PostPublishView(viewModel: .preview(state: .failed(reason: .uploadFailed(idx: 2),
                                                                uploadedUrls: [0: "u0", 1: "u1"]),
                                                text: "Retry me",
                                                imageDataList: Array(repeating: Data([0x00]), count: 5)))
                .previewDisplayName("failed - uploadFailed 可重试")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
