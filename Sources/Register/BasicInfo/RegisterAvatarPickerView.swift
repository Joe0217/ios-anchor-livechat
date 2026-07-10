import SwiftUI
import PhotosUI

/// Page 1 圆形头像 + 相机叠标（对齐 `注册1.png` / `注册-填写好状态.png`）
struct RegisterAvatarPickerView: View {
    @ObservedObject var store: RegisterStore
    @State private var pickerItem: PhotosPickerItem? = nil

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            ZStack(alignment: .bottomTrailing) {
                // 头像圆形（无背景色/边框，对齐 2026-07-09 用户反馈）
                ZStack {
                    AvatarView(urlString: store.iconUrl, size: 100, kind: .anchor, persistent: false)
                    if store.isAvatarUploading {
                        Circle().fill(.black.opacity(0.4)).frame(width: 100, height: 100)
                        ProgressView().tint(.white)
                    }
                }
                // 相机叠标（保留粉色小按钮）
                Circle()
                    .fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 2, y: 2)
            }
        }
        .onChange(of: pickerItem) { newItem in
            Task { await upload(newItem) }
        }
    }

    @MainActor
    private func upload(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        store.isAvatarUploading = true
        defer { store.isAvatarUploading = false }
        do {
            let url = try await ImageUploader.shared.upload(rawData: data, preset: .avatar)
            store.iconUrl = url
            store.avatarUploadError = nil
        } catch ImageCompressor.CompressError.originalTooLarge(let bytes) {
            // 图片超 preset.maxRawKB 硬顶（avatar preset 上限见 ImageCompressionPreset.avatar）
            let maxMB = Int((Double(bytes) / 1024.0 / 1024.0).rounded())
            store.avatarUploadError = L10n.Register.errorImageTooLarge(maxMB > 0 ? maxMB : 5)
        } catch {
            // Bug fix 2026-07-08：avatar 上传失败**不**借用 submitError（那是给 Page 2 A2/A3 接口错用的）；
            // 用独立 avatarUploadError，BasicInfo view 层负责显示 toast，不跨页穿透
            store.avatarUploadError = L10n.Register.errorUploadFailed
        }
    }
}
