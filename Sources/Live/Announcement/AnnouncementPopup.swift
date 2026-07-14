import SwiftUI

/// 公告管理弹窗（对齐 H5 liveAnnouncementPopup.vue DM-20260601-002）
///
/// - textarea 输入（字数上限 120）+ 字数计数
/// - 保存按钮 → API save
/// - 敏感词 code=1070 → toast 提示（v9 不做 mirror 高亮）
struct AnnouncementPopup: View {
    @Binding var isPresented: Bool
    @StateObject private var store: AnnouncementStore
    /// v20 保存成功回调 —— 父层用于**立即关闭 popup + 插入公屏 announcement 消息**（对齐 H5 保存后行为）
    private let onSaved: (String) -> Void

    init(roomId: String,
         isPresented: Binding<Bool>,
         onSaved: @escaping (String) -> Void = { _ in }) {
        self._store = StateObject(wrappedValue: AnnouncementStore(roomId: roomId))
        self._isPresented = isPresented
        self.onSaved = onSaved
    }

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.announcementPopupTitle) {
            // v20: 内容区固定 200pt 高（用户明示"公告弹窗高度改为 200pt"）
            VStack(spacing: 8) {
                textEditor
                charCountLabel
                saveStatusLabel
                PKPopupButton(title: L10n.announcementSave, style: .gradientPurpleToRed) {
                    store.save()
                }
                .disabled(store.saveState == .saving)
                .padding(.horizontal, 20).padding(.top, 2)
            }
            .padding(.horizontal, 8)
            .frame(height: 200)   // v20 明示高度
            .onAppear { store.loadIfNeeded() }
            // v21 修 bug：原来把"保存完成"副作用挂在 saveStatusLabel 的 `Color.clear.onAppear` 里，
            // popup 是 .overlay 永久挂载 + @StateObject 复用 → saveState 停在 .saved 未 reset →
            // 再次打开 popup 时 view 重建触发 .onAppear 副作用重放 → 自动 onSaved + 关闭。
            // 改为 onChange 观察状态转移，并立即 resetSaveState 避免 stale。
            .onChange(of: store.saveState) { newState in
                guard case .saved = newState else { return }
                let content = store.draftContent
                store.resetSaveState()
                onSaved(content)
                withAnimation { isPresented = false }
            }
        }
    }

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.1))
            if store.draftContent.isEmpty {
                Text(L10n.announcementPlaceholder)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 12).padding(.top, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { store.draftContent },
                set: { new in
                    // 字数限制
                    store.draftContent = String(new.prefix(announcementCharLimit))
                }
            ))
            .scrollContentBackground(.hidden)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        // v20: 缩小到 90pt 让整个 popup 内容装进 200pt
        .frame(height: 90)
    }

    private var charCountLabel: some View {
        HStack {
            Spacer()
            Text("\(store.draftContent.count) / \(announcementCharLimit)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var saveStatusLabel: some View {
        switch store.saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(.white)
                Text(L10n.announcementSaving)          // v20 L10n 3 语已补齐
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            }
        case .saved:
            // v21：副作用（onSaved + 关闭）已迁到 body 的 onChange(of: saveState)；这里保持无视觉
            EmptyView()
        case .sensitiveWords(let hits):
            Text(String(format: L10n.announcementSensitiveWord, hits.joined(separator: ", ")))
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.9))
                .multilineTextAlignment(.center)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.9))
                .lineLimit(2)
        }
    }
}
