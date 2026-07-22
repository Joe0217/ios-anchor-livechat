import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "robot-call-broadcast")

/// 机器人来电期间的本机直播推流。
///
/// H5 在响铃框出现时就以 `agoraChannelId` 开始主播推流；预录视频仅是主播端看到的
/// 对方画面。本对象复用已有 `AgoraManager` 外部视频帧管线，将 CameraManager 的帧推入
/// 机器人房间，并在来电结束时统一离开频道和释放摄像头。
@MainActor
final class RobotCallBroadcastSession {
    private let agora = AgoraManager()
    private var camera: CameraManager?
    private var activeRecordId: String?
    private var stopTask: Task<Void, Never>?

    func start(for invite: RobotCallInvite) async {
        guard activeRecordId != invite.recordId else { return }
        await stop()

        guard let channelId = invite.agoraChannelId,
              let userId = SessionStore.shared.user?.userId,
              userId > 0 else {
            logger.warning("skip broadcast record=\(invite.recordId, privacy: .private): missing channel or user")
            return
        }
        guard await MediaPermissionGate.requestAccess(for: .liveStream) else {
            logger.warning("skip broadcast record=\(invite.recordId, privacy: .private): media permission denied")
            return
        }
        guard !Task.isCancelled else { return }

        do {
            let tokenResult = try await LiveService.getAgoraRtmToken()
            guard !Task.isCancelled,
                  let token = tokenResult.rtcToken,
                  !token.isEmpty else {
                logger.warning("skip broadcast record=\(invite.recordId, privacy: .private): missing RTC token")
                return
            }

            let camera = CameraManager()
            self.camera = camera
            activeRecordId = invite.recordId
            camera.subscribe(ObjectIdentifier(self)) { [weak agora] pixelBuffer in
                agora?.pushFrame(pixelBuffer)
            }
            camera.start()
            agora.join(channelId: channelId, token: token, uid: UInt(userId))
            logger.info("started record=\(invite.recordId, privacy: .private) channel=\(channelId, privacy: .private)")
        } catch is CancellationError {
            return
        } catch {
            logger.error("start failed record=\(invite.recordId, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard activeRecordId != nil || camera != nil || agora.isActive else { return }

        let camera = self.camera
        self.camera = nil
        activeRecordId = nil
        let agora = self.agora
        let task = Task {
            camera?.unsubscribe(ObjectIdentifier(self))
            camera?.tearDown()
            await agora.leave()
        }
        stopTask = task
        await task.value
        stopTask = nil
        logger.info("stopped")
    }
}
