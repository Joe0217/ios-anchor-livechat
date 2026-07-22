import AVFoundation
import Combine
import SwiftUI
import UIKit

/// 摄像头/麦克风能力的系统权限门禁。
///
/// 业务权限（`SelfPermissionBridge`）与系统媒体权限是两层独立约束：前者决定用户是否可开播，
/// 后者决定 App 是否可以实际采集音视频。媒体功能开始前必须同时经过两层校验。
enum MediaPermissionGate {
    enum Requirement {
        case camera
        case microphone
        case liveStream
    }

    /// 请求满足指定功能所需的系统授权。已拒绝时不会重复弹系统弹窗，直接返回 `false`。
    static func requestAccess(for requirement: Requirement) async -> Bool {
        switch requirement {
        case .camera:
            return await requestAccess(for: .video)
        case .microphone:
            return await requestAccess(for: .audio)
        case .liveStream:
            guard await requestAccess(for: .video) else { return false }
            return await requestAccess(for: .audio)
        }
    }

    /// 当前是否已具备指定功能所需的全部授权，不触发系统弹窗。
    static func hasAccess(for requirement: Requirement) -> Bool {
        switch requirement {
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .liveStream:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    static func denialMessage(for requirement: Requirement) -> String {
        switch requirement {
        case .camera:
            return L10n.mediaPermissionCameraRequired
        case .microphone:
            return L10n.mediaPermissionMicrophoneRequired
        case .liveStream:
            return L10n.mediaPermissionLiveRequired
        }
    }

    /// 用户已拒绝系统弹窗后，iOS 不会再次展示同一项授权请求；此时只能跳 App 设置页。
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

/// 跨页面媒体权限弹窗。用于当前页面必须先关闭后才能展示提示的场景（如美颜预览）。
@MainActor
final class MediaPermissionAlertCenter: ObservableObject {
    static let shared = MediaPermissionAlertCenter()

    @Published private(set) var requirement: MediaPermissionGate.Requirement?

    private init() {}

    /// 当前页面仍在展示时立即提示权限，不需要等待 dismiss 动画。
    func present(for requirement: MediaPermissionGate.Requirement) {
        self.requirement = requirement
    }

    /// 等待导航 dismiss 动画完成，避免弹窗叠在即将退出的页面上。
    func presentAfterCurrentPageDismissal(for requirement: MediaPermissionGate.Requirement) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.requirement = requirement
        }
    }

    func dismiss() {
        requirement = nil
    }

    func retry(_ requirement: MediaPermissionGate.Requirement) async {
        self.requirement = nil
        if !(await MediaPermissionGate.requestAccess(for: requirement)) {
            MediaPermissionGate.openAppSettings()
        }
    }
}

/// 所有媒体权限场景共用的模态提示，避免不同页面的系统 alert 呈现和交互不一致。
struct MediaPermissionDialog: View {
    let requirement: MediaPermissionGate.Requirement
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(L10n.mediaPermissionAlertTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(MediaPermissionGate.denialMessage(for: requirement))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                HStack(spacing: 12) {
                    Button(L10n.settingsCancel, action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Theme.Palette.divider, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button(L10n.settingsConfirm, action: onConfirm)
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Theme.Palette.brandPinkA, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
            .padding(.horizontal, 28)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
