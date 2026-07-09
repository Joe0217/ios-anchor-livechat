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
  # 礼物特效引擎：SVGA 动效播放 + EVA（yylive/YYEVA-iOS）高性能 MP4 特效播放
  # ⚠️ YYEVA 最新是 1.1.42，无 1.2+/1.4 系列（`pod search YYEVA` 2026-07-09 验证），
  # 别按语义化推 `~> 1.4`（会命不中）；锁 `~> 1.1.42` 保守；升 2.x 前需重跑 pod search 验证。
  pod 'SVGAPlayer', '~> 2.5'
  pod 'YYEVA', '~> 1.1.42'
end

# ⚠️ SVGAPlayer 2.5.x upstream bug（截至 2026-07）：Svga.pbobjc.m 用 OSAtomicCompareAndSwapPtrBarrier
# 但未 import <libkern/OSAtomic.h>；Xcode 16 + iOS 18 SDK 起 implicit function declaration 由
# warning 升级为 error → SVGAPlayer 编译失败 → Hily main target 级联挂 → tests 全部跑不了。
#
# 两条同时打：
#   (1) 关 implicit declaration 报 error（治 c99 严格模式那部分）
#   (2) 用 -include libkern/OSAtomic.h 强制预注入头（治 module import + 类型冲突那部分）
# 这样不改 pod 源码，pod install 重跑不会丢配置。详见 github.com/svga/SVGAPlayer-iOS 未修 issue。
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      # ⚠️ Xcode 14+ 移除 libarclite（旧 ARC 兼容库，仅 iOS < 11 需要）；若某 pod 的 podspec 声明
      # IPHONEOS_DEPLOYMENT_TARGET < 11.0，真机 build 会报
      #   "SDK does not contain 'libarclite' at ... libarclite_iphoneos.a"
      # 修复：全局拉平到 iOS 16（对齐主 target 的 deploymentTarget，避免真机 build 挂）
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
    if target.name == 'SVGAPlayer'
      target.build_configurations.each do |config|
        config.build_settings['GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS'] = 'NO'
        cflags = config.build_settings['OTHER_CFLAGS'] || '$(inherited)'
        cflags = [cflags, '-include', 'libkern/OSAtomic.h'].join(' ')
        config.build_settings['OTHER_CFLAGS'] = cflags
      end
    end
  end
end
