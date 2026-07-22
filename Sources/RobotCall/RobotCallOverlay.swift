import AVFoundation
import SwiftUI
import UIKit

/// 机器人来电、预录视频通话和结算奖励的全局覆盖层。
struct RobotCallOverlay: View {
    @ObservedObject var store: RobotCallStore
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ZStack {
            switch store.state {
            case .idle:
                Color.clear.allowsHitTesting(false)
            case .ringing:
                if let invite = store.invite {
                    RobotCallIncomingView(invite: invite, store: store)
                }
            case .connecting:
                RobotCallConnectingView()
            case .connected:
                if let invite = store.invite {
                    RobotCallVideoCallView(invite: invite, store: store, session: session)
                }
            }

            if let reward = store.reward {
                RobotCallRewardView(reward: reward, onDismiss: store.dismissReward)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.state)
        .animation(.easeInOut(duration: 0.2), value: store.reward)
    }
}

private struct RobotCallIncomingView: View {
    let invite: RobotCallInvite
    @ObservedObject var store: RobotCallStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.robotCallIncomingTitle)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(store.ringSecondsRemaining)s")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.41, green: 0.12, blue: 0.60))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                }

                VStack(spacing: 8) {
                    Text(L10n.robotCallIncomingSupport)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.47, blue: 0.96))
                    Rectangle()
                        .fill(Color(red: 0.78, green: 0.47, blue: 0.96).opacity(0.72))
                        .frame(width: 124, height: 2)
                }

                AvatarView(urlString: nil, size: 80, kind: .user, disablesTap: true)

                Text(invite.displayUserId)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190)

                Text(L10n.robotCallWaiting)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))

                HStack(spacing: 58) {
                    callActionButton(
                        icon: "phone.down.fill",
                        color: Color(red: 0.77, green: 0.20, blue: 0.18),
                        label: L10n.robotCallReject
                    ) {
                        Task { await store.reject() }
                    }
                    callActionButton(
                        icon: "phone.fill",
                        color: Color(red: 0.16, green: 0.62, blue: 0.31),
                        label: L10n.robotCallAccept
                    ) {
                        Task { await store.accept() }
                    }
                }
                .padding(.top, 12)
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(Color(red: 0.13, green: 0.10, blue: 0.19), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .padding(.horizontal, 24)
        }
        .disabled(store.isRequestInFlight)
    }

    private func callActionButton(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct RobotCallConnectingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
        }
    }
}

private struct RobotCallVideoCallView: View {
    let invite: RobotCallInvite
    @ObservedObject var store: RobotCallStore
    let session: SessionStore
    @State private var showEndConfirmation = false

    var body: some View {
        ZStack {
            RobotCallVideoSurface(url: invite.fileURL) {
                Task { await store.videoDidFinish() }
            }
            .ignoresSafeArea()

            Color.black.opacity(0.14).ignoresSafeArea().allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                hostSummary
                    .padding(.top, 16)

                Text(timeText(store.elapsedSeconds))
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.top, 10)

                Spacer()

                HStack {
                    Spacer()
                    Button {
                        if store.canHangUp {
                            showEndConfirmation = true
                        } else {
                            Task { await store.hangUp() }
                        }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color(red: 0.77, green: 0.20, blue: 0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.robotCallEnd)
                    Spacer()
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 12)
        }
        .confirmationDialog(
            L10n.callHangupConfirmTitle,
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.robotCallEnd, role: .destructive) {
                Task { await store.hangUp() }
            }
            Button(L10n.callHangupConfirmCancel, role: .cancel) {}
        }
    }

    private var hostSummary: some View {
        HStack(spacing: 8) {
            AvatarView(urlString: session.user?.icon, size: 40, kind: .anchor, disablesTap: true)
            Text(session.user?.nickname ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(4)
        .padding(.trailing, 12)
        .background(.black.opacity(0.42), in: Capsule())
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RobotCallRewardView: View {
    let reward: RobotCallReward
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.66).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: reward.isEligible ? "diamond.fill" : "clock.badge.exclamationmark")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(reward.isEligible ? Color(red: 1, green: 0.63, blue: 0.22) : .white.opacity(0.82))

                Text(reward.isEligible ? L10n.robotCallRewardTitle : L10n.robotCallNoRewardTitle)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)

                Text(String(format: reward.isEligible ? L10n.robotCallRewardDurationFormat : L10n.robotCallDurationFormat, timeText))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.66))

                if reward.isEligible {
                    Text(String(format: L10n.robotCallRewardCoinsFormat, reward.diamondText))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Button(L10n.robotCallRewardOK, action: onDismiss)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color(red: 0.91, green: 0.18, blue: 0.52), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .buttonStyle(.plain)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: 320)
            .background(Color(red: 0.12, green: 0.10, blue: 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            }
            .padding(.horizontal, 24)
        }
    }

    private var timeText: String {
        String(format: "%02d:%02d", reward.callDurationSeconds / 60, reward.callDurationSeconds % 60)
    }
}

private struct RobotCallVideoSurface: UIViewRepresentable {
    let url: URL
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    func makeUIView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        context.coordinator.install(url: url, in: view)
        return view
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        context.coordinator.install(url: url, in: uiView)
    }

    static func dismantleUIView(_ uiView: PlayerContainer, coordinator: Coordinator) {
        coordinator.stop()
        uiView.playerLayer.player = nil
    }

    final class Coordinator {
        private let onFinished: () -> Void
        private var currentURL: URL?
        private var player: AVPlayer?
        private var completionObserver: NSObjectProtocol?

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
        }

        deinit { stop() }

        func install(url: URL, in view: PlayerContainer) {
            guard currentURL != url else { return }
            stop()
            currentURL = url
            let player = AVPlayer(url: url)
            self.player = player
            view.playerLayer.player = player
            completionObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [onFinished] _ in
                onFinished()
            }
            player.play()
        }

        func stop() {
            if let completionObserver {
                NotificationCenter.default.removeObserver(completionObserver)
            }
            completionObserver = nil
            player?.pause()
            player = nil
            currentURL = nil
        }
    }

    final class PlayerContainer: UIView {
        let playerLayer = AVPlayerLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(playerLayer)
            backgroundColor = .black
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
}
