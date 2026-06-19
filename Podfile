platform :ios, '16.0'

# 云信 NIM SDK 只有 CocoaPods 分发（无 SPM），与现有 SPM(声网)/embedded framework(相芯) 共存。
# 工作流：xcodegen generate 后需重新 pod install；构建用 Hily.xcworkspace。
target 'Hily' do
  use_frameworks!
  pod 'NIMSDK_LITE', '~> 10.10.0'  # IM + 聊天室（V2NIMChatroomClient），不含多余 RTC
  # 声网视频 SDK：官方指定的专用包（含 AgoraRtcKit.xcframework），替代原 SPM AgoraRtcEngine_iOS。
  # 版本号必须精确写全 '4.5.2.9.BASIC'（.BASIC 被当 prerelease，用 ~> 或省略会命不中）。
  pod 'AgoraVideo_Special_iOS', '4.5.2.9.BASIC'
  # 声网 RTM2 专版：1v1 通话信令（VideoCall/Cancel/Accept/Reject/Hangup 五类 CallAction）。
  # ⚠️ 仅装 RtmKit subspec、跳过 RtmBasic：RtmBasic 与 AgoraVideo_Special_iOS 都带
  # aosl.xcframework（同名不同二进制冲突），二者同代号下复用 RTC 的 aosl 即可。
  pod 'AgoraRtm_OC_Special/RtmKit', '~> 2.2.6'
end
