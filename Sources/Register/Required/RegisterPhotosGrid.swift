import SwiftUI
import PhotosUI

/// Page 2 6 宫格照片上传（2 行 3 列，独立进度 + 重试 + 删除）
///
/// 视觉基线参考 EditProfile MediaTile（对齐 plan v2 §2.3 preflight 结论：不复用但借鉴），
/// 但结构简化：只支持图（无视频混编）、无拖动排序、无 mediaId server 状态
struct RegisterPhotosGrid: View {
    @ObservedObject var store: RegisterStore

    private let maxPhotos = 6
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showMediaSourceMenu = false
    @State private var showPhotoLibrary = false
    @State private var showBeautyCamera = false
    @State private var showCameraPermissionAlert = false

    private var remainingSlots: Int { max(0, maxPhotos - store.picUploadTasks.count) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(store.picUploadTasks) { task in
                photoCell(task)
            }
            if remainingSlots > 0 {
                addCell
            }
        }
        .confirmationDialog(
            L10n.Publish.addImage,
            isPresented: $showMediaSourceMenu,
            titleVisibility: .visible
        ) {
            Button {
                DispatchQueue.main.async { openBeautyCamera() }
            } label: {
                Label(L10n.beautyStudioCamera, systemImage: "camera.fill")
            }
            Button {
                DispatchQueue.main.async { showPhotoLibrary = true }
            } label: {
                Label(L10n.Publish.mediaSourcePhotoLibrary, systemImage: "photo")
            }
            Button(L10n.Publish.cancel, role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotoLibrary,
            selection: $pickerItems,
            maxSelectionCount: remainingSlots,
            matching: .images
        )
        .onChange(of: pickerItems) { newItems in
            Task { await enqueueAndUpload(newItems) }
        }
        .overlay {
            if showCameraPermissionAlert {
                MediaPermissionDialog(
                    requirement: .camera,
                    onCancel: { showCameraPermissionAlert = false },
                    onConfirm: retryBeautyCameraPermission
                )
                .zIndex(100)
            }
        }
        .fullScreenCover(isPresented: $showBeautyCamera) {
            BeautySettingsView(mode: .camera) { data in
                showBeautyCamera = false
                Task { await enqueueAndUpload([data]) }
            }
        }
    }

    private func photoCell(_ task: PhotoUploadTask) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.17, green: 0.13, blue: 0.24))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    switch task.state {
                    case .uploading:
                        ProgressView().tint(.white)
                    case .succeeded(let url):
                        CachedAsyncImage(
                            url: URL(string: url),
                            contentMode: .fill,
                            persistent: false,
                            allowsRegistrationReviewImage: true
                        ) {
                            ProgressView()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        if RegistrationReviewMediaPolicy.containsMarker(url) {
                            reviewingBadge
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    case .failed:
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text(L10n.commonRetry).font(.caption2).foregroundStyle(.white)
                        }
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .failed = task.state {
                        Task { await retry(task) }
                    }
                }

            Button {
                store.removePicTask(id: task.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.4)))
            }
            .padding(4)
        }
    }

    private var reviewingBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.profileMediaReviewing)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private var addCell: some View {
        Button {
            showMediaSourceMenu = true
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.17, green: 0.13, blue: 0.24))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.4))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Publish.addImage)
    }

    @MainActor
    private func enqueueAndUpload(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard store.picUploadTasks.count < maxPhotos else { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            enqueueAndUpload(data)
        }
        pickerItems.removeAll()
    }

    @MainActor
    private func enqueueAndUpload(_ dataItems: [Data]) async {
        for data in dataItems {
            guard store.picUploadTasks.count < maxPhotos else { break }
            enqueueAndUpload(data)
        }
    }

    @MainActor
    private func enqueueAndUpload(_ data: Data) {
        let taskId = UUID()
        store.picUploadTasks.append(
            PhotoUploadTask(id: taskId, localData: data, state: .uploading(progress: 0))
        )
        Task { await performUpload(id: taskId, data: data) }
    }

    private func openBeautyCamera() {
        Task { @MainActor in
            guard await MediaPermissionGate.requestAccess(for: .camera) else {
                showCameraPermissionAlert = true
                return
            }
            showBeautyCamera = true
        }
    }

    private func retryBeautyCameraPermission() {
        Task { @MainActor in
            guard await MediaPermissionGate.requestAccess(for: .camera) else {
                MediaPermissionGate.openAppSettings()
                return
            }
            showCameraPermissionAlert = false
            showBeautyCamera = true
        }
    }

    @MainActor
    private func retry(_ task: PhotoUploadTask) async {
        // 重置状态
        if let idx = store.picUploadTasks.firstIndex(where: { $0.id == task.id }) {
            store.picUploadTasks[idx].state = .uploading(progress: 0)
        }
        await performUpload(id: task.id, data: task.localData)
    }

    private func performUpload(id: UUID, data: Data) async {
        do {
            let url = try await ImageUploader.shared.upload(
                rawData: data,
                preset: .moment,
                directory: .registrationReview
            )
            await MainActor.run { store.setPicSucceeded(id: id, url: url) }
        } catch ImageCompressor.CompressError.originalTooLarge(let bytes) {
            let maxMB = Int((Double(bytes) / 1024.0 / 1024.0).rounded())
            let msg = L10n.Register.errorImageTooLarge(maxMB > 0 ? maxMB : 5)
            await MainActor.run { store.setPicFailed(id: id, error: msg) }
        } catch {
            await MainActor.run { store.setPicFailed(id: id, error: L10n.Register.errorUploadFailed) }
        }
    }
}
